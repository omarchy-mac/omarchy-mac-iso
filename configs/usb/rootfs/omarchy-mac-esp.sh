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
  local src=$esp_mnt/$rel dest n=0
  [[ -f $src ]] || return 0
  dest=$src.omarchy-bak
  if [[ -e $dest ]]; then
    dest=$src.omarchy-bak.$(date +%Y%m%d%H%M%S)
    while [[ -e $dest ]]; do
      n=$((n + 1))
      dest=$src.omarchy-bak.$(date +%Y%m%d%H%M%S).$n
    done
  fi
  cp -a "$src" "$dest" || return 1
  printf '==> ESP backup %s -> %s\n' "$rel" "${dest#"$esp_mnt"/}" >&2
}

# 64MiB: one kernel + initrd plus slack. A full ESP mid-write is unbootable.
ESP_MIN_FREE_BYTES=$((64 * 1024 * 1024))

esp_require_free_bytes() {
  local esp_mnt=$1 need=${2:-$ESP_MIN_FREE_BYTES}
  local avail_kb
  avail_kb=$(df -Pk "$esp_mnt" | awk 'NR==2 { print $4 }')
  [[ $avail_kb =~ ^[0-9]+$ ]] || return 1
  (( avail_kb * 1024 >= need )) || {
    printf 'error: ESP %s has %sKiB free, need %s bytes\n' \
      "$esp_mnt" "$avail_kb" "$need" >&2
    return 1
  }
}

# Under EFI/omarchy/ so grub-mkconfig 10_linux (/boot/vmlinuz-*) does
# not treat the installer kernel as the default Omarchy entry.
# Drop the legacy ESP-root names from earlier installs; do not bak
# EFI/omarchy/ — those files are ours and ~50MiB each copy.
esp_copy_unique_kernels() {
  local live_esp_mnt=$1 esp_mnt=$2
  [[ -f $live_esp_mnt/vmlinuz-linux-asahi ]] || return 1
  [[ -f $live_esp_mnt/initramfs-linux-asahi.img ]] || return 1
  esp_require_free_bytes "$esp_mnt" || return 1
  mkdir -p "$esp_mnt/EFI/omarchy"
  cp "$live_esp_mnt/vmlinuz-linux-asahi" "$esp_mnt/EFI/omarchy/vmlinuz"
  cp "$live_esp_mnt/initramfs-linux-asahi.img" "$esp_mnt/EFI/omarchy/initramfs.img"
  rm -f "$esp_mnt/vmlinuz-omarchy-usb-root" \
    "$esp_mnt/initramfs-omarchy-usb-root.img"
}

# linux line for an installed root. $2 is the LUKS UUID when encrypted.
root_linux_args() {
  local root_uuid=$1 luks_uuid=${2:-}
  if [[ -n $luks_uuid ]]; then
    printf 'root=UUID=%s rw rootflags=subvol=@ cryptdevice=UUID=%s:root:allow-discards loglevel=3 quiet splash' \
      "$root_uuid" "$luks_uuid"
  else
    printf 'root=UUID=%s rw rootflags=subvol=@ loglevel=3 quiet splash' "$root_uuid"
  fi
}

# Piggyback on an OS that already owns BOOTAA64.EFI (custom.cfg only).
# $3 is the LUKS UUID when the new root is encrypted.
write_piggyback_esp_grub() {
  local esp_mnt=$1 root_uuid=$2 luks_uuid=${3:-}
  local linux_args
  linux_args=$(root_linux_args "$root_uuid" "$luks_uuid")
  mkdir -p "$esp_mnt/grub"
  esp_backup_existing "$esp_mnt" grub/custom.cfg || return 1
  esp_backup_existing "$esp_mnt" grub/grub.cfg || return 1
  : >"$esp_mnt/omarchy-mac-root"
  cat >"$esp_mnt/grub/custom.cfg" <<EOF
menuentry 'Omarchy Mac (new root $root_uuid)' {
  search --no-floppy --file /omarchy-mac-root --set=root
  linux /EFI/omarchy/vmlinuz $linux_args
  initrd /EFI/omarchy/initramfs.img
}
EOF
  if [[ -f $esp_mnt/grub/grub.cfg ]] && ! grep -q custom.cfg "$esp_mnt/grub/grub.cfg"; then
    printf '\nif [ -f /grub/custom.cfg ]; then source /grub/custom.cfg; fi\n' \
      >>"$esp_mnt/grub/grub.cfg"
  fi
}

# Take over a UEFI-only System ESP: write BOOTAA64.EFI next to m1n1.
# $3 is grub-embed-system.cfg. $4 is the LUKS UUID when encrypted.
# Does not touch m1n1/vendorfw/asahi.
write_owned_esp_grub() {
  local esp_mnt=$1 root_uuid=$2 embed_cfg=$3 luks_uuid=${4:-}
  local linux_args
  linux_args=$(root_linux_args "$root_uuid" "$luks_uuid")
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
  linux /EFI/omarchy/vmlinuz $linux_args
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

# One field from an lsblk --pairs line. PARTLABEL contains the letters
# LABEL, so a greedy .*LABEL= regex reads the wrong column.
lsblk_pair_field() {
  local line=$1 want=$2 rest key val
  rest=$line
  while [[ $rest =~ ^([A-Z]+)=\"([^\"]*)\"[[:space:]]*(.*)$ ]]; do
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    rest=${BASH_REMATCH[3]}
    if [[ $key == "$want" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  return 1
}

# Print /dev/NAME of the Omarchy root on $1 (disk NAME). Matches a btrfs
# labelled OMARCHYROOT, or a LUKS container labelled OMARCHYROOT / GPT
# name "root" (mkpart). Asahi's own LUKS has neither — do not return it.
# lsblk -l and -P cannot be combined (util-linux errors and prints nothing).
existing_omarchy_root_on() {
  local disk=$1 line name fstype label partlabel
  while IFS= read -r line; do
    name=$(lsblk_pair_field "$line" NAME) || continue
    fstype=$(lsblk_pair_field "$line" FSTYPE) || fstype=
    label=$(lsblk_pair_field "$line" LABEL) || label=
    partlabel=$(lsblk_pair_field "$line" PARTLABEL) || partlabel=
    [[ $name == "$disk" ]] && continue
    if [[ $fstype == btrfs && $label == OMARCHYROOT ]]; then
      printf '/dev/%s\n' "$name"
      return 0
    fi
    if [[ $fstype == crypto_LUKS && ( $label == OMARCHYROOT || $partlabel == root ) ]]; then
      printf '/dev/%s\n' "$name"
      return 0
    fi
  done < <(lsblk -n -P -o NAME,FSTYPE,LABEL,PARTLABEL "/dev/$disk" 2>/dev/null)
  return 1
}
