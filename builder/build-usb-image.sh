#!/bin/bash
# Usage: build-usb-image.sh <out-dir>
# Native Apple Silicon build: GPT disk image with a FAT ESP (GRUB, linux-asahi,
# live initramfs, root.img). Unprivileged: udisks loop-mounts a FAT file.
set -euo pipefail

out_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kver="$(uname -r)"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $(uname -m) == aarch64 ]] || fail "--usb needs an aarch64 host (this builds linux-asahi into the image)"
[[ -f /boot/vmlinuz-linux-asahi ]] || fail "no /boot/vmlinuz-linux-asahi — install linux-asahi"
command -v mkinitcpio >/dev/null || fail "mkinitcpio not found"
command -v grub-mkstandalone >/dev/null || fail "grub-mkstandalone not found (pacman -S grub)"
command -v mkfs.vfat >/dev/null || fail "mkfs.vfat not found (pacman -S dosfstools)"
command -v parted >/dev/null || fail "parted not found"
command -v udisksctl >/dev/null || fail "udisksctl not found"

work="$(mktemp -d)"
loop_dev=""
cleanup() {
  if [[ -n $loop_dev ]]; then
    udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
    udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work" "$out_dir"

log "Building root.img"
"$repo_root/builder/build-usb-rootimg.sh" "$work/root.img"

log "Building live initramfs (linux-asahi $kver, dwc3-apple)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio.conf" \
  -D /usr/lib/initcpio \
  -D "$repo_root/configs/usb-initcpio" \
  -k "$kver" \
  -g "$work/initramfs-omarchy-usb.img"

log "Building standalone GRUB"
grub-mkstandalone -O arm64-efi \
  --fonts="" --locales="" --themes="" \
  --install-modules="linux fat ext2 part_gpt search search_label search_fs_uuid echo normal configfile gzio reboot sleep" \
  --modules="part_gpt fat search search_label linux echo normal" \
  -o "$work/BOOTAA64.EFI" \
  "boot/grub/grub.cfg=$repo_root/configs/usb/grub.cfg"

# 512 MiB FAT ESP, GPT wrapper with 1 MiB headroom.
fat_kb=$((512 * 1024))
fat_bytes=$((fat_kb * 1024))
disk_bytes=$((fat_bytes + 2 * 1024 * 1024))

log "Formatting ESP"
mkfs.vfat -F 32 -n OMARCHYISO -C "$work/esp.fat" "$fat_kb" >/dev/null

log "Populating ESP"
map_out="$(udisksctl loop-setup -f "$work/esp.fat" --no-user-interaction)"
loop_dev="$(printf '%s\n' "$map_out" | grep -oE '/dev/loop[0-9]+')"
[[ -n $loop_dev ]] || fail "udisksctl loop-setup did not print a loop device"

# udisks often auto-mounts; wait for it
mnt=""
for _ in $(seq 1 20); do
  mnt="$(findmnt -n -o TARGET "$loop_dev" 2>/dev/null || true)"
  [[ -n $mnt ]] && break
  sleep 0.2
done
if [[ -z $mnt ]]; then
  mount_out="$(udisksctl mount -b "$loop_dev" --no-user-interaction)"
  mnt="$(printf '%s\n' "$mount_out" | awk '{print $NF}' | tr -d '.')"
fi
[[ -d $mnt ]] || fail "could not mount ESP FAT image"

mkdir -p "$mnt/EFI/BOOT" "$mnt/grub"
cp "$work/BOOTAA64.EFI" "$mnt/EFI/BOOT/BOOTAA64.EFI"
cp "$repo_root/configs/usb/grub.cfg" "$mnt/grub/grub.cfg"
cp /boot/vmlinuz-linux-asahi "$mnt/vmlinuz-linux-asahi"
cp "$work/initramfs-omarchy-usb.img" "$mnt/initramfs-omarchy-usb.img"
cp "$work/root.img" "$mnt/root.img"
sync

udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null
udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null
loop_dev=""

log "Wrapping GPT disk image"
disk="$out_dir/omarchy-mac-usb.img"
rm -f "$disk"
truncate -s "$disk_bytes" "$disk"
parted -s "$disk" mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 esp on
dd if="$work/esp.fat" of="$disk" bs=1M seek=1 conv=notrunc status=none

# Loose copies for iterating onto an existing stick without dd.
cp "$work/BOOTAA64.EFI" "$out_dir/BOOTAA64.EFI"
cp "$work/initramfs-omarchy-usb.img" "$out_dir/initramfs-omarchy-usb.img"
cp "$work/root.img" "$out_dir/root.img"
cp /boot/vmlinuz-linux-asahi "$out_dir/vmlinuz-linux-asahi"
cp "$repo_root/configs/usb/grub.cfg" "$out_dir/grub.cfg"

git_ref="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat > "$out_dir/BUILD_INFO" <<EOF
artifact: omarchy-mac-usb
built_from_ref: $git_ref
kernel: linux-asahi $kver
contract: GPT disk image, one FAT32 ESP labelled OMARCHYISO
  EFI/BOOT/BOOTAA64.EFI (grub-mkstandalone)
  /vmlinuz-linux-asahi + /initramfs-omarchy-usb.img + /root.img
flash: dd if=omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
EOF

log "Wrote $disk ($(du -h "$disk" | cut -f1))"
