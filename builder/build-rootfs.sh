#!/bin/bash
# Usage: build-rootfs.sh <out-payload.img>
# Pacstrap Arch Linux ARM `base` plus omarchy-base.packages (the same
# set the script-based install.sh uses) and local omarchy tarballs onto
# btrfs @ (label OMARCHYLIVE). Needs root. Live session stays
# multi-user.target / autologin — not a graphical login. Do not
# pacstrap linux-asahi or asahi-scripts (their hooks mount the host ESP).
set -euo pipefail

out="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Full omarchy-base.packages no longer fits in 8GiB uncompressed. 12GiB
# plus zstd on the payload still flashes onto a 16GB stick.
payload_bytes=${OMARCHY_USB_PAYLOAD_BYTES:-$((12 * 1024 * 1024 * 1024))}
packages_file=$repo_root/configs/usb/rootfs/packages
skip_file=$repo_root/configs/usb/rootfs/packages-aarch64-skip
forbidden_packages=(linux-asahi asahi-scripts m1n1 uboot-asahi)
local_tarball_packages=(omarchy-keyring ttf-jetbrains-mono-nerd-basic omarchy-settings omarchy)
required_packages=(sudo cryptsetup herdr mise-bin tmux yay)

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail "build-rootfs.sh needs root (pacstrap + mount)"
command -v pacstrap >/dev/null || fail "pacstrap not found — pacman -S arch-install-scripts"
command -v mkfs.btrfs >/dev/null || fail "need btrfs-progs"
command -v losetup >/dev/null || fail "need losetup"
grep -q '^\[omarchy-aarch64\]' /etc/pacman.conf \
  || fail "host /etc/pacman.conf needs [omarchy-aarch64] (same repo the script install uses)"

sudo_home=""
if [[ -n ${SUDO_USER:-} ]]; then
  sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

read_package_names() {
  local file=$1 pkg
  [[ -f $file ]] || return 0
  while read -r pkg; do
    [[ -z $pkg || $pkg == \#* ]] && continue
    printf '%s\n' "$pkg"
  done <"$file"
}

find_omarchy_tree() {
  local dir
  for dir in \
    ${OMARCHY_PATH:+"$OMARCHY_PATH"} \
    ${sudo_home:+"$sudo_home/code/omarchy-mac"} \
    "${repo_root}/../omarchy-mac" \
    "${HOME}/code/omarchy-mac"; do
    [[ -f $dir/install/omarchy-base.packages ]] || continue
    printf '%s\n' "$dir"
    return 0
  done
  return 1
}

package_in_repos() {
  pacman -Si --noconfirm "$1" >/dev/null 2>&1
}

# Arch Linux ARM and omarchy-pkgs-aarch64 use these names.
remap_package() {
  case $1 in
    nvim) printf '%s\n' neovim ;;
    qemu-user-static-binfmt) printf '%s\n' qemu-user-binfmt ;;
    hyprland-preview-share-picker) printf '%s\n' hyprland-preview-share-picker-git ;;
    *) printf '%s\n' "$1" ;;
  esac
}

find_local_pkg() {
  local name=$1 dir f newest=""
  # sudo ./bin/omarchy-mac-iso-make sets HOME=/root; tarballs live in
  # the invoking user's ~/.local/share/omarchy/build-output.
  # ${name}-[0-9]* so "omarchy" does not pick omarchy-keyring / omarchy-settings.
  for dir in \
    ${OMARCHY_LOCAL_PACKAGES:+"$OMARCHY_LOCAL_PACKAGES"} \
    ${sudo_home:+"$sudo_home/.local/share/omarchy/build-output"} \
    ${OMARCHY_PATH:+"$OMARCHY_PATH/build-output"} \
    "${HOME}/.local/share/omarchy/build-output" \
    "${repo_root}/../omarchy-mac/build-output"; do
    [[ -d $dir ]] || continue
    newest=""
    for f in "$dir"/${name}-[0-9]*.pkg.tar.*; do
      [[ -f $f ]] || continue
      newest=$f
    done
    if [[ -n $newest ]]; then
      # Multiple pkgver in one dir: take the last sort -V name.
      newest=$(printf '%s\n' "$dir"/${name}-[0-9]*.pkg.tar.* | sort -V | tail -n1)
      printf '%s\n' "$newest"
      return 0
    fi
  done
  return 1
}

