#!/bin/bash
# Place a temporary Omarchy installer slice at the *tail* of the largest
# GPT hole on an Apple Silicon Mac, then copy live GRUB onto the System ESP.
#
# Run from macOS after Asahi UEFI-only (alx.sh/dev, firmware 14.8.3 on M3).
# Does not shrink APFS, does not touch m1n1/vendorfw/asahi, does not luksFormat.
#
# Usage:
#   ./scripts/macos/place-nvme-installer.sh --payload payload.img --esp-files DIR
#   ./scripts/macos/place-nvme-installer.sh --payload payload.img.zst --esp-files DIR --confirm
#
# DIR needs: vmlinuz-linux-asahi, initramfs-omarchy-usb.img,
# initramfs-linux-asahi.img, BOOTAA64.EFI (USB live GRUB).
set -euo pipefail

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

payload=""
esp_files=""
disk=disk0
confirm=0
root_reserve_mib=0

usage() {
  cat <<'EOF'
Place omarchy-install at the tail of the largest GPT hole, then copy live GRUB.

  --payload PATH       payload.img or payload.img.zst (OMARCHYLIVE btrfs)
  --esp-files DIR      vmlinuz, live+install initrds, BOOTAA64.EFI
  --disk disk0         GPT disk (default disk0)
  --root-reserve MiB   unallocated hole to leave in front (default: payload size)
  --confirm            actually gpt add / dd / copy (otherwise print the plan)

Never pass rdisk0 / disk0 as the dd target — only the new slice.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --payload) payload=$2; shift 2 ;;
    --esp-files) esp_files=$2; shift 2 ;;
    --disk) disk=$2; shift 2 ;;
    --root-reserve) root_reserve_mib=$2; shift 2 ;;
    --confirm) confirm=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n $payload && -f $payload ]] || fail "need --payload (payload.img or .zst)"
[[ -n $esp_files && -d $esp_files ]] || fail "need --esp-files DIR"
[[ $disk != *rdisk* ]] || fail "use diskN not rdiskN for --disk (gpt), rdisk is only for dd of the new slice"
[[ $(uname -s) == Darwin ]] || fail "this script is for macOS (gpt / diskutil / mount_msdos)"

for f in vmlinuz-linux-asahi initramfs-omarchy-usb.img initramfs-linux-asahi.img BOOTAA64.EFI; do
  [[ -f $esp_files/$f ]] || fail "missing $esp_files/$f"
done

command -v gpt >/dev/null || fail "gpt not found"
command -v diskutil >/dev/null || fail "diskutil not found"

