#!/bin/bash
# Usage: build-usb-image.sh <out-dir>
# Native Apple Silicon build: NVMe installer file set by default. With
# OMARCHY_USB_DISK_IMAGE=1, also wrap a GPT image with a FAT ESP plus a btrfs
# payload partition (label OMARCHYLIVE, subvol=@).
set -euo pipefail

out_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kver="${OMARCHY_KVER:-$(uname -r)}"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $(uname -m) == aarch64 ]] || fail "--usb needs an aarch64 host (this builds linux-asahi into the image)"
# Alarm puts the kernel at /boot/vmlinuz-linux-asahi. Omarchy piggyback ESP
# keeps it under EFI/omarchy/ so grub-mkconfig does not pick it up. Do not
# pacman linux-asahi on an Omarchy ESP (update-m1n1).
host_vmlinuz=""
if [[ -n ${OMARCHY_VMLINUZ:-} ]]; then
  [[ -f $OMARCHY_VMLINUZ ]] || fail "OMARCHY_VMLINUZ=$OMARCHY_VMLINUZ is missing"
  host_vmlinuz=$OMARCHY_VMLINUZ
else
  for f in /boot/vmlinuz-linux-asahi /boot/EFI/omarchy/vmlinuz; do
    [[ -f $f ]] || continue
    host_vmlinuz=$f
    break
  done
fi
[[ -n $host_vmlinuz ]] \
  || fail "no host linux-asahi vmlinuz (tried /boot/vmlinuz-linux-asahi and /boot/EFI/omarchy/vmlinuz)"
# M3 DCP needs appledrm v14.7 (>= asahi-wip-7.2). 7.1.6 falls back to simpledrm.
# The 7.2 module spells it iomfb_*_v14_7_0, not V14_7. grep -a on the .ko —
# `strings | grep -q` under pipefail exits 141 (SIGPIPE) on a match.
appledrm_ko=""
moddir=${OMARCHY_MODULES_DIR:-/usr/lib/modules/$kver}
for f in "$moddir"/kernel/drivers/gpu/drm/apple/appledrm.ko*; do
  [[ -f $f ]] || continue
  appledrm_ko=$f
  break
done
if [[ -z $appledrm_ko ]]; then
  fail "no appledrm.ko under $moddir (set OMARCHY_MODULES_DIR / OMARCHY_KVER)"
fi
if ! grep -aqi 'v14_7' "$appledrm_ko"; then
  if [[ ${OMARCHY_ALLOW_OLD_APPLEDRM:-} == 1 ]]; then
    log "warning: $kver appledrm has no v14.7 — M3 will stay on simpledrm"
  else
    fail "$kver appledrm ($appledrm_ko) has no v14.7 (need linux-asahi >= 7.2 for M3 DCP). Build on a 7.2 host, or set OMARCHY_KVER/OMARCHY_VMLINUZ/OMARCHY_MODULES_DIR, or OMARCHY_ALLOW_OLD_APPLEDRM=1 for a simpledrm image"
  fi
fi
log "appledrm $appledrm_ko (v14.7 ok)"
command -v mkinitcpio >/dev/null || fail "mkinitcpio not found (pacman -S mkinitcpio)"
command -v grub-mkstandalone >/dev/null || fail "grub-mkstandalone not found (pacman -S grub)"
command -v zstd >/dev/null || fail "zstd not found (pacman -S zstd)"
wrap_disk=0
[[ ${OMARCHY_USB_DISK_IMAGE:-} == 1 ]] && wrap_disk=1
if (( wrap_disk == 1 )); then
  command -v mkfs.vfat >/dev/null || fail "mkfs.vfat not found (pacman -S dosfstools)"
  command -v parted >/dev/null || fail "parted not found"
  command -v udisksctl >/dev/null || fail "udisksctl not found"
fi