sync_package_dbs() {
  log "Refreshing pacman databases (yay lives in [omarchy-aarch64] edge)"
  pacman -Sy --noconfirm >/dev/null \
    || fail "pacman -Sy failed — cannot resolve payload packages against a stale db"
}

assemble_packages() {
  local omarchy_tree pkg
  local -A skip=() seen=() local_ok=()
  extra_packages=()
  skipped_packages=()
  unresolved_packages=()

  omarchy_tree=$(find_omarchy_tree) \
    || fail "need omarchy-mac with install/omarchy-base.packages (set OMARCHY_PATH)"
  log "Omarchy package lists from $omarchy_tree"

  while read -r pkg; do
    skip[$pkg]=1
  done < <(read_package_names "$omarchy_tree/install/omarchy-aarch64-unavailable.packages")
  while read -r pkg; do
    skip[$pkg]=1
  done < <(read_package_names "$skip_file")
  skip[gpu-screen-recorder]=1
  for pkg in "${forbidden_packages[@]}"; do
    skip[$pkg]=1
  done
  for pkg in "${local_tarball_packages[@]}"; do
    local_ok[$pkg]=1
  done

  while read -r pkg; do
    pkg=$(remap_package "$pkg")
    [[ -n ${seen[$pkg]:-} ]] && continue
    seen[$pkg]=1
    if [[ -n ${skip[$pkg]:-} ]]; then
      skipped_packages+=("$pkg")
      continue
    fi
    if [[ -n ${local_ok[$pkg]:-} ]]; then
      find_local_pkg "$pkg" >/dev/null \
        || fail "local tarball $pkg-*.pkg.tar.* not found (set OMARCHY_LOCAL_PACKAGES)"
      continue
    fi
    if ! package_in_repos "$pkg"; then
      unresolved_packages+=("$pkg")
      continue
    fi
    extra_packages+=("$pkg")
  done < <(
    read_package_names "$packages_file"
    read_package_names "$omarchy_tree/install/omarchy-base.packages"
  )

  (( ${#unresolved_packages[@]} == 0 )) \
    || fail "not in configured repos: ${unresolved_packages[*]} (add a remap, a local tarball, or packages-aarch64-skip)"
  (( ${#extra_packages[@]} > 0 )) || fail "no packages resolved for the USB payload"
  for pkg in "${required_packages[@]}"; do
    printf '%s\n' "${extra_packages[@]}" | grep -qx "$pkg" \
      || fail "required package $pkg was not resolved from repos"
  done
  if (( ${#skipped_packages[@]} > 0 )); then
    log "skipped ${#skipped_packages[@]} packages: ${skipped_packages[*]}"
  fi
}

for pkg in "${forbidden_packages[@]}"; do
  if read_package_names "$packages_file" | grep -qx "$pkg"; then
    fail "refusing to pacstrap $pkg (mounts or rewrites the host ESP)"
  fi
done

sync_package_dbs
assemble_packages

loop=""
mnt=""

# pacstrap rbind-mounts /dev, /proc, /sys. umount of @ is busy until those
# are gone. -R walks children first.
unmount_tree() {
  local dir=$1
  [[ -n $dir && -d $dir ]] || return 0
  findmnt "$dir" >/dev/null || return 0
  umount -R "$dir" 2>/dev/null && return 0
  local target
  while read -r target; do
    umount "$target" 2>/dev/null || true
  done < <(findmnt -Rnc -o TARGET -- "$dir" 2>/dev/null | tac)
  umount "$dir" 2>/dev/null || umount -l "$dir"
}

cleanup() {
  unmount_tree "$mnt" || true
  if [[ -n $loop ]]; then
    losetup -d "$loop" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Mount scratch only. The payload image itself is $out (the USB builder
# puts that under /var/tmp so it is not on tmpfs).
work="$(mktemp -d -p /var/tmp omarchy-mac-iso-rootfs.XXXXXX)"
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
mount -o subvol=@,compress=zstd:1 "$loop" "$mnt"

# Isolate the chroot so alpm hooks cannot mount the host ESP
# (/run/.system-efi → nvme0n1p4). Do not pacstrap asahi-scripts or
# linux-asahi: update-m1n1 is for the installed system, and the live
# kernel is already on the USB ESP. Copy this host's modules so they
# match that kernel (brcmfmac, cdc_ether, …). Firmware is copied from
# the initramfs at boot.
mkdir -p "$mnt/run" "$mnt/boot"
mount -t tmpfs tmpfs "$mnt/run"
mount -t tmpfs tmpfs "$mnt/boot"

log "pacstrap base networkmanager iwd mesa asahi-audio gum + ${#extra_packages[@]} packages"
pacstrap -c "$mnt" base networkmanager iwd mesa asahi-audio \
  alsa-ucm-conf-asahi speakersafetyd pipewire-pulse gum \
  parted gptfdisk btrfs-progs dosfstools grub \
  "${extra_packages[@]}"

local_pkgs=()
for name in omarchy-keyring ttf-jetbrains-mono-nerd-basic omarchy-settings omarchy; do
  f=$(find_local_pkg "$name") \
    || fail "no $name-*.pkg.tar.* (sudo HOME is /root; set OMARCHY_LOCAL_PACKAGES or build omarchy as $SUDO_USER)"
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

# Same drop-in bootstrap.sh / omarchy-provision-owner write. Arch `base`
# comments %wheel out of /etc/sudoers; without this, pacstrap'd sudo cannot
# elevate the desktop user after install.
install -d -m750 "$mnt/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$mnt/etc/sudoers.d/00-omarchy-wheel"
chmod 440 "$mnt/etc/sudoers.d/00-omarchy-wheel"

install -m644 "$repo_root/configs/usb/rootfs/issue" "$mnt/etc/issue"
install -d "$mnt/etc/systemd/system"
install -d "$mnt/etc/systemd/system.conf.d"
install -m644 "$repo_root/configs/usb/rootfs/systemd-show-status.conf" \
  "$mnt/etc/systemd/system.conf.d/show-status.conf"
install -d "$mnt/etc/sysctl.d"
install -m644 "$repo_root/configs/usb/rootfs/sysctl-quiet-console.conf" \
  "$mnt/etc/sysctl.d/90-omarchy-quiet-console.conf"
install -d "$mnt/usr/local/sbin"
install -d "$mnt/usr/local/share/omarchy-mac-iso"
install -m755 "$repo_root/configs/usb/rootfs/omarchy-mac-install" \
  "$mnt/usr/local/sbin/omarchy-mac-install"
install -m755 "$repo_root/configs/usb/rootfs/omarchy-mac-live-welcome" \
  "$mnt/usr/local/sbin/omarchy-mac-live-welcome"
install -d "$mnt/root"
install -m644 "$repo_root/configs/usb/rootfs/root-bash-profile" \
  "$mnt/root/.bash_profile"
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
# ISO-installed desktops keep the hook under the share path, not
# /usr/lib/initcpio.
asahi_initcpio=""
for dir in /usr/lib/initcpio /usr/local/share/omarchy-mac-iso/initcpio; do
  [[ -f $dir/hooks/asahi && -f $dir/install/asahi ]] || continue
  asahi_initcpio=$dir
  break
done
[[ -n $asahi_initcpio ]] \
  || fail "asahi initcpio hook missing (looked in /usr/lib/initcpio and /usr/local/share/omarchy-mac-iso/initcpio)"
install -m644 "$asahi_initcpio/hooks/asahi" \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/hooks/asahi"
install -m644 "$asahi_initcpio/install/asahi" \
  "$mnt/usr/local/share/omarchy-mac-iso/initcpio/install/asahi"
[[ -d /usr/share/asahi-scripts ]] \
  || fail "host /usr/share/asahi-scripts missing"
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
install -m644 "$repo_root/configs/usb/rootfs/omarchy-mac-quiet-console.service" \
  "$mnt/etc/systemd/system/omarchy-mac-quiet-console.service"

systemctl --root="$mnt" enable omarchy-mac-usb-ready.service
systemctl --root="$mnt" enable omarchy-mac-asahi-hw.service
systemctl --root="$mnt" enable omarchy-mac-quiet-console.service
systemctl --root="$mnt" enable NetworkManager.service
systemctl --root="$mnt" enable speakersafetyd.service
systemctl --root="$mnt" --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
systemctl --root="$mnt" set-default multi-user.target

[[ -x $mnt/sbin/init || -L $mnt/sbin/init ]] || fail "pacstrap did not install /sbin/init"
log "payload used $(du -sh "$mnt" | cut -f1) on the @ subvolume"

sync
unmount_tree "$mnt" || {
  findmnt -R "$mnt" >&2 || true
  fail "could not unmount payload $mnt"
}
mnt=""
losetup -d "$loop"
loop=""
trap - EXIT
