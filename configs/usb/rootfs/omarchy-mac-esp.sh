#!/bin/bash
# System ESP GRUB helpers. Safe to source from tests.
# Never write m1n1/, vendorfw/, or asahi/. Never mkfs.vfat the ESP.

esp_has_bootloader() {
  local esp_mnt=$1
  [[ -f $esp_mnt/EFI/BOOT/BOOTAA64.EFI ]]
}

# Earlier ISO standalone loaders omitted test.mod even though the generated
# include chain uses '['. Reinstalling restores that old loader, not the live
# image's new one. Recognize only our known standalone layout; do not parse or
# rewrite a foreign owner's configuration, or replace its EFI executable.
esp_require_supported_grub() {
  local esp_mnt=$1 loader=$1/EFI/BOOT/BOOTAA64.EFI
  if [[ -f $esp_mnt/omarchy-nvme-live && -f $esp_mnt/grub/omarchy-nvme-had-bootloader ]]; then
    loader=$esp_mnt/EFI/BOOT/BOOTAA64.EFI.omarchy-nvme-bak
    [[ -f $loader ]] || {
      printf 'error: saved pre-installer EFI bootloader is missing\n' >&2
      return 1
    }
  fi
  [[ -f $loader ]] || return 0
  if grep -aqF 'boot/grub/arm64-efi/normal.mod' "$loader" &&
    grep -aqF 'search --no-floppy --file /omarchy-mac-root --set=root' "$loader" &&
    ! grep -aqF 'boot/grub/arm64-efi/test.mod' "$loader"; then
    printf 'error: the existing ISO GRUB loader lacks test.mod and cannot load its conditional menu includes\n' >&2
    printf 'Restore a compatible owning GRUB loader before reinstalling; the installer will not replace its bootloader or rewrite its menu.\n' >&2
    return 1
  fi
}

esp_protected_hashes() {
  local esp_mnt=$1
  # boot.bin is the one m1n1 file the j613 DCP slot patch may change.
  # vendorfw/, asahi/, and the rest of m1n1/ must stay byte-identical.
  (cd "$esp_mnt" && find asahi m1n1 vendorfw EFI/asahi -type f \
    ! -name boot.bin ! -name 'boot.bin.bak*' 2>/dev/null | sort | xargs -r sha256sum) || true
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
  # vfat cannot preserve Unix ownership/modes; cp -a can fail after copying.
  cp "$src" "$dest" || return 1
  printf '==> ESP backup %s -> %s\n' "$rel" "${dest#"$esp_mnt"/}" >&2
}

# The NVMe placer temporarily replaces only BOOTAA64.EFI. Restore the owning
# OS's saved executable before piggybacking; its grub.cfg/custom.cfg were never
# replaced. Return 1 when there was no prior owner and 2 for a broken backup.
esp_restore_nvme_preinstall_bootloader() {
  local esp_mnt=$1
  local marker=$esp_mnt/grub/omarchy-nvme-had-bootloader
  local backup=$esp_mnt/EFI/BOOT/BOOTAA64.EFI.omarchy-nvme-bak
  local tmp=$esp_mnt/EFI/BOOT/.BOOTAA64.EFI.omarchy-restore
  [[ -f $marker ]] || return 1
  [[ -f $backup ]] || return 2
  cp "$backup" "$tmp" || return 2
  mv "$tmp" "$esp_mnt/EFI/BOOT/BOOTAA64.EFI" || return 2
}

esp_cleanup_nvme_live() {
  local esp_mnt=$1 source_mode=$2
  [[ $source_mode == nvme ]] || return 0
  rm -f "$esp_mnt/vmlinuz-omarchy-nvme-live" \
    "$esp_mnt/initramfs-omarchy-nvme-live.img" \
    "$esp_mnt/initramfs-omarchy-nvme-install.img" \
    "$esp_mnt/initramfs-omarchy-nvme-install-plain.img" \
    "$esp_mnt/grub/grub-nvme.cfg" \
    "$esp_mnt/omarchy-nvme-live" \
    "$esp_mnt/grub/omarchy-nvme-had-bootloader"
}

# After restoring a pre-NVMe BOOTAA64, piggyback only if that owner still
# has a GRUB config we can source. UEFI-only often has BOOTAA64 (U-Boot)
# and no grub.cfg; writing custom.cfg there never boots the new root.
# A leftover NVMe-live menu in grub.cfg is the same: own instead.
esp_nvme_restore_can_piggyback() {
  local esp=$1
  [[ -f $esp/grub/grub.cfg ]] || return 1
  ! grep -qE 'OMARCHY NVMe installer GRUB|Omarchy Mac live \(NVMe installer\)' \
    "$esp/grub/grub.cfg"
}

