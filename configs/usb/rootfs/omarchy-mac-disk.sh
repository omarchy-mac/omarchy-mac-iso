#!/bin/bash
# Partition helpers for omarchy-mac-install. Safe to source from tests.
# Never mklabel/wipefs a disk that already has Apple GPT types.

APPLE_APFS=7c3457ef-0000-11aa-aa11-00306543ecac
APPLE_IBOOT=69646961-6700-11aa-aa11-00306543ecac
APPLE_RECOVERY=52637672-7900-11aa-aa11-00306543ecac
ESP_PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
GPT_BACKUP_SECTORS=34
# Skip GPT alignment slivers
MIN_FREE_MIB=64
# Temporary NVMe live slice. Delete this GPT name only — never APFS/iBoot/Recovery.
INSTALLER_PARTLABEL=omarchy-install

disk_has_apple_partitions() {
  local disk=$1 type
  while read -r type; do
    [[ -z $type ]] && continue
    type=${type,,}
    [[ $type == "$APPLE_APFS" || $type == "$APPLE_IBOOT" || $type == "$APPLE_RECOVERY" ]] && return 0
  done < <(lsblk -ln -o PARTTYPE "/dev/$disk" 2>/dev/null)
  return 1
}

# Snapshot "name type" lines for Apple partitions on $1 (path or NAME).
# Use -l so tree glyphs (├/└) do not change when a new partition is added.
apple_partition_snapshot() {
  local dev=$1 name type
  while read -r name type; do
    [[ -z $type ]] && continue
    type=${type,,}
    if [[ $type == "$APPLE_APFS" || $type == "$APPLE_IBOOT" || $type == "$APPLE_RECOVERY" ]]; then
      printf '%s %s\n' "$name" "$type"
    fi
  done < <(lsblk -ln -o NAME,PARTTYPE "$dev" 2>/dev/null)
}

