#!/bin/bash
# Prints minirootfs and kernel cache paths, one per line.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${script_dir}/versions.env"

cache_dir="${OMARCHY_MAC_ISO_CACHE:-${HOME}/.cache/omarchy-mac-iso}"
mkdir -p "${cache_dir}"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

verify_sha256() {
    local path="$1" expected="$2"
    local actual
    actual="$(shasum -a 256 "${path}" | cut -d' ' -f1)"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "checksum mismatch for $(basename "${path}"): expected ${expected}, got ${actual} (delete ${path} and retry, or the pin in versions.env is stale)"
    fi
}

fetch_pinned() {
    local url="$1" sha256="$2" dest="$3"

    if [[ -f "${dest}" ]]; then
        if actual="$(shasum -a 256 "${dest}" | cut -d' ' -f1)" && [[ "${actual}" == "${sha256}" ]]; then
            log "using cached $(basename "${dest}")"
            return 0
        fi
        log "cached $(basename "${dest}") failed checksum, re-downloading"
        rm -f "${dest}"
    fi

    log "downloading $(basename "${dest}")"
    local tmp
    tmp="$(mktemp "${dest}.XXXXXX")"
    if ! curl -fSL --progress-bar "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        fail "download failed: ${url}"
    fi
    verify_sha256 "${tmp}" "${sha256}"
    mv "${tmp}" "${dest}"
}

minirootfs_dest="${cache_dir}/alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
kernel_dest="${cache_dir}/linux-virt-${KERNEL_PKG_VERSION}.apk"

fetch_pinned "${MINIROOTFS_URL}" "${MINIROOTFS_SHA256}" "${minirootfs_dest}"
fetch_pinned "${KERNEL_PKG_URL}" "${KERNEL_PKG_SHA256}" "${kernel_dest}"

printf '%s\n%s\n' "${minirootfs_dest}" "${kernel_dest}"