write_shared_esp_notice() {
  local root_mnt=$1 esp_uuid=$2 mode=$3
  case $mode in
    own) return 0 ;;
    piggyback) ;;
    *) printf 'error: invalid ESP ownership mode: %s\n' "$mode" >&2; return 1 ;;
  esac
  cat >"$root_mnt/etc/omarchy-mac-iso-shared-esp" <<EOF
This root shares EFI system partition UUID=$esp_uuid with another installation.
Do not run omarchy-system-boot-to-esp here: it would replace the shared GRUB owner.
Kernel/initramfs updates must sync EFI/omarchy/<root-uuid>/ explicitly.
EOF
  assert_shared_esp_notice "$root_mnt" "$esp_uuid" "$mode"
}

assert_shared_esp_notice() {
  local root_mnt=$1 esp_uuid=$2 mode=$3
  case $mode in
    own) return 0 ;;
    piggyback)
      grep -qF "UUID=$esp_uuid" "$root_mnt/etc/omarchy-mac-iso-shared-esp" && return 0
      ;;
  esac
  printf 'error: shared ESP ownership notice missing or invalid\n' >&2
  return 1
}

# Leave room for FAT metadata and an interrupted retry in addition to the exact
# source sizes. A full ESP mid-write can make every installed root unbootable.
ESP_WRITE_SLACK_BYTES=$((16 * 1024 * 1024))

esp_require_free_bytes() {
  local esp_mnt=$1 need=$2
  local avail_kb
  avail_kb=$(df -Pk "$esp_mnt" | awk 'NR==2 { print $4 }')
  [[ $avail_kb =~ ^[0-9]+$ ]] || return 1
  (( avail_kb * 1024 >= need )) || {
    printf 'error: ESP %s has %sKiB free, need %s bytes\n' \
      "$esp_mnt" "$avail_kb" "$need" >&2
    return 1
  }
}

# Classify where install boot files may come from. A source mounted from a
# separate ESP is a normal USB source. The same mount is valid only while the
# dedicated NVMe-live marker exists; otherwise borrowing /boot files from the
# GRUB-owning installation is unsafe.
esp_boot_source_mode() {
  local live_esp_mnt=$1 esp_mnt=$2
  if [[ $live_esp_mnt != "$esp_mnt" ]]; then
    printf 'external\n'
    return 0
  fi
  [[ -f $esp_mnt/omarchy-nvme-live ]] || return 1
  printf 'nvme\n'
}

# Print the kernel and initrd selected from an installer ESP. $3 is 1 only
# when consuming a same-ESP NVMe placement: that path must use its private
# files and fail rather than silently borrowing an existing OS's /boot files.
esp_boot_sources() {
  local live_esp_mnt=$1 luks_uuid=${2:-} strict_nvme=${3:-0}
  local kernel initrd
  if (( strict_nvme == 1 )); then
    kernel=$live_esp_mnt/vmlinuz-omarchy-nvme-live
    if [[ -n $luks_uuid ]]; then
      initrd=$live_esp_mnt/initramfs-omarchy-nvme-install.img
    else
      initrd=$live_esp_mnt/initramfs-omarchy-nvme-install-plain.img
    fi
  else
    kernel=$live_esp_mnt/vmlinuz-linux-asahi
    initrd=$live_esp_mnt/initramfs-linux-asahi.img
    if [[ -z $luks_uuid && -f $live_esp_mnt/initramfs-linux-asahi-plain.img ]]; then
      initrd=$live_esp_mnt/initramfs-linux-asahi-plain.img
    fi
  fi
  [[ -f $kernel && -f $initrd ]] || return 1
  printf '%s\t%s\n' "$kernel" "$initrd"
}

# NVMe-live files the installer does not copy from. The live session is
# already running from the payload overlay, so the live initrd can go
# before the unique-kernel copy. The unused install initrd (plain vs LUKS)
# can go too. Do not list the kernel or the initrd esp_boot_sources picks.
esp_nvme_unused_before_copy() {
  local luks_uuid=${1:-}
  printf '%s\n' initramfs-omarchy-nvme-live.img
  if [[ -n $luks_uuid ]]; then
    printf '%s\n' initramfs-omarchy-nvme-install-plain.img
  else
    printf '%s\n' initramfs-omarchy-nvme-install.img
  fi
}