# Print "start_mib size_mib" for each Free Space region on a parted device
# (block device or image file). start/size are in MiB.
list_free_regions() {
  local dev=$1 start end size rest found=0
  while read -r start end size rest; do
    [[ $rest == *"Free Space"* ]] || continue
    start=${start%s}
    size=${size%s}
    start=${start%MiB}
    size=${size%MiB}
    start=${start%%.*}
    size=${size%%.*}
    [[ $start =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] || continue
    (( size >= MIN_FREE_MIB )) || continue
    printf '%s %s\n' "$start" "$size"
    found=1
  done < <(parted -s "$dev" unit MiB print free 2>/dev/null)
  (( found == 1 ))
}

largest_free_region() {
  local dev=$1 start size best_start=0 best_size=0
  while read -r start size; do
    (( size > best_size )) && { best_size=$size; best_start=$start; }
  done < <(list_free_regions "$dev")
  (( best_size > 0 )) || return 1
  printf '%s %s\n' "$best_start" "$best_size"
}

disk_is_nvme() {
  local name=$1
  [[ $name == nvme* ]]
}

device_mib() {
  local dev=$1 bytes
  if [[ -b $dev ]]; then
    bytes=$(( $(cat /sys/block/"${dev#/dev/}"/size) * 512 ))
  else
    bytes=$(stat -c %s "$dev")
  fi
  printf '%s\n' $(( bytes / 1024 / 1024 ))
}

# Move backup GPT to the real end of a USB image that was dd'd onto a
# larger stick. Never run this on NVMe / Apple partitions.
grow_gpt_to_device() {
  local dev=$1 name=${1#/dev/}
  if [[ -b $dev ]]; then
    disk_is_nvme "$name" && return 0
    disk_has_apple_partitions "$name" && return 0
  fi
  if command -v sgdisk >/dev/null; then
    sgdisk -e "$dev" >/dev/null
  else
    printf 'Fix\n' | parted ---pretend-input-tty "$dev" print >/dev/null || true
  fi
}

# Parted reports free-space start in whole MiB, which can land inside
# the previous partition's last fractional MiB (Apple NVMe 4K). Step 1MiB
# in from both ends.
inset_free_region() {
  local start=$1 size=$2
  start=$(( start + 1 ))
  size=$(( size - 2 ))
  (( size >= MIN_FREE_MIB )) || return 1
  printf '%s %s\n' "$start" "$size"
}

# start size -> start size end, clamped so parted does not treat the
# exact device size as "outside of the device".
clamp_free_region() {
  local start=$1 size=$2 disk_mib=$3 end max_end
  end=$(( start + size ))
  max_end=$(( disk_mib - 2 ))
  (( max_end > start )) || return 1
  (( end > max_end )) && end=$max_end
  size=$(( end - start ))
  (( size >= MIN_FREE_MIB )) || return 1
  printf '%s %s %s\n' "$start" "$size" "$end"
}

# Existing System ESP: GPT ESP type, or FAT labelled EFI*.
# lsblk -l so tree glyphs are not part of NAME.
existing_esp_on() {
  local disk=$1 name type label
  while read -r name type label; do
    [[ $name == "$disk" ]] && continue
    type=${type,,}
    if [[ $type == "$ESP_PARTTYPE" ]]; then
      printf '/dev/%s\n' "$name"
      return 0
    fi
    if [[ ${label,,} == efi* || $label == OMARCHYISO || $label == OMARCHYBOOT ]]; then
      printf '/dev/%s\n' "$name"
      return 0
    fi
  done < <(lsblk -ln -o NAME,PARTTYPE,LABEL "/dev/$disk" 2>/dev/null)
  return 1
}

partition_names_on() {
  local disk=$1 name
  while read -r name; do
    [[ $name == "$disk" ]] && continue
    printf '%s\n' "$name"
  done < <(lsblk -ln -o NAME "/dev/$disk" 2>/dev/null)
}

# After mkpart, the new node is the NAME that was not in $before_list.
new_partition_node() {
  local disk=$1 before=$2 name
  while read -r name; do
    [[ $name == "$disk" ]] && continue
    printf '%s\n' "$before" | grep -qx "$name" && continue
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -ln -o NAME "/dev/$disk")
  return 1
}

# Whole MiB from a parted unit (1.00MiB -> 1).
mib_int() {
  local v=$1
  v=${v%;}
  v=${v%MiB}
  v=${v%%.*}
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

# Machine-readable GPT rows: number start_mib end_mib name
gpt_part_rows() {
  local dev=$1 num start end size fs name flags
  while IFS=: read -r num start end size fs name flags; do
    [[ $num =~ ^[0-9]+$ ]] || continue
    name=${name%;}
    start=$(mib_int "$start") || continue
    end=$(mib_int "$end") || continue
    printf '%s %s %s %s\n' "$num" "$start" "$end" "$name"
  done < <(parted -s -m "$dev" unit MiB print 2>/dev/null)
}

find_part_number_by_name() {
  local dev=$1 want=$2 num start end name
  while read -r num start end name; do
    [[ $name == "$want" ]] || continue
    printf '%s\n' "$num"
    return 0
  done < <(gpt_part_rows "$dev")
  return 1
}

part_start_end_mib() {
  local dev=$1 want=$2 num start end name
  while read -r num start end name; do
    [[ $num == "$want" ]] || continue
    printf '%s %s\n' "$start" "$end"
    return 0
  done < <(gpt_part_rows "$dev")
  return 1
}

# Place the installer at the tail of a hole so the remaining space is a
# leading unallocated region the Linux TUI can mkpart, then grow into
# after the installer is deleted. Prints:
#   root_start_mib root_size_mib installer_start_mib installer_size_mib
split_hole_for_tail_installer() {
  local hole_start=$1 hole_size=$2 installer_mib=$3
  local installer_start root_size
  [[ $hole_start =~ ^[0-9]+$ && $hole_size =~ ^[0-9]+$ && $installer_mib =~ ^[0-9]+$ ]] || return 1
  (( installer_mib >= MIN_FREE_MIB )) || return 1
  (( hole_size >= installer_mib + MIN_FREE_MIB )) || return 1
  installer_start=$(( hole_start + hole_size - installer_mib ))
  root_size=$(( hole_size - installer_mib ))
  (( installer_start > hole_start )) || return 1
  printf '%s %s %s %s\n' "$hole_start" "$root_size" "$installer_start" "$installer_mib"
}

# Delete GPT name omarchy-install only. Refuses any other name so a
# script cannot rm Recovery/APFS by accident.
delete_installer_partition() {
  local dev=$1 name=${2:-$INSTALLER_PARTLABEL} num
  [[ $name == "$INSTALLER_PARTLABEL" ]] || return 1
  num=$(find_part_number_by_name "$dev" "$name") || return 1
  parted -s "$dev" rm "$num"
}

# Grow partition $2 into the free region that starts at its current end.
# Never uses 100% — Recovery often follows the hole.
grow_partition_into_next_hole() {
  local dev=$1 num=$2
  local start end hole_start hole_size hole_end disk_mib
  read -r start end <<<"$(part_start_end_mib "$dev" "$num")" || return 1
  disk_mib=$(device_mib "$dev")
  while read -r hole_start hole_size; do
    (( hole_start >= end - 2 && hole_start <= end + 2 )) || continue
    read -r hole_start hole_size hole_end <<<"$(clamp_free_region "$hole_start" "$hole_size" "$disk_mib")" \
      || return 1
    (( hole_end > end )) || return 1
    parted -s "$dev" resizepart "$num" "${hole_end}MiB"
    return 0
  done < <(list_free_regions "$dev")
  return 1
}

installer_partition_on() {
  local disk=$1 name label
  while read -r name label; do
    [[ $name == "$disk" ]] && continue
    [[ $label == "$INSTALLER_PARTLABEL" ]] || continue
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -ln -o NAME,PARTLABEL "/dev/$disk" 2>/dev/null)
  return 1
}

# macOS diskutil addPartition cannot set a GPT name (gpt label is EPERM
# on the internal SSD). The live payload is still labelled OMARCHYLIVE.
omarchy_live_payload_on() {
  local disk=$1 skip=${2:-} name label
  while read -r name label; do
    [[ $name == "$disk" ]] && continue
    [[ $label == OMARCHYLIVE ]] || continue
    [[ -n $skip && /dev/$name == "$skip" ]] && continue
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -ln -o NAME,LABEL "/dev/$disk" 2>/dev/null)
  return 1
}