# /tmp is often a small tmpfs (16GiB here). A 12GiB payload plus pacstrap
# does not fit; transaction aborted looks like a random pacman failure.
work="$(mktemp -d -p /var/tmp omarchy-mac-iso.XXXXXX)"
log "work dir $work (not /tmp tmpfs)"
loop_dev=""
esp_priv=0
modules_bind=0
host_moddir=/lib/modules/$kver
cleanup() {
  if (( modules_bind == 1 )); then
    umount "$host_moddir" 2>/dev/null || umount -l "$host_moddir" 2>/dev/null || true
    rmdir "$host_moddir" 2>/dev/null || true
  fi
  if [[ -n $loop_dev ]]; then
    if (( esp_priv == 1 )); then
      umount "$loop_dev" 2>/dev/null || umount -l "$loop_dev" 2>/dev/null || true
      losetup -d "$loop_dev" 2>/dev/null || true
    else
      udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
      udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null 2>&1 || true
    fi
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

# asahi-scripts is not pacstrapped. ISO-installed hosts keep the hook under
# the share path, not /usr/lib/initcpio.
mkinitcpio_dirs=(-D /usr/lib/initcpio -D "$repo_root/configs/usb-initcpio")
asahi_hook=""
for dir in /usr/lib/initcpio /usr/local/share/omarchy-mac-iso/initcpio; do
  [[ -f $dir/hooks/asahi ]] || continue
  asahi_hook=$dir/hooks/asahi
  [[ $dir == /usr/lib/initcpio ]] || mkinitcpio_dirs+=(-D "$dir")
  break
done
[[ -n $asahi_hook ]] \
  || fail "asahi mkinitcpio hook missing (looked in /usr/lib/initcpio and /usr/local/share/omarchy-mac-iso/initcpio)"

# mkinitcpio -k $kver only reads /lib/modules/$kver. A side-loaded tree
# (OMARCHY_MODULES_DIR) is not visible unless it is mounted there. Use a
# bind mount, not a symlink: kms find() does not follow a modules-dir link.
if [[ ! -d $host_moddir/kernel ]]; then
  [[ -d $moddir/kernel ]] \
    || fail "no kernel/ under $moddir (set OMARCHY_MODULES_DIR)"
  mkdir -p "$host_moddir"
  mount --bind "$moddir" "$host_moddir" \
    || fail "could not bind $moddir onto $host_moddir for mkinitcpio"
  modules_bind=1
  log "bound $moddir -> $host_moddir for mkinitcpio"
fi

log "Building live initramfs (linux-asahi $kver, dwc3-apple)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio.conf" \
  "${mkinitcpio_dirs[@]}" \
  -k "$kver" \
  -g "$work/initramfs-omarchy-usb.img"

log "Building install initramfs (USB root, LUKS)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio-install.conf" \
  "${mkinitcpio_dirs[@]}" \
  -k "$kver" \
  -g "$work/initramfs-linux-asahi.img"

log "Building install initramfs (unencrypted, no encrypt hook)"
mkinitcpio -n \
  -c "$repo_root/configs/usb-initcpio/mkinitcpio-install-plain.conf" \
  "${mkinitcpio_dirs[@]}" \
  -k "$kver" \
  -g "$work/initramfs-linux-asahi-plain.img"

# kms uses find() on /lib/modules/$kver, which does not follow a modules-dir
# symlink (OMARCHY_MODULES_DIR). Name appledrm in MODULES so Plymouth/DCP
# still get the 7.2 driver when the host is 7.1.6 with a side-loaded tree.
for img in "$work/initramfs-linux-asahi.img" "$work/initramfs-linux-asahi-plain.img"; do
  lsinitcpio "$img" | grep -q 'appledrm\.ko' \
    || fail "$(basename "$img") missing appledrm.ko (set OMARCHY_KVER / OMARCHY_MODULES_DIR, and keep appledrm in the install mkinitcpio MODULES)"
done

log "Building standalone GRUB"
grub-mkstandalone -O arm64-efi \
  --fonts="" --locales="" --themes="" \
  --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile test gzio reboot sleep" \
  --modules="part_gpt fat search search_fs_file configfile linux echo normal test" \
  -o "$work/BOOTAA64.EFI" \
  "boot/grub/grub.cfg=$repo_root/configs/usb/grub-embed.cfg"

log "Building standalone NVMe-live GRUB"
grub-mkstandalone -O arm64-efi \
  --fonts="" --locales="" --themes="" \
  --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile test gzio reboot sleep" \
  --modules="part_gpt fat search search_fs_file configfile linux echo normal test" \
  -o "$work/BOOTAA64-NVME.EFI" \
  "boot/grub/grub.cfg=$repo_root/configs/usb/grub-embed-nvme.cfg"

if (( wrap_disk == 1 )); then
  # 512 MiB FAT ESP, then the btrfs payload, 1 MiB GPT head/tail.
  fat_mib=512
  fat_kb=$((fat_mib * 1024))
  esp_end_mib=$((1 + fat_mib))
  payload_end_mib=$((esp_end_mib + payload_mib))
  disk_bytes=$(( (payload_end_mib + 1) * 1024 * 1024 ))

  log "Formatting ESP"
  mkfs.vfat -F 32 -n OMARCHYISO -C "$work/esp.fat" "$fat_kb" >/dev/null

  log "Populating ESP"
  # A plugged-in live USB is also labelled OMARCHYISO. udisks then auto-mounts
  # this loop (same label) at /run/media/scott/OMARCHYISO and "AlreadyMounted"
  # races the explicit mount. Root builds loop-mount privately.
  mnt=""
  if (( EUID == 0 )); then
    loop_dev="$(losetup -f --show "$work/esp.fat")"
    [[ -n $loop_dev ]] || fail "losetup failed for $work/esp.fat"
    mkdir -p "$work/esp"
    mount "$loop_dev" "$work/esp"
    mnt=$work/esp
    esp_priv=1
  else
    map_out="$(udisksctl loop-setup -f "$work/esp.fat" --no-user-interaction)"
    loop_dev="$(printf '%s\n' "$map_out" | grep -oE '/dev/loop[0-9]+')"
    [[ -n $loop_dev ]] || fail "udisksctl loop-setup did not print a loop device"
    for _ in $(seq 1 20); do
      mnt="$(findmnt -n -o TARGET "$loop_dev" 2>/dev/null | awk 'NR==1{print; exit}')"
      [[ -n $mnt && -d $mnt ]] && break
      sleep 0.2
    done
    if [[ -z $mnt || ! -d $mnt ]]; then
      mount_out="$(udisksctl mount -b "$loop_dev" --no-user-interaction 2>&1)" || true
      mnt="$(findmnt -n -o TARGET "$loop_dev" 2>/dev/null | awk 'NR==1{print; exit}')"
      if [[ -z $mnt ]]; then
        mnt="$(printf '%s\n' "$mount_out" | awk '{print $NF}' | tr -d '.')"
      fi
    fi
  fi
  [[ -d $mnt ]] || fail "could not mount ESP FAT image"

  mkdir -p "$mnt/EFI/BOOT" "$mnt/grub"
  cp "$work/BOOTAA64.EFI" "$mnt/EFI/BOOT/BOOTAA64.EFI"
  cp "$repo_root/configs/usb/grub.cfg" "$mnt/EFI/BOOT/grub.cfg"
  cp "$repo_root/configs/usb/grub.cfg" "$mnt/grub/grub.cfg"
  : >"$mnt/omarchy-usb-live"
  cp "$host_vmlinuz" "$mnt/vmlinuz-linux-asahi"
  cp "$work/initramfs-omarchy-usb.img" "$mnt/initramfs-omarchy-usb.img"
  cp "$work/initramfs-linux-asahi.img" "$mnt/initramfs-linux-asahi.img"
  cp "$work/initramfs-linux-asahi-plain.img" "$mnt/initramfs-linux-asahi-plain.img"
  sync

  if (( esp_priv == 1 )); then
    umount "$mnt"
    losetup -d "$loop_dev"
  else
    udisksctl unmount -b "$loop_dev" --no-user-interaction >/dev/null
    udisksctl loop-delete -b "$loop_dev" --no-user-interaction >/dev/null
  fi
  loop_dev=""
  esp_priv=0

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
else
  log "Skipping GPT disk image (pass --disk-image for omarchy-mac-usb.img)"
  rm -f "$out_dir/omarchy-mac-usb.img"
fi

cp "$work/BOOTAA64.EFI" "$out_dir/BOOTAA64.EFI"
cp "$work/BOOTAA64-NVME.EFI" "$out_dir/BOOTAA64-NVME.EFI"
cp "$work/initramfs-omarchy-usb.img" "$out_dir/initramfs-omarchy-usb.img"
cp "$work/initramfs-linux-asahi.img" "$out_dir/initramfs-linux-asahi.img"
cp "$work/initramfs-linux-asahi-plain.img" "$out_dir/initramfs-linux-asahi-plain.img"
cp "$work/payload.img" "$out_dir/payload.img"
cp "$host_vmlinuz" "$out_dir/vmlinuz-linux-asahi"
cp "$repo_root/configs/usb/grub.cfg" "$out_dir/grub.cfg"
cp "$repo_root/configs/usb/grub-nvme-installer.cfg" "$out_dir/grub-nvme-installer.cfg"
rm -f "$out_dir/linux-asahi.config"
kernel_config=${OMARCHY_KERNEL_CONFIG:-$moddir/build/.config}
if [[ -f $kernel_config ]]; then
  cp "$kernel_config" "$out_dir/linux-asahi.config"
fi
# SHARE / Drive copies cannot hold the 12GiB raw payload. Keep payload.img
# on the builder for loop-mounts; testers take payload.img.zst.
zstd_level=${OMARCHY_PAYLOAD_ZSTD_LEVEL:-19}
log "compressing payload.img (zstd -$zstd_level) for testers"
zstd -T0 -"$zstd_level" -f "$out_dir/payload.img" -o "$out_dir/payload.img.zst"
# mkinitcpio writes 600; the release dir is for copying onto a Mac.
chmod a+r "$out_dir"/initramfs-*.img "$out_dir"/vmlinuz-linux-asahi \
  "$out_dir"/payload.img "$out_dir"/payload.img.zst \
  "$out_dir"/BOOTAA64.EFI "$out_dir"/BOOTAA64-NVME.EFI

git_ref="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
source_state=clean
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=normal 2>/dev/null) ]] \
  || source_state=dirty