esp_nvme_unused_bytes() {
  local esp_mnt=$1 luks_uuid=${2:-} rel total=0
  while IFS= read -r rel; do
    [[ -f $esp_mnt/$rel ]] || continue
    total=$((total + $(stat -c %s "$esp_mnt/$rel")))
  done < <(esp_nvme_unused_before_copy "$luks_uuid")
  printf '%s\n' "$total"
}

esp_nvme_drop_unused_before_copy() {
  local esp_mnt=$1 luks_uuid=${2:-} rel
  while IFS= read -r rel; do
    rm -f "$esp_mnt/$rel"
  done < <(esp_nvme_unused_before_copy "$luks_uuid")
}

esp_require_kernel_copy_space() {
  local live_esp_mnt=$1 esp_mnt=$2 luks_uuid=${3:-} strict_nvme=${4:-0}
  local sources kernel initrd need reclaim=0
  sources=$(esp_boot_sources "$live_esp_mnt" "$luks_uuid" "$strict_nvme") || return 1
  IFS=$'\t' read -r kernel initrd <<<"$sources"
  need=$(( $(stat -c %s "$kernel") + $(stat -c %s "$initrd") + ESP_WRITE_SLACK_BYTES ))
  if (( strict_nvme == 1 )); then
    reclaim=$(esp_nvme_unused_bytes "$esp_mnt" "$luks_uuid")
    if (( need > reclaim )); then
      need=$((need - reclaim))
    else
      need=0
    fi
  fi
  esp_require_free_bytes "$esp_mnt" "$need"
}

# Store one kernel/initrd pair per installed btrfs UUID. Two roots can have
# different kernel module trees or encryption settings, so sharing
# EFI/omarchy/vmlinuz and initramfs.img is not safe.
esp_copy_unique_kernels() {
  local live_esp_mnt=$1 esp_mnt=$2 root_uuid=$3 luks_uuid=${4:-}
  local strict_nvme=${5:-0}
  local sources kernel initrd kernel_tmp initrd_tmp
  local root_dir=$esp_mnt/EFI/omarchy/$root_uuid
  [[ $root_uuid =~ ^[0-9A-Fa-f-]+$ ]] || return 1
  sources=$(esp_boot_sources "$live_esp_mnt" "$luks_uuid" "$strict_nvme") || return 1
  IFS=$'\t' read -r kernel initrd <<<"$sources"
  esp_require_kernel_copy_space "$live_esp_mnt" "$esp_mnt" "$luks_uuid" \
    "$strict_nvme" || return 1
  mkdir -p "$root_dir"
  kernel_tmp=$root_dir/.vmlinuz.omarchy-new
  initrd_tmp=$root_dir/.initramfs.img.omarchy-new
  rm -f "$kernel_tmp" "$initrd_tmp"
  if ! cp "$kernel" "$kernel_tmp" || ! cp "$initrd" "$initrd_tmp"; then
    rm -f "$kernel_tmp" "$initrd_tmp"
    return 1
  fi
  mv "$initrd_tmp" "$root_dir/initramfs.img"
  mv "$kernel_tmp" "$root_dir/vmlinuz"
  rm -f "$esp_mnt/vmlinuz-omarchy-usb-root" \
    "$esp_mnt/initramfs-omarchy-usb-root.img"
}

# linux line for an installed root. $2 is the LUKS UUID when encrypted.
root_linux_args() {
  local root_uuid=$1 luks_uuid=${2:-}
  if [[ -n $luks_uuid ]]; then
    printf 'root=UUID=%s rw rootflags=subvol=@ cryptdevice=UUID=%s:root:allow-discards appledrm.show_notch=1 loglevel=3 quiet splash' \
      "$root_uuid" "$luks_uuid"
  else
    printf 'root=UUID=%s rw rootflags=subvol=@ appledrm.show_notch=1 loglevel=3 quiet splash' "$root_uuid"
  fi
}

# Script install's grub-mkconfig adds Advanced + fallback. The ISO does not
# run grub-mkconfig and has one initrd, so Advanced is a verbose boot
# (no quiet/splash) of that same image.
root_linux_args_verbose() {
  root_linux_args "$@" | sed 's/ loglevel=3 quiet splash/ loglevel=7/'
}

