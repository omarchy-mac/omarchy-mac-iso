#!/bin/bash
# Usage: build-rootfs.sh <out-payload.img>
# Pacstrap Arch Linux ARM `base` onto btrfs @ (label OMARCHYLIVE).
# Needs root. This is S3: systemd userspace, not the Omarchy desktop.
set -euo pipefail

out="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
payload_bytes=${OMARCHY_USB_PAYLOAD_BYTES:-$((2 * 1024 * 1024 * 1024))}

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail "build-rootfs.sh needs root (pacstrap + mount)"
command -v pacstrap >/dev/null || fail "pacstrap not found — pacman -S arch-install-scripts"
command -v mkfs.btrfs >/dev/null || fail "need btrfs-progs"
command -v losetup >/dev/null || fail "need losetup"

loop=""
mnt=""
cleanup() {
  if [[ -n $mnt ]]; then
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

# Kernel is still loaded from the ESP; linux-asahi here is for modules
# (brcmfmac, cdc_ether, …) after switch_root. Firmware is copied from the
# initramfs at boot (internal ESP), not baked in.
log "pacstrap base linux-asahi networkmanager iwd"
pacstrap -c "$mnt" base linux-asahi networkmanager iwd asahi-scripts

install -m644 "$repo_root/configs/usb/rootfs/issue" "$mnt/etc/issue"
install -d "$mnt/etc/systemd/system"
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
cat >"$mnt/etc/NetworkManager/conf.d/wifi_backend.conf" <<'EOF'
[device]
wifi.backend=iwd
EOF

systemctl --root="$mnt" enable omarchy-mac-usb-ready.service
systemctl --root="$mnt" enable NetworkManager.service
systemctl --root="$mnt" set-default multi-user.target

[[ -x $mnt/sbin/init || -L $mnt/sbin/init ]] || fail "pacstrap did not install /sbin/init"
log "payload used $(du -sh "$mnt" | cut -f1) on the @ subvolume"

sync
umount "$mnt"
mnt=""
losetup -d "$loop"
loop=""
trap - EXIT
