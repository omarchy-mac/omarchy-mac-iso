#!/bin/bash
# Usage: build-initramfs.sh <minirootfs.tar.gz> <linux-virt.apk> <out-dir>
set -euo pipefail

minirootfs="$1"
kernel_apk="$2"
out_dir="$3"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

stage_dir="${work_dir}/root"
mkdir -p "${stage_dir}"

log "extracting Alpine userspace"
tar -xzf "${minirootfs}" -C "${stage_dir}"

log "extracting kernel from linux-virt package"
kernel_stage="${work_dir}/kernel"
mkdir -p "${kernel_stage}"
tar -xzf "${kernel_apk}" -C "${kernel_stage}" boot/vmlinuz-virt
[[ -f "${kernel_stage}/boot/vmlinuz-virt" ]] || fail "linux-virt package did not contain boot/vmlinuz-virt"

log "installing init"
install -m 755 "${script_dir}/../configs/initramfs/init" "${stage_dir}/init"

log "packing initramfs"
mkdir -p "${out_dir}"
( cd "${stage_dir}" && find . -print0 | cpio --null -o -H newc ) \
    | gzip -9 > "${out_dir}/initramfs.img"

cp "${kernel_stage}/boot/vmlinuz-virt" "${out_dir}/vmlinuz"

log "staged $(du -h "${out_dir}/vmlinuz" | cut -f1) kernel + $(du -h "${out_dir}/initramfs.img" | cut -f1) initramfs"
