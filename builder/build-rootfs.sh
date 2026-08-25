#!/bin/bash
# Usage: build-rootfs.sh <out-payload.img>
# Pacstrap Arch Linux ARM `base` plus the Omarchy shell (hyprland,
# quickshell, sddm, omarchy from local tarballs) onto btrfs @ (label
# OMARCHYLIVE). Needs root. Live session stays multi-user.target /
# autologin — not a graphical login. Do not pacstrap linux-asahi or
# asahi-scripts (their hooks mount the host ESP).
set -euo pipefail

out="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shell packages no longer fit in 3GiB (base + mesa was ~2.1GiB).
payload_bytes=${OMARCHY_USB_PAYLOAD_BYTES:-$((8 * 1024 * 1024 * 1024))}
packages_file=$repo_root/configs/usb/rootfs/packages
forbidden_packages=(linux-asahi asahi-scripts m1n1 uboot-asahi)

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail "build-rootfs.sh needs root (pacstrap + mount)"
command -v pacstrap >/dev/null || fail "pacstrap not found — pacman -S arch-install-scripts"
command -v mkfs.btrfs >/dev/null || fail "need btrfs-progs"
command -v losetup >/dev/null || fail "need losetup"

read_package_list() {
  local pkg
  [[ -f $packages_file ]] || fail "missing $packages_file"
  while read -r pkg; do
    [[ -z $pkg || $pkg == \#* ]] && continue
    printf '%s\n' "$pkg"
  done <"$packages_file"
}

for pkg in "${forbidden_packages[@]}"; do
  if read_package_list | grep -qx "$pkg"; then
    fail "refusing to pacstrap $pkg (mounts or rewrites the host ESP)"
  fi
done

find_local_pkg() {
  local name=$1 dir f
  for dir in \
    ${OMARCHY_LOCAL_PACKAGES:+"$OMARCHY_LOCAL_PACKAGES"} \
    "${HOME}/.local/share/omarchy/build-output" \
    "${repo_root}/../omarchy-mac/build-output"; do
    [[ -d $dir ]] || continue
    for f in "$dir"/${name}-*.pkg.tar.*; do
      [[ -f $f ]] || continue
      printf '%s\n' "$f"
      return 0
    done
  done
  return 1
}

loop=""
mnt=""
cleanup() {
  if [[ -n $mnt ]]; then
    umount "$mnt/boot" 2>/dev/null || true
    umount "$mnt/run" 2>/dev/null || true
    umount "$mnt" 2>/dev/null || true
  fi
  if [[ -n $loop ]]; then
    losetup -d "$loop" 2>/dev/null || true
  fi
}
trap cleanup EXIT

work="$(mktemp -d)"
mnt="$work/mnt"
mkdir -p "$mnt" "$work/root/@" "$work/root/@home" "$work/root/@log"
printf 'omarchy-mac-live-ok rootfs %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$work/root/@/omarchy-mac-live-ok"

log "Creating ${payload_bytes} byte btrfs payload"
rm -f "$out"
truncate -s "$payload_bytes" "$out"
mkfs.btrfs -q -L OMARCHYLIVE --csum crc32c \
  --rootdir "$work/root" \
  --subvol default:@ \
  --subvol rw:@home \
  --subvol rw:@log \
  "$out"

loop="$(losetup -f --show "$out")"
mount -o subvol=@ "$loop" "$mnt"

# Isolate the chroot so alpm hooks cannot mount the host ESP
# (/run/.system-efi → nvme0n1p4). Do not pacstrap asahi-scripts or
# linux-asahi: update-m1n1 is for the installed system, and the live
# kernel is already on the USB ESP. Copy this host's modules so they
# match that kernel (brcmfmac, cdc_ether, …). Firmware is copied from
# the initramfs at boot.
mkdir -p "$mnt/run" "$mnt/boot"
mount -t tmpfs tmpfs "$mnt/run"
mount -t tmpfs tmpfs "$mnt/boot"

mapfile -t extra_packages < <(read_package_list)
log "pacstrap base networkmanager iwd mesa asahi-audio gum + ${extra_packages[*]}"
pacstrap -c "$mnt" base networkmanager iwd mesa asahi-audio \
  alsa-ucm-conf-asahi speakersafetyd pipewire-pulse gum \
  parted gptfdisk btrfs-progs dosfstools grub \
  "${extra_packages[@]}"

local_pkgs=()
for name in omarchy-keyring ttf-jetbrains-mono-nerd-basic omarchy-settings omarchy; do
  f=$(find_local_pkg "$name") \
    || fail "no $name-*.pkg.tar.* — set OMARCHY_LOCAL_PACKAGES or build omarchy first"
  local_pkgs+=("$f")
done
log "pacman -U ${local_pkgs[*]##*/}"
pacman -U --noconfirm --needed --root "$mnt" --cachedir /var/cache/pacman/pkg \
  "${local_pkgs[@]}"

install -m644 "$repo_root/configs/usb/rootfs/pacman.conf" "$mnt/etc/pacman.conf"
[[ -f /etc/pacman.d/mirrorlist ]] || fail "host /etc/pacman.d/mirrorlist missing"
install -m644 /etc/pacman.d/mirrorlist "$mnt/etc/pacman.d/mirrorlist"
[[ -f /etc/pacman.d/mirrorlist.asahi-alarm ]] || fail "host asahi-alarm mirrorlist missing"
install -m644 /etc/pacman.d/mirrorlist.asahi-alarm "$mnt/etc/pacman.d/mirrorlist.asahi-alarm"

umount "$mnt/boot"
umount "$mnt/run"

kver=$(uname -r)
log "Copying host modules $kver (match ESP vmlinuz)"
mkdir -p "$mnt/usr/lib/modules"
cp -a "/usr/lib/modules/$kver" "$mnt/usr/lib/modules/"
[[ -d $mnt/usr/lib/modules/$kver ]] || fail "failed to copy modules for $kver"

install -m644 "$repo_root/configs/usb/rootfs/issue" "$mnt/etc/issue"
install -d "$mnt/etc/systemd/system"
install -d "$mnt/usr/local/sbin"
install -d "$mnt/usr/local/share/omarchy-mac-iso"
install -m755 "$repo_root/configs/usb/rootfs/omarchy-mac-install" \
  "$mnt/usr/local/sbin/omarchy-mac-install"
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-disk.sh" \
  "$mnt/usr/local/share/omarchy-mac-iso/omarchy-mac-disk.sh"
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-disk.sh" \
  "$mnt/usr/local/sbin/omarchy-mac-disk.sh"
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-esp.sh" \
  "$mnt/usr/local/share/omarchy-mac-iso/omarchy-mac-esp.sh"
install -d "$mnt/usr/local/share/omarchy-mac-iso/initcpio/hooks"
install -d "$mnt/usr/local/share/omarchy-mac-iso/initcpio/install"
install -m644 "$repo_root/configs/usb-initcpio/mkinitcpio-install.conf" \
  "$mnt/usr/local/share/omarchy-mac-iso/mkinitcpio-install.conf"
install -m644 "$repo_root/configs/usb/grub-embed.cfg" \
  "$mnt/usr/local/share/omarchy-mac-iso/grub-embed.cfg"
install -m644 "$repo_root/configs/usb/grub-embed-install.cfg" \
  "$mnt/usr/local/share/omarchy-mac-iso/grub-embed-install.cfg"
install -m644 "$repo_root/configs/usb/grub-embed-system.cfg" \
  "$mnt/usr/local/share/omarchy-mac-iso/grub-embed-system.cfg"
install -m644 "$repo_root/configs/usb-initcpio/hooks/omarchy-usb-wait" \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/hooks/omarchy-usb-wait"
install -m644 "$repo_root/configs/usb-initcpio/install/omarchy-usb-wait" \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/install/omarchy-usb-wait"
# asahi-scripts is not pacstrapped (its alpm hooks mount the host ESP).
# Copy only what mkinitcpio needs to build an installed-USB initramfs.
[[ -f /usr/lib/initcpio/hooks/asahi ]] || fail "host asahi initcpio hook missing"
install -m644 /usr/lib/initcpio/hooks/asahi \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/hooks/asahi"
install -m644 /usr/lib/initcpio/install/asahi \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/install/asahi"
mkdir -p "$mnt/usr/share"
cp -a /usr/share/asahi-scripts "$mnt/usr/share/asahi-scripts"
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-usb-ready.service" \
  "$mnt/etc/systemd/system/omarchy-mac-usb-ready.service"
install -d "$mnt/etc/systemd/system/getty@tty1.service.d"
install -m644 "$repo_root/configs/usb/rootfs/getty-autologin.conf" \
  "$mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf"

printf 'omarchy-mac-live\n' >"$mnt/etc/hostname"
printf 'LANG=C.UTF-8\n' >"$mnt/etc/locale.conf"
: >"$mnt/etc/fstab"
: >"$mnt/etc/machine-id"

install -d "$mnt/etc/NetworkManager/conf.d"
install -m644 "$repo_root/configs/usb/rootfs/nm-live.conf" \
  "$mnt/etc/NetworkManager/conf.d/nm-live.conf"
install -d -m700 "$mnt/etc/NetworkManager/system-connections"
install -d "$mnt/etc/modprobe.d"
install -m644 "$repo_root/configs/usb/modprobe.d/hid_apple.conf" \
  "$mnt/etc/modprobe.d/hid_apple.conf"
install -m644 "$repo_root/configs/usb/modprobe.d/asahi-notch.conf" \
  "$mnt/etc/modprobe.d/asahi-notch.conf"
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-asahi-hw.service" \
  "$mnt/etc/systemd/system/omarchy-mac-asahi-hw.service"

systemctl --root="$mnt" enable omarchy-mac-usb-ready.service
systemctl --root="$mnt" enable omarchy-mac-asahi-hw.service
systemctl --root="$mnt" enable NetworkManager.service
systemctl --root="$mnt" enable speakersafetyd.service
systemctl --root="$mnt" --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
systemctl --root="$mnt" set-default multi-user.target

[[ -x $mnt/sbin/init || -L $mnt/sbin/init ]] || fail "pacstrap did not install /sbin/init"
log "payload used $(du -sh "$mnt" | cut -f1) on the @ subvolume"

sync
umount "$mnt"
mnt=""
losetup -d "$loop"
loop=""
trap - EXIT