partition_number_of() {
  local part=$1 n
  n=$(lsblk -dn -o PARTN "$part" 2>/dev/null || true)
  [[ $n =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

# Set GPT name omarchy-install on the NVMe live payload. No-op on USB
# (PARTLABEL stays payload) and if the name is already set.
ensure_installer_partlabel() {
  local part=$1 disk num label ptype
  [[ -b $part ]] || return 1
  disk=$(lsblk -no PKNAME "$part")
  [[ -n $disk ]] || return 1
  disk_is_nvme "$disk" || return 0
  label=$(lsblk -dn -o PARTLABEL "$part" 2>/dev/null || true)
  [[ $label == "$INSTALLER_PARTLABEL" ]] && return 0
  ptype=$(lsblk -dn -o PARTTYPE "$part" 2>/dev/null || true)
  ptype=${ptype,,}
  [[ $ptype != "$APPLE_APFS" && $ptype != "$APPLE_IBOOT" && $ptype != "$APPLE_RECOVERY" ]] \
    || return 1
  num=$(partition_number_of "$part") || return 1
  parted -s "/dev/$disk" name "$num" "$INSTALLER_PARTLABEL" || return 1
  command -v udevadm >/dev/null && udevadm settle --timeout=5 || true
  printf '==> GPT name %s on %s (macOS could not set it)\n' "$INSTALLER_PARTLABEL" "$part"
}
