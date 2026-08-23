#!/bin/bash
# Usage: build-usb-rootimg.sh <out-root.img>
# Tiny ext4 image with a marker file. Stand-in for a full Omarchy rootfs.
set -euo pipefail

out="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/tree"
printf 'omarchy-mac-live-ok usb-image %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$work/tree/omarchy-mac-live-ok"

rm -f "$out"
truncate -s 32M "$out"
mkfs.ext4 -F -q -L OMARCHYLIVE -d "$work/tree" "$out"