# $1 title. $2 linux_args. $3 kernel directory. $4 is 1 to search
# /omarchy-mac-root inside each entry (piggyback, sourced from another
# grub.cfg). Own-mode searches once above the menu.
grub_root_menu_entries() {
  local title=$1 linux_args=$2 kernel_dir=$3 search_inside=${4:-0}
  local verbose_args body
  verbose_args=$(printf '%s' "$linux_args" | sed 's/ loglevel=3 quiet splash/ loglevel=7/')
  if (( search_inside == 1 )); then
    body=$'  search --no-floppy --file /omarchy-mac-root --set=root\n'
  else
    body=""
  fi
  cat <<EOF
menuentry '$title' {
${body}  linux $kernel_dir/vmlinuz $linux_args
  initrd $kernel_dir/initramfs.img
}
menuentry '$title (verbose)' {
${body}  linux $kernel_dir/vmlinuz $verbose_args
  initrd $kernel_dir/initramfs.img
}
EOF
}

# Regenerate only our managed include. Files whose names are not complete
# btrfs UUIDs are intentionally ignored; a full grub-mkconfig output is not a
# fragment and must never be sourced or concatenated here.
write_managed_omarchy_grub() {
  local esp_mnt=$1 default_line=${2:-} current_uuid=${3:-} cfg base
  local out=$esp_mnt/grub/omarchy.cfg
  local tmp=$esp_mnt/grub/.omarchy.cfg.new
  {
    printf '# Managed Omarchy roots. One entry file per installed btrfs UUID.\n'
    if [[ -n $default_line ]]; then
      printf 'set timeout=8\n'
      printf '%s\n' "$default_line"
    fi
    for cfg in "$esp_mnt"/grub/omarchy-roots/*.cfg; do
      [[ -f $cfg ]] || continue
      base=${cfg##*/}
      [[ $base =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}[.]cfg$ ]] || continue
      if managed_root_is_stale "$esp_mnt" "${base%.cfg}" "$current_uuid"; then
        # Retain the fragment and kernel files for recovery/reconnected disks,
        # but do not offer a root whose devices are no longer present.
        printf '==> omitting absent Omarchy root %s from the active menu\n' "${base%.cfg}" >&2
        continue
      fi
      cat "$cfg"
    done
  } >"$tmp" || return 1
  mv "$tmp" "$out"
}

