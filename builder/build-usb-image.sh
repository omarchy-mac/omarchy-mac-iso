#!/bin/bash
# Usage: build-usb-image.sh <out-dir>
# Native Apple Silicon build: GPT disk image with a FAT ESP (GRUB, linux-asahi,
# live initramfs) plus a btrfs payload partition (label OMARCHYLIVE, subvol=@).
# Unprivileged: udisks loop-mounts the filesystem images; dd into the GPT file.
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

log "Building btrfs payload (OMARCHYLIVE)"
if [[ ${OMARCHY_USB_ROOTFS:-} == 1 ]]; then
  "$repo_root/builder/build-rootfs.sh" "$work/payload.img"
else
  "$repo_root/builder/build-usb-rootimg.sh" "$work/payload.img"
fi
payload_bytes=$(stat -c %s "$work/payload.img")
payload_mib=$(( (payload_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))

log "Building live initramfs (linux-asahi $kver, dwc3-apple)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio.conf" \
  -D /usr/lib/initcpio \
  -D "$repo_root/configs/usb-initcpio" \
  -k "$kver" \
  -g "$work/initramfs-omarchy-usb.img"

log "Building install initramfs (USB root, no overlay)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio-install.conf" \
  -D /usr/lib/initcpio \
  -D "$repo_root/configs/usb-initcpio" \
  -k "$kver" \
  -g "$work/initramfs-linux-asahi.img"

log "Building standalone GRUB"
grub-mkstandalone -O arm64-efi \
  --fonts="" --locales="" --themes="" \
  --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile gzio reboot sleep" \
  --modules="part_gpt fat search search_fs_file configfile linux echo normal" \
  -o "$work/BOOTAA64.EFI" \
  "boot/grub/grub.cfg=$repo_root/configs/usb/grub-embed.cfg"

# 512 MiB FAT ESP, then the btrfs payload, 1 MiB GPT head/tail.
fat_mib=512
fat_kb=$((fat_mib * 1024))
esp_end_mib=$((1 + fat_mib))
payload_end_mib=$((esp_end_mib + payload_mib))
disk_bytes=$(( (payload_end_mib + 1) * 1024 * 1024 ))

log "Formatting ESP"
mkfs.vfat -F 32 -n OMARCHYISO -C "$work/esp.fat" "$fat_kb" >/dev/null

log "Populating ESP"
map_out="$(udisksctl loop-setup -f "$work/esp.fat" --no-user-interaction)"
loop_dev="$(printf '%s\n' "$map_out" | grep -oE '/dev/loop[0-9]+')"
[[ -n $loop_dev ]] || fail "udisksctl loop-setup did not print a loop device"

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
cp "$repo_root/configs/usb/grub.cfg" "$mnt/EFI/BOOT/grub.cfg"
cp "$repo_root/configs/usb/grub.cfg" "$mnt/grub/grub.cfg"
: >"$mnt/omarchy-usb-live"
cp /boot/vmlinuz-linux-asahi "$mnt/vmlinuz-linux-asahi"
cp "$work/initramfs-omarchy-usb.img" "$mnt/initramfs-omarchy-usb.img"
cp "$work/initramfs-linux-asahi.img" "$mnt/initramfs-linux-asahi.img"
sync

udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null
udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null
loop_dev=""

log "Wrapping GPT disk image (ESP ${fat_mib}MiB + payload ${payload_mib}MiB)"
disk="$out_dir/omarchy-mac-usb.img"
rm -f "$disk"
truncate -s "$disk_bytes" "$disk"
parted -s "$disk" mklabel gpt \
  mkpart ESP fat32 1MiB "${esp_end_mib}MiB" \
  set 1 esp on \
  mkpart payload btrfs "${esp_end_mib}MiB" "${payload_end_mib}MiB"
dd if="$work/esp.fat" of="$disk" bs=1M seek=1 conv=notrunc status=none
dd if="$work/payload.img" of="$disk" bs=1M seek="$esp_end_mib" conv=notrunc status=none

cp "$work/BOOTAA64.EFI" "$out_dir/BOOTAA64.EFI"
cp "$work/initramfs-omarchy-usb.img" "$out_dir/initramfs-omarchy-usb.img"
cp "$work/initramfs-linux-asahi.img" "$out_dir/initramfs-linux-asahi.img"
cp "$work/payload.img" "$out_dir/payload.img"
cp /boot/vmlinuz-linux-asahi "$out_dir/vmlinuz-linux-asahi"
cp "$repo_root/configs/usb/grub.cfg" "$out_dir/grub.cfg"

git_ref="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
payload_kind="busybox pid 1"
[[ ${OMARCHY_USB_ROOTFS:-} == 1 ]] && payload_kind="systemd + Omarchy shell (hyprland/quickshell/sddm, multi-user.target)"
cat > "$out_dir/BUILD_INFO" <<EOF
artifact: omarchy-mac-usb
built_from_ref: $git_ref
kernel: linux-asahi $kver
contract: GPT disk image, FAT32 ESP labelled OMARCHYISO + btrfs payload labelled OMARCHYLIVE (subvol=@)
  EFI/BOOT/BOOTAA64.EFI (grub-mkstandalone)
  /vmlinuz-linux-asahi + /initramfs-omarchy-usb.img on the ESP
  payload: $payload_kind
flash: dd if=omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
EOF

log "Wrote $disk ($(du -h "$disk" | cut -f1))"