artifact=omarchy-mac-nvme-installer-files
(( wrap_disk == 1 )) && artifact=omarchy-mac-usb-and-nvme-installer-files
payload_kind="busybox pid 1"
[[ ${OMARCHY_USB_ROOTFS:-} == 1 ]] && payload_kind="systemd + Omarchy shell (hyprland/quickshell/sddm, multi-user.target)"
{
  printf 'artifact: %s\n' "$artifact"
  printf 'built_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'built_from_ref: %s\n' "$git_ref"
  printf 'source_state: %s\n' "$source_state"
  printf 'kernel: linux-asahi %s\n' "$kver"
  printf 'kernel_source_ref: %s\n' "${OMARCHY_KERNEL_SOURCE_REF:-not-recorded}"
  printf 'target_scope: Apple Silicon; M3 j613 has an additional DCP enhancement\n'
  if (( wrap_disk == 1 )); then
    printf 'contract: GPT disk image, FAT32 ESP labelled OMARCHYISO + btrfs payload labelled OMARCHYLIVE (subvol=@)\n'
    printf '  EFI/BOOT/BOOTAA64.EFI (grub-mkstandalone)\n'
    printf '  /vmlinuz-linux-asahi + /initramfs-omarchy-usb.img on the ESP\n'
    printf '  payload: %s\n' "$payload_kind"
    printf 'flash: dd if=omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync\n'
  else
    printf 'contract: NVMe/live installer files (no GPT disk image)\n'
    printf '  payload.img (btrfs OMARCHYLIVE subvol=@) and payload.img.zst for testers\n'
    printf '  BOOTAA64.EFI BOOTAA64-NVME.EFI vmlinuz-linux-asahi initramfs-omarchy-usb.img\n'
    printf '  initramfs-linux-asahi.img initramfs-linux-asahi-plain.img\n'
    printf '  grub-nvme-installer.cfg\n'
    printf '  payload: %s\n' "$payload_kind"
    printf 'place: scripts/macos/place-nvme-installer.sh --payload payload.img.zst --esp-files .\n'
    printf 'disk-image: pass --disk-image to also wrap omarchy-mac-usb.img\n'
  fi
} >"$out_dir/BUILD_INFO"

log "Writing SHA256SUMS"
(
  cd "$out_dir"
  mapfile -d '' checksum_files < <(
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' | sort -z
  )
  (( ${#checksum_files[@]} > 0 )) || fail "no output files to checksum"
  sha256sum -- "${checksum_files[@]}"
) >"$out_dir/SHA256SUMS"
chmod a+r "$out_dir/BUILD_INFO" "$out_dir/SHA256SUMS"

if (( wrap_disk == 1 )); then
  log "Wrote $disk ($(du -h "$disk" | cut -f1))"
fi
log "Wrote $out_dir/payload.img ($(du -h "$out_dir/payload.img" | cut -f1))"
log "Wrote $out_dir/payload.img.zst ($(du -h "$out_dir/payload.img.zst" | cut -f1))"
