#!/bin/bash
# Usage: build-usb-rootimg.sh <out-payload.img>
# Btrfs payload (label OMARCHYLIVE) with @ / @home / @log. Tiny busybox
# /sbin/init lives on @ — S3 replaces this tree with a pacstrap'd Omarchy.
# compress=none so a later zip still shrinks. Copy the busybox ELF and libc,
# not a symlink (that is what panicked the overlay spike). Unprivileged:
# mkfs.btrfs --rootdir --subvol.
set -euo pipefail

out="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bb=/usr/lib/initcpio/busybox
live_init="$repo_root/configs/usb/live-init"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -x $bb ]] || fail "no $bb — mkinitcpio is required"
[[ -f $live_init ]] || fail "missing $live_init"
[[ ! -L $bb ]] || fail "$bb is a symlink; copy the ELF"
command -v readelf >/dev/null && command -v ldd >/dev/null && command -v file >/dev/null \
  || fail "need readelf, ldd, and file to pack busybox and its libraries"
command -v mkfs.btrfs >/dev/null || fail "need btrfs-progs"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rootdir="$work/root"
tree="$rootdir/@"

copy_into_tree() {
  local src=$1 rel=$2
  mkdir -p "$tree/$(dirname "$rel")"
  cp -L "$src" "$tree$rel"
  chmod 755 "$tree$rel"
  [[ ! -L $tree$rel ]] || fail "$rel is still a symlink after cp -L"
}

copy_shared_objects() {
  local bin=$1 interp lib
  interp=$(readelf -l "$bin" | sed -n 's/.*program interpreter: \([^]]*\).*/\1/p')
  if [[ -n $interp ]]; then
    copy_into_tree "$(readlink -f "$interp")" "$interp"
  fi
  while read -r lib; do
    [[ -e $lib ]] || continue
    copy_into_tree "$(readlink -f "$lib")" "$lib"
  done < <(ldd "$bin" | awk '/=> \// {print $3}')
}

mkdir -p "$tree/bin" "$tree/sbin" "$tree/proc" "$tree/sys" "$tree/dev" "$tree/run" "$tree/tmp"
mkdir -p "$rootdir/@home" "$rootdir/@log"

printf 'omarchy-mac-live-ok usb-image %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$tree/omarchy-mac-live-ok"

copy_into_tree "$bb" /bin/busybox
copy_shared_objects "$bb"
for applet in sh ash cat ls echo sleep; do
  ln -sf busybox "$tree/bin/$applet"
done

install -m755 "$live_init" "$tree/sbin/init"
cp -L "$tree/sbin/init" "$tree/init"
chmod 755 "$tree/init"

file -b "$tree/bin/busybox" | grep -q ELF || fail "busybox in payload is not an ELF"
[[ -x $tree/sbin/init && ! -L $tree/sbin/init ]] || fail "/sbin/init must be a regular executable"

rm -f "$out"
truncate -s 128M "$out"
mkfs.btrfs -q -L OMARCHYLIVE --csum crc32c \
  --rootdir "$rootdir" \
  --subvol default:@ \
  --subvol rw:@home \
  --subvol rw:@log \
  "$out"