work=""
cleanup() {
  if [[ -n $work ]]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

payload_file=$payload
if [[ $payload == *.zst ]]; then
  command -v zstd >/dev/null || fail "zstd not found (brew install zstd) to decompress $payload"
  work=$(mktemp -d /tmp/omarchy-place.XXXXXX)
  printf '==> decompressing %s\n' "$payload"
  zstd -d -q -o "$work/payload.img" "$payload"
  payload_file=$work/payload.img
fi

payload_bytes=$(stat -f %z "$payload_file")
[[ $payload_bytes -gt 0 ]] || fail "empty payload"
# gpt -r show / gpt add -b -s use the disk's native block size (4096 on
# Apple Silicon internal SSDs, not 512). 2048 512-byte sectors per MiB
# would make the hole look ~8x too small and mis-place the slice.
block_size=$(diskutil info "$disk" | awk -F': *' '/Device Block Size/{print $2; exit}' | awk '{print $1}')
[[ $block_size -eq 512 || $block_size -eq 4096 ]] || fail "unexpected Device Block Size: $block_size"
sec_per_mib=$(( 1048576 / block_size ))
printf '==> %s native block size %s (gpt units); %s sectors/MiB\n' "$disk" "$block_size" "$sec_per_mib"
installer_sectors=$(( (payload_bytes + 1048575) / 1048576 * sec_per_mib ))
installer_mib=$(( installer_sectors / sec_per_mib ))
if [[ $root_reserve_mib -eq 0 ]]; then
  root_reserve_mib=$installer_mib
fi
[[ $root_reserve_mib -ge 64 ]] || fail "--root-reserve must be >= 64 MiB"
need_mib=$(( installer_mib + root_reserve_mib ))
need_sectors=$(( need_mib * sec_per_mib ))

# gpt -r show: start size [index] contents. Pick the largest hole.
# On 4K Apple SSDs the contents column is often *blank* (not the word
# "Unused"). A real partition has "GPT part"; metadata has PMBR/GPT header.
best_start=0
best_size=0
while read -r start size rest; do
  [[ $start =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] || continue
  printf '%s' "$rest" | grep -Eq 'GPT part|PMBR|Pri GPT|Sec GPT' && continue
  if printf '%s' "$rest" | grep -q Unused || [[ -z "${rest// }" ]]; then
    if [[ $size -gt $best_size ]]; then
      best_start=$start
      best_size=$size
    fi
  fi
done < <(gpt -r show "/dev/$disk")

[[ $best_size -gt 0 ]] || fail "no Unused GPT region on $disk — shrink APFS from Disk Utility / Asahi, never from Linux"
[[ $best_size -ge $need_sectors ]] || fail "largest hole is $best_size sectors, need $need_sectors (${need_mib}MiB = installer ${installer_mib}MiB + reserve ${root_reserve_mib}MiB)"

hole_end=$(( best_start + best_size ))
installer_start=$(( hole_end - installer_sectors ))
# Align start down to 1MiB.
installer_start=$(( installer_start / sec_per_mib * sec_per_mib ))
[[ $installer_start -gt $best_start ]] || fail "aligned installer start landed on the hole start"
installer_sectors=$(( hole_end - installer_start ))
# Leave at least 1MiB if Recovery's start is the hole end; gpt add uses exact size.
root_hole_sectors=$(( installer_start - best_start ))
[[ $root_hole_sectors -ge $(( root_reserve_mib * sec_per_mib )) ]] || fail "leading hole after alignment is too small"

# Linux filesystem GUID. Name must stay omarchy-install (Linux TUI deletes only that).
linux_guid=0FC63DAF-8483-4772-8E79-3D69D8477DE4

printf '==> plan for /dev/%s\n' "$disk"
printf '    hole     start=%s size=%s sectors\n' "$best_start" "$best_size"
printf '    leave    start=%s size=%s sectors unallocated (Linux TUI fills this)\n' \
  "$best_start" "$root_hole_sectors"
printf '    add      start=%s size=%s name=omarchy-install\n' \
  "$installer_start" "$installer_sectors"
printf '    dd       %s (%s bytes) onto the new rdisk slice\n' "$payload_file" "$payload_bytes"
printf '    ESP      copy live GRUB next to m1n1 (m1n1/vendorfw/asahi stay)\n'

if [[ $confirm -eq 0 ]]; then
  printf '==> dry-run. Re-run with --confirm to write.\n'
  printf '    sudo gpt add -b %s -s %s -t %s -l omarchy-install %s\n' \
    "$installer_start" "$installer_sectors" "$linux_guid" "$disk"
  exit 0
fi

[[ $(id -u) -eq 0 ]] || fail " --confirm needs root (sudo)"

esp_dev=""
while read -r line; do
  printf '%s' "$line" | grep -qi 'EFI' || continue
  # diskutil list: "   3: EFI EFI-OMARC  500.0 MB  disk0s4"
  ident=$(printf '%s' "$line" | awk '{ print $NF }')
  [[ $ident == ${disk}s* ]] || continue
  esp_dev=$ident
done < <(diskutil list "$disk")
[[ -n $esp_dev ]] || fail "no EFI slice on $disk"

esp_mnt=/tmp/omarchy-nvme-efi
mkdir -p "$esp_mnt"
diskutil unmount "$esp_dev" >/dev/null 2>&1 || umount "$esp_mnt" >/dev/null 2>&1 || true
if ! diskutil mount "$esp_dev" >/dev/null 2>&1; then
  mount_msdos "/dev/$esp_dev" "$esp_mnt" || fail "could not mount ESP $esp_dev (diskutil and mount_msdos both failed)"
else
  auto_mnt=$(diskutil info "$esp_dev" | awk -F': *' '/Mount Point:/{print $2; exit}')
  [[ -n $auto_mnt && -d $auto_mnt ]] && esp_mnt=$auto_mnt
fi
[[ -d $esp_mnt/m1n1 ]] || fail "ESP $esp_dev has no m1n1/ at $esp_mnt — run Asahi UEFI-only first"
printf '==> ESP mounted at %s\n' "$esp_mnt"

hash_tree() {
  local root=$1 f
  # macOS find exits 1 if any named path is missing (often EFI/asahi).
  (cd "$root" && {
    [[ -d m1n1 ]] && find m1n1 -type f
    [[ -d vendorfw ]] && find vendorfw -type f
    [[ -d asahi ]] && find asahi -type f
    [[ -d EFI/asahi ]] && find EFI/asahi -type f
    true
  } 2>/dev/null | LC_ALL=C sort | while read -r f; do
    shasum -a 256 "$f"
  done)
  return 0
}
before=$(hash_tree "$esp_mnt")
printf '==> hashed ESP firmware; unmounting before partition add\n'
diskutil unmount "$esp_dev" >/dev/null 2>&1 || umount "$esp_mnt" >/dev/null 2>&1 || true

# Raw `gpt add` is EPERM on the internal SSD while macOS is booted.
# diskutil addPartition can use the hole, but only immediately *after*
# an existing slice, so: placeholder (leading hole) then installer, then
# free the placeholder. Result: [hole] [omarchy-install] [Recovery].
lead_bytes=$((root_hole_sectors * block_size))
inst_bytes=$((installer_sectors * block_size))
linux_before=$(diskutil list "$disk")

printf '==> diskutil placeholder (%s B) after %s, then omarchy-install (%s B)\n' \
  "$lead_bytes" "$esp_dev" "$inst_bytes"
diskutil addPartition "$esp_dev" %Linux% placeholder "${lead_bytes}B" \
  || fail "diskutil addPartition placeholder failed"
placeholder=""
while read -r ident; do
  [[ $ident == ${disk}s* ]] || continue
  diskutil info "$ident" 2>/dev/null | grep -q 'Linux Filesystem' || continue
  printf '%s' "$linux_before" | grep -q "$ident" && continue
  placeholder=$ident
done < <(diskutil list "$disk" | awk '/Linux Filesystem/{print $NF}')
[[ -n $placeholder ]] || fail "could not find placeholder slice after addPartition"
printf '    placeholder is %s\n' "$placeholder"

diskutil addPartition "$placeholder" %Linux% omarchy-install "${inst_bytes}B" \
  || fail "diskutil addPartition omarchy-install failed"
slice=""
linux_mid=$(diskutil list "$disk")
while read -r ident; do
  [[ $ident == ${disk}s* ]] || continue
  diskutil info "$ident" 2>/dev/null | grep -q 'Linux Filesystem' || continue
  [[ $ident == "$placeholder" ]] && continue
  printf '%s' "$linux_before" | grep -q "$ident" && continue
  slice=$ident
done < <(diskutil list "$disk" | awk '/Linux Filesystem/{print $NF}')
[[ -n $slice && $slice != "$placeholder" ]] || fail "could not find omarchy-install slice"
printf '    omarchy-install is %s\n' "$slice"

# gpt label is EPERM on the internal SSD (same as gpt add). The live
# TUI names the slice omarchy-install as soon as Linux boots.
idx=""
while read -r start size index rest; do
  [[ $start == "$installer_start" ]] || continue
  [[ $index =~ ^[0-9]+$ ]] || continue
  idx=$index
done < <(gpt -r show "/dev/$disk")
if [[ -n $idx ]] && gpt label -i "$idx" -l omarchy-install "$disk" 2>/dev/null; then
  printf '==> GPT name omarchy-install on index %s\n' "$idx"
else
  printf '==> macOS cannot set GPT names (EPERM); live TUI will name the slice\n'
fi

printf '==> freeing placeholder %s (leading hole for the TUI)\n' "$placeholder"
diskutil eraseVolume free none "$placeholder" \
  || fail "could not free placeholder $placeholder"

rslice=r${slice}
[[ -e /dev/$rslice ]] || fail "missing /dev/$rslice"
[[ $rslice != r${disk} && $rslice != rdisk0 ]] || fail "refusing whole-disk dd target $rslice"

printf '==> dd payload onto /dev/%s only\n' "$rslice"
dd if="$payload_file" of="/dev/$rslice" bs=4m status=progress
sync

printf '==> copying live GRUB onto the ESP\n'
esp_mnt=/tmp/omarchy-nvme-efi
mkdir -p "$esp_mnt"
diskutil unmount "$esp_dev" >/dev/null 2>&1 || true
if ! diskutil mount "$esp_dev" >/dev/null 2>&1; then
  mount_msdos "/dev/$esp_dev" "$esp_mnt" || fail "could not remount ESP $esp_dev for copy"
else
  auto_mnt=$(diskutil info "$esp_dev" | awk -F': *' '/Mount Point:/{print $2; exit}')
  [[ -n $auto_mnt && -d $auto_mnt ]] && esp_mnt=$auto_mnt
fi
mkdir -p "$esp_mnt/EFI/BOOT" "$esp_mnt/grub"
cp "$esp_files/BOOTAA64.EFI" "$esp_mnt/EFI/BOOT/BOOTAA64.EFI"
grub_cfg=""
if [[ -f $esp_files/grub-nvme-installer.cfg ]]; then
  grub_cfg=$esp_files/grub-nvme-installer.cfg
elif [[ -f $esp_files/grub.cfg ]]; then
  grub_cfg=$esp_files/grub.cfg
else
  fail "no grub-nvme-installer.cfg or grub.cfg in $esp_files"
fi
cp "$grub_cfg" "$esp_mnt/grub/grub.cfg"
cp "$grub_cfg" "$esp_mnt/EFI/BOOT/grub.cfg"
cp "$esp_files/vmlinuz-linux-asahi" "$esp_mnt/vmlinuz-linux-asahi"
cp "$esp_files/initramfs-omarchy-usb.img" "$esp_mnt/initramfs-omarchy-usb.img"
cp "$esp_files/initramfs-linux-asahi.img" "$esp_mnt/initramfs-linux-asahi.img"
: >"$esp_mnt/omarchy-usb-live"

after=$(hash_tree "$esp_mnt")
[[ $before == "$after" ]] || fail "m1n1/vendorfw/asahi changed — aborting"

printf '==> done. GPT name omarchy-install is %s.\n' "$slice"
printf '    Cold power on. U-Boot should load NVMe EFI/BOOT/BOOTAA64.EFI.\n'
printf '    Live TUI: Install into free space (the hole in front of omarchy-install).\n'
printf '    First boot of the installed root deletes omarchy-install and grows.\n'
diskutil list "$disk"
