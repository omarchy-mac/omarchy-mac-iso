#!/bin/bash
# System ESP GRUB helpers. Safe to source from tests.
# Never write m1n1/, vendorfw/, or asahi/. Never mkfs.vfat the ESP.

esp_has_bootloader() {
  local esp_mnt=$1
  [[ -f $esp_mnt/EFI/BOOT/BOOTAA64.EFI ]]
}

esp_protected_hashes() {
  local esp_mnt=$1
  (cd "$esp_mnt" && find asahi m1n1 vendorfw EFI/asahi -type f 2>/dev/null | sort | xargs -r sha256sum) || true
}

# Copy an existing ESP file to *.omarchy-bak next to it (on the ESP, so
# macOS can restore without the USB). If that bak already exists, keep
# it and write a timestamped copy. No-op if the source is missing.
esp_backup_existing() {
  local esp_mnt=$1 rel=$2
  local src=$esp_mnt/$rel dest
  [[ -f $src ]] || return 0
  dest=$src.omarchy-bak
  if [[ -e $dest ]]; then
    dest=$src.omarchy-bak.$(date +%Y%m%d%H%M%S)
    n=0
    while [[ -e $dest ]]; do
      n=$((n + 1))
      dest=$src.omarchy-bak.$(date +%Y%m%d%H%M%S).$n
    done
  fi
  cp -a "$src" "$dest" || return 1
  printf '==> ESP backup %s -> %s\n' "$rel" "${dest#"$esp_mnt"/}" >&2
}

# Under EFI/omarchy/ so grub-mkconfig 10_linux (/boot/vmlinuz-*) does
# not treat the installer kernel as the default Omarchy entry.
esp_copy_unique_kernels() {
  local live_esp_mnt=$1 esp_mnt=$2
  [[ -f $live_esp_mnt/vmlinuz-linux-asahi ]] || return 1
  [[ -f $live_esp_mnt/initramfs-linux-asahi.img ]] || return 1
  mkdir -p "$esp_mnt/EFI/omarchy"
  esp_backup_existing "$esp_mnt" EFI/omarchy/vmlinuz || return 1
  esp_backup_existing "$esp_mnt" EFI/omarchy/initramfs.img || return 1
  cp "$live_esp_mnt/vmlinuz-linux-asahi" "$esp_mnt/EFI/omarchy/vmlinuz"
  cp "$live_esp_mnt/initramfs-linux-asahi.img" "$esp_mnt/EFI/omarchy/initramfs.img"
}

# Piggyback on an OS that already owns BOOTAA64.EFI (custom.cfg only).
write_piggyback_esp_grub() {
  local esp_mnt=$1 root_uuid=$2
  mkdir -p "$esp_mnt/grub"
  esp_backup_existing "$esp_mnt" grub/custom.cfg || return 1
  esp_backup_existing "$esp_mnt" grub/grub.cfg || return 1
  : >"$esp_mnt/omarchy-mac-root"
  cat >"$esp_mnt/grub/custom.cfg" <<EOF
menuentry 'Omarchy Mac (new root $root_uuid)' {
  search --no-floppy --file /omarchy-mac-root --set=root
  linux /EFI/omarchy/vmlinuz root=UUID=$root_uuid rw rootflags=subvol=@ loglevel=3
  initrd /EFI/omarchy/initramfs.img
}
EOF
  if [[ -f $esp_mnt/grub/grub.cfg ]] && ! grep -q custom.cfg "$esp_mnt/grub/grub.cfg"; then
    printf '\nif [ -f /grub/custom.cfg ]; then source /grub/custom.cfg; fi\n' \
      >>"$esp_mnt/grub/grub.cfg"
  fi
}

# Take over a UEFI-only System ESP: write BOOTAA64.EFI next to m1n1.
# $3 is grub-embed-system.cfg. Does not touch m1n1/vendorfw/asahi.
write_owned_esp_grub() {
  local esp_mnt=$1 root_uuid=$2 embed_cfg=$3
  [[ -f $embed_cfg ]] || return 1
  command -v grub-mkstandalone >/dev/null || return 1
  mkdir -p "$esp_mnt/EFI/BOOT" "$esp_mnt/grub"
  # BOOTAA64 is usually missing in own-mode; grub.cfg often still has the
  # previous OS menu — that is the file that locked this machine out.
  esp_backup_existing "$esp_mnt" EFI/BOOT/BOOTAA64.EFI || return 1
  esp_backup_existing "$esp_mnt" EFI/BOOT/grub.cfg || return 1
  esp_backup_existing "$esp_mnt" grub/grub.cfg || return 1
  : >"$esp_mnt/omarchy-mac-root"
  cat >"$esp_mnt/grub/grub.cfg" <<EOF
echo '========================================'
echo '  OMARCHY MAC (System ESP, not USB)'
echo '========================================'
set timeout=8
set default=0

search --no-floppy --file /omarchy-mac-root --set=root

menuentry 'Omarchy Mac' {
  linux /EFI/omarchy/vmlinuz root=UUID=$root_uuid rw rootflags=subvol=@ loglevel=3
  initrd /EFI/omarchy/initramfs.img
}
EOF
  cp "$esp_mnt/grub/grub.cfg" "$esp_mnt/EFI/BOOT/grub.cfg"
  grub-mkstandalone -O arm64-efi \
    --fonts="" --locales="" --themes="" \
    --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile gzio reboot sleep" \
    --modules="part_gpt fat search search_fs_file configfile linux echo normal" \
    -o "$esp_mnt/EFI/BOOT/BOOTAA64.EFI" \
    "boot/grub/grub.cfg=$embed_cfg" >/dev/null
}

# Print /dev/NAME of btrfs labelled OMARCHYROOT on $1 (disk NAME).
existing_omarchy_root_on() {
  local disk=$1 name fstype label
  while read -r name fstype label; do
    [[ $name == "$disk" ]] && continue
    [[ $fstype == btrfs && $label == OMARCHYROOT ]] || continue
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -ln -o NAME,FSTYPE,LABEL "/dev/$disk" 2>/dev/null)
  return 1
}
