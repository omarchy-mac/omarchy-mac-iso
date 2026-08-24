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

disk_has_apple_partitions() {
  local disk=$1 type
  while read -r type; do
    [[ -z $type ]] && continue
    type=${type,,}
    [[ $type == "$APPLE_APFS" || $type == "$APPLE_IBOOT" || $type == "$APPLE_RECOVERY" ]] && return 0
  done < <(lsblk -n -o PARTTYPE "/dev/$disk" 2>/dev/null)
  return 1
}

# Snapshot "name type" lines for Apple partitions on $1 (path or NAME).
apple_partition_snapshot() {
  local dev=$1 name type
  while read -r name type; do
    [[ -z $type ]] && continue
    type=${type,,}
    if [[ $type == "$APPLE_APFS" || $type == "$APPLE_IBOOT" || $type == "$APPLE_RECOVERY" ]]; then
      printf '%s %s\n' "$name" "$type"
    fi
  done < <(lsblk -n -o NAME,PARTTYPE "$dev" 2>/dev/null)
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

# Existing System ESP: GPT ESP type, or FAT labelled EFI*.
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
  done < <(lsblk -n -o NAME,PARTTYPE,LABEL "/dev/$disk" 2>/dev/null)
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