managed_default_uuid() {
  local esp_mnt=$1 uuid
  [[ -s $esp_mnt/grub/omarchy-default-root ]] || return 1
  IFS= read -r uuid <"$esp_mnt/grub/omarchy-default-root"
  [[ $uuid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || return 1
  printf '%s\n' "$uuid"
}

# Return success only when the currently managed default is the filesystem
# being replaced. Encrypted callers know the outer LUKS UUID; the per-root
# fragment is the safe link back to its inner btrfs UUID.
managed_default_matches_replacement() {
  local esp_mnt=$1 default_uuid=$2 old_root_uuid=${3:-} old_luks_uuid=${4:-}
  local cfg=$esp_mnt/grub/omarchy-roots/$default_uuid.cfg
  [[ -n $old_root_uuid && $default_uuid == "$old_root_uuid" ]] && return 0
  [[ -n $old_luks_uuid && -f $cfg ]] || return 1
  grep -qF "cryptdevice=UUID=$old_luks_uuid:root:allow-discards" "$cfg"
}

# True when a UUID exists as a block device. Tests set ESP_UUID_DIR.
esp_uuid_present() {
  local uuid=$1 dir=${ESP_UUID_DIR:-/dev/disk/by-uuid}
  [[ -n $uuid ]] || return 1
  [[ -e $dir/$uuid ]]
}

# Only classify our exact generated fragment, never the owning grub.cfg or
# custom.cfg. A locked LUKS root is present when its outer UUID is present,
# even though its inner btrfs UUID cannot be seen until it is unlocked.
# Unknown/customized fragments and failed device discovery are preserved.
managed_root_is_stale() {
  local esp_mnt=$1 root_uuid=$2 current_uuid=${3:-}
  local cfg=$esp_mnt/grub/omarchy-roots/$root_uuid.cfg
  local line luks_uuid="" linux_args devices
  [[ $root_uuid != "$current_uuid" && -f $cfg ]] || return 1
  while IFS= read -r line; do
    [[ $line == *cryptdevice=* ]] || continue
    if [[ $line =~ cryptdevice=UUID=([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}):root:allow-discards ]]; then
      luks_uuid=${BASH_REMATCH[1]}
    else
      return 1
    fi
  done <"$cfg"
  linux_args=$(root_linux_args "$root_uuid" "$luks_uuid")
  cmp -s "$cfg" <(grub_root_menu_entries "Omarchy Mac (root $root_uuid)" \
    "$linux_args" "/EFI/omarchy/$root_uuid" 1) || return 1
  if [[ -n ${ESP_UUID_DIR:-} ]]; then
    [[ -d $ESP_UUID_DIR ]] || return 1
    esp_uuid_present "$root_uuid" && return 1
    if [[ -n $luks_uuid ]] && esp_uuid_present "$luks_uuid"; then
      return 1
    fi
  else
    devices=$(lsblk --list --noheadings --output UUID) || return 1
    [[ -n $devices ]] || return 1
    grep -Fxq "$root_uuid" <<<"$devices" && return 1
    if [[ -n $luks_uuid ]] && grep -Fxq "$luks_uuid" <<<"$devices"; then
      return 1
    fi
  fi
  return 0
}

# A leftover ISO shared-kernel line (/EFI/omarchy/vmlinuz) is stale when
# none of its root= / cryptdevice= UUIDs are on disk. A living second
# Omarchy root still has those UUIDs — do not rewrite it.
esp_legacy_shared_kernel_stale() {
  local cfg=$1 line uuid seen=0 live=0
  [[ -f $cfg ]] || return 1
  while IFS= read -r line; do
    [[ $line == *'/EFI/omarchy/vmlinuz'* ]] || continue
    seen=1
    uuid=""
    if [[ $line =~ cryptdevice=UUID=([0-9A-Fa-f-]+) ]]; then
      uuid=${BASH_REMATCH[1]}
    elif [[ $line =~ root=UUID=([0-9A-Fa-f-]+) ]]; then
      uuid=${BASH_REMATCH[1]}
    fi
    if [[ -z $uuid ]]; then
      live=1
      continue
    fi
    if esp_uuid_present "$uuid"; then
      live=1
    fi
  done <"$cfg"
  (( seen == 1 && live == 0 ))
}

# Preserve an existing custom.cfg verbatim and add one stable include. Arch's
# grub-mkconfig keeps custom.cfg and sources it, so UUID entries survive future
# kernel updates by the GRUB-owning installation.
ensure_custom_sources_omarchy() {
  local esp_mnt=$1 custom=$esp_mnt/grub/custom.cfg
  local tmp=$esp_mnt/grub/.custom.cfg.new
  if [[ -f $custom ]] && grep -Eq \
    '^[[:space:]]*((if .*;[[:space:]]*then[[:space:]]*)?(source|configfile))[[:space:]]+/grub/omarchy[.]cfg([[:space:];]|$)' \
    "$custom"; then
    return 0
  fi
  esp_backup_existing "$esp_mnt" grub/custom.cfg || return 1
  if [[ -f $custom ]]; then
    cp "$custom" "$tmp" || return 1
  else
    : >"$tmp"
  fi
  cat >>"$tmp" <<'EOF'

if [ -f /grub/omarchy.cfg ]; then
  source /grub/omarchy.cfg
fi
EOF
  mv "$tmp" "$custom"
}

# Piggyback on an OS that already owns BOOTAA64.EFI. Its grub.cfg, menu,
# grubenv behavior, and custom.cfg contents remain owned by that OS.
# A second living Omarchy root keeps that default. A leftover shared
# /EFI/omarchy/vmlinuz line is rewritten only when its UUIDs are gone.
write_piggyback_esp_grub() {
  local esp_mnt=$1 root_uuid=$2 luks_uuid=${3:-}
  local old_root_uuid=${4:-} old_luks_uuid=${5:-}
  local linux_args verbose_args entry_title kernel_dir root_cfg default_line=""
  local default_uuid modify_grub=0 rewrite_legacy=0 cfg
  linux_args=$(root_linux_args "$root_uuid" "$luks_uuid")
  verbose_args=$(root_linux_args_verbose "$root_uuid" "$luks_uuid")
  entry_title="Omarchy Mac (root $root_uuid)"
  kernel_dir=/EFI/omarchy/$root_uuid
  mkdir -p "$esp_mnt/grub/omarchy-roots"
  : >"$esp_mnt/omarchy-mac-root"
  root_cfg=$esp_mnt/grub/omarchy-roots/$root_uuid.cfg
  grub_root_menu_entries "$entry_title" "$linux_args" "$kernel_dir" 1 \
    >"$root_cfg"
  if default_uuid=$(managed_default_uuid "$esp_mnt"); then
    if managed_default_matches_replacement "$esp_mnt" "$default_uuid" \
      "$old_root_uuid" "$old_luks_uuid" || \
      managed_root_is_stale "$esp_mnt" "$default_uuid" "$root_uuid"; then
      default_uuid=$root_uuid
      printf '%s\n' "$default_uuid" >"$esp_mnt/grub/omarchy-default-root"
    fi
    default_line="set default='Omarchy Mac (root $default_uuid)'"
  fi
  write_managed_omarchy_grub "$esp_mnt" "$default_line" "$root_uuid" || return 1
  ensure_custom_sources_omarchy "$esp_mnt" || return 1
  if [[ -n $old_root_uuid || -n $old_luks_uuid ]]; then
    rewrite_legacy=1
  fi
  for cfg in "$esp_mnt/grub/grub.cfg" "$esp_mnt/grub/custom.cfg"; do
    if esp_legacy_shared_kernel_stale "$cfg"; then
      rewrite_legacy=1
    fi
  done
  if [[ -f $esp_mnt/grub/grub.cfg ]] && ! grep -Eq \
    '^[[:space:]]*((if .*;[[:space:]]*then[[:space:]]*)?(source|configfile)).*custom[.]cfg' \
    "$esp_mnt/grub/grub.cfg"; then
    modify_grub=1
  fi
  if (( rewrite_legacy == 1 )) &&
    [[ -f $esp_mnt/grub/grub.cfg ]] && grep -q '/EFI/omarchy/vmlinuz' "$esp_mnt/grub/grub.cfg"; then
    modify_grub=1
  fi
  (( modify_grub == 0 )) || esp_backup_existing "$esp_mnt" grub/grub.cfg \
    || return 1
  if [[ -f $esp_mnt/grub/grub.cfg ]] && ! grep -Eq \
    '^[[:space:]]*((if .*;[[:space:]]*then[[:space:]]*)?(source|configfile)).*custom[.]cfg' \
    "$esp_mnt/grub/grub.cfg"; then
    cat >>"$esp_mnt/grub/grub.cfg" <<'EOF'

if [ -f /grub/custom.cfg ]; then
  source /grub/custom.cfg
fi
EOF
  fi
  # Replace-existing, or a shared-kernel line whose UUIDs are no longer on
  # disk. A living second root keeps /EFI/omarchy/vmlinuz as its entry.
  if (( rewrite_legacy == 1 )); then
    for cfg in "$esp_mnt/grub/grub.cfg" "$esp_mnt/grub/custom.cfg"; do
      [[ -f $cfg ]] || continue
      grep -q '/EFI/omarchy/vmlinuz' "$cfg" || continue
      sed -i -E \
        -e "s|^([[:space:]]*)linux /EFI/omarchy/vmlinuz .*loglevel=3 quiet splash$|\\1linux $kernel_dir/vmlinuz $linux_args|" \
        -e "s|^([[:space:]]*)linux /EFI/omarchy/vmlinuz .*loglevel=7$|\\1linux $kernel_dir/vmlinuz $verbose_args|" \
        -e "s|^([[:space:]]*)initrd /EFI/omarchy/initramfs.img$|\\1initrd $kernel_dir/initramfs.img|" \
        "$cfg"
    done
  fi
}

# Take over a UEFI-only System ESP. Build every replacement into a temporary
# file first; grub-mkstandalone failure leaves the currently bootable files
# untouched. Does not touch m1n1/vendorfw/asahi.
write_owned_esp_grub() {
  local esp_mnt=$1 root_uuid=$2 embed_cfg=$3 luks_uuid=${4:-}
  local old_root_uuid=${5:-} old_luks_uuid=${6:-}
  local linux_args kernel_dir entry_title root_cfg default_uuid default_line
  local cfg_tmp efi_cfg_tmp efi_tmp
  linux_args=$(root_linux_args "$root_uuid" "$luks_uuid")
  kernel_dir=/EFI/omarchy/$root_uuid
  entry_title="Omarchy Mac (root $root_uuid)"
  [[ -f $embed_cfg ]] || return 1
  command -v grub-mkstandalone >/dev/null || return 1
  mkdir -p "$esp_mnt/EFI/BOOT" "$esp_mnt/grub/omarchy-roots"
  cfg_tmp=$esp_mnt/grub/.grub.cfg.omarchy-new
  efi_cfg_tmp=$esp_mnt/EFI/BOOT/.grub.cfg.omarchy-new
  efi_tmp=$esp_mnt/EFI/BOOT/.BOOTAA64.EFI.omarchy-new
  rm -f "$cfg_tmp" "$efi_cfg_tmp" "$efi_tmp"
  grub-mkstandalone -O arm64-efi \
    --fonts="" --locales="" --themes="" \
    --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile test gzio reboot sleep" \
    --modules="part_gpt fat search search_fs_file configfile linux echo normal test" \
    -o "$efi_tmp" \
    "boot/grub/grub.cfg=$embed_cfg" >/dev/null || {
      rm -f "$efi_tmp"
      return 1
    }
  esp_backup_existing "$esp_mnt" EFI/BOOT/BOOTAA64.EFI || return 1
  esp_backup_existing "$esp_mnt" EFI/BOOT/grub.cfg || return 1
  esp_backup_existing "$esp_mnt" grub/grub.cfg || return 1
  : >"$esp_mnt/omarchy-mac-root"
  root_cfg=$esp_mnt/grub/omarchy-roots/$root_uuid.cfg
  grub_root_menu_entries "$entry_title" "$linux_args" "$kernel_dir" 1 \
    >"$root_cfg"
  if default_uuid=$(managed_default_uuid "$esp_mnt"); then
    if managed_default_matches_replacement "$esp_mnt" "$default_uuid" \
      "$old_root_uuid" "$old_luks_uuid" || \
      managed_root_is_stale "$esp_mnt" "$default_uuid" "$root_uuid"; then
      default_uuid=$root_uuid
      printf '%s\n' "$default_uuid" >"$esp_mnt/grub/omarchy-default-root"
    fi
  else
    default_uuid=$root_uuid
    printf '%s\n' "$default_uuid" >"$esp_mnt/grub/omarchy-default-root"
  fi
  default_line="set default='Omarchy Mac (root $default_uuid)'"
  write_managed_omarchy_grub "$esp_mnt" "$default_line" "$root_uuid" || return 1
  ensure_custom_sources_omarchy "$esp_mnt" || return 1
  cat >"$cfg_tmp" <<'EOF'
echo '========================================'
echo '  OMARCHY MAC (System ESP, not USB)'
echo '========================================'
search --no-floppy --file /omarchy-mac-root --set=root
source /grub/custom.cfg
EOF
  cp "$cfg_tmp" "$efi_cfg_tmp" || return 1
  mv "$cfg_tmp" "$esp_mnt/grub/grub.cfg" || return 1
  mv "$efi_cfg_tmp" "$esp_mnt/EFI/BOOT/grub.cfg" || return 1
  mv "$efi_tmp" "$esp_mnt/EFI/BOOT/BOOTAA64.EFI"
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

# Print every /dev/NAME Omarchy root on $1 (disk NAME). Matches a btrfs
# labelled OMARCHYROOT, or a LUKS container labelled OMARCHYROOT / GPT
# name "root" (mkpart). Asahi's own LUKS has neither — do not return it.
# lsblk -l and -P cannot be combined (util-linux errors and prints nothing).
existing_omarchy_roots_on() {
  local disk=$1 line name fstype label partlabel found=0
  while IFS= read -r line; do
    name=$(lsblk_pair_field "$line" NAME) || continue
    fstype=$(lsblk_pair_field "$line" FSTYPE) || fstype=
    label=$(lsblk_pair_field "$line" LABEL) || label=
    partlabel=$(lsblk_pair_field "$line" PARTLABEL) || partlabel=
    [[ $name == "$disk" ]] && continue
    if [[ $fstype == btrfs && $label == OMARCHYROOT ]]; then
      printf '/dev/%s\n' "$name"
      found=1
      continue
    fi
    if [[ $fstype == crypto_LUKS && ( $label == OMARCHYROOT || $partlabel == root ) ]]; then
      printf '/dev/%s\n' "$name"
      found=1
    fi
  done < <(lsblk -n -P -o NAME,FSTYPE,LABEL,PARTLABEL "/dev/$disk" 2>/dev/null)
  (( found != 0 ))
}
