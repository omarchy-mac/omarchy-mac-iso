#!/usr/bin/env python3
# Replace the j613 DTB slot in an existing m1n1 boot.bin with that DTB plus
# configs/m1n1/j613-dcp.dtbo. The new blob is padded to the slot length so
# every other byte of boot.bin stays identical. Never a full boot.bin swap.
#
# Usage:
#   patch-boot-bin-dcp.py --boot-bin PATH --dtbo PATH [--write]
#   patch-boot-bin-dcp.py --self-test
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile

MAGIC = b"\xd0\x0d\xfe\xed"


def find_j613_slot(boot: bytes) -> tuple[int, int]:
    off = 0
    while True:
        off = boot.find(MAGIC, off)
        if off < 0:
            break
        if off + 8 > len(boot):
            break
        total = struct.unpack(">I", boot[off + 4 : off + 8])[0]
        if 0x1000 <= total <= 0x100000 and off + total <= len(boot):
            blob = boot[off : off + total]
            if b"apple,j613" in blob and b"apple,t8122" in blob:
                return off, total
            off += total
        else:
            off += 4
    raise SystemExit("j613 DTB slot not found in boot.bin")


def pad_dtb(dtb: bytes, slot_len: int) -> bytes:
    if len(dtb) > slot_len:
        raise SystemExit(
            f"DTB is {len(dtb)} bytes, larger than the m1n1 slot ({slot_len})"
        )
    padded = bytearray(dtb + b"\0" * (slot_len - len(dtb)))
    padded[4:8] = struct.pack(">I", slot_len)
    return bytes(padded)


def splice(boot: bytes, off: int, slot_len: int, padded: bytes) -> bytes:
    if len(padded) != slot_len:
        raise SystemExit("padded DTB length does not match the slot")
    cand = boot[:off] + padded + boot[off + slot_len :]
    if len(cand) != len(boot):
        raise SystemExit("boot.bin length changed")
    if cand[:off] != boot[:off] or cand[off + slot_len :] != boot[off + slot_len :]:
        raise SystemExit("bytes outside the j613 slot would change")
    return cand


def slot_has_dcp(blob: bytes) -> bool:
    return b"apple,t8122-dcp" in blob or b"apple,dcp" in blob


def fdtoverlay(base: bytes, dtbo_path: str) -> bytes:
    fdtoverlay_bin = shutil.which("fdtoverlay")
    if not fdtoverlay_bin:
        raise SystemExit("fdtoverlay not found (pacman -S dtc)")
    with tempfile.TemporaryDirectory() as tmp:
        base_path = os.path.join(tmp, "base.dtb")
        out_path = os.path.join(tmp, "out.dtb")
        with open(base_path, "wb") as f:
            f.write(base)
        subprocess.check_call(
            [fdtoverlay_bin, "-i", base_path, "-o", out_path, dtbo_path]
        )
        with open(out_path, "rb") as f:
            return f.read()


def patch(boot_bin: str, dtbo: str, write: bool) -> None:
    with open(boot_bin, "rb") as f:
        boot = f.read()
    off, slot_len = find_j613_slot(boot)
    blob = boot[off : off + slot_len]
    if slot_has_dcp(blob):
        print(f"j613 slot at 0x{off:x} already has DCP nodes; leaving boot.bin")
        return
    merged = fdtoverlay(blob, dtbo)
    padded = pad_dtb(merged, slot_len)
    cand = splice(boot, off, slot_len, padded)
    print(
        f"j613 slot 0x{off:x} {slot_len} bytes; overlay applied "
        f"({len(merged)} -> {slot_len} padded)"
    )
    print(f"orig sha256: {hashlib.sha256(boot).hexdigest()}")
    print(f"new  sha256: {hashlib.sha256(cand).hexdigest()}")
    if not write:
        print("dry-run (pass --write to replace boot.bin, backup .bak-predcp)")
        return
    bak = boot_bin + ".bak-predcp"
    if not os.path.exists(bak):
        shutil.copy2(boot_bin, bak)
        print(f"backup {bak}")
    with open(boot_bin, "wb") as f:
        f.write(cand)


def self_test() -> None:
    slot_len = 0x2000
    body = b"\x00" * 64 + b"apple,j613\0apple,t8122\0" + b"\x00" * (slot_len - 64 - 22)
    dtb = bytearray(slot_len)
    dtb[0:4] = MAGIC
    dtb[4:8] = struct.pack(">I", slot_len)
    dtb[64:] = body[64:]
    prefix = b"HEAD" * 16
    suffix = b"TAIL" * 16
    boot = prefix + bytes(dtb) + suffix
    off, found_len = find_j613_slot(boot)
    assert off == len(prefix), off
    assert found_len == slot_len, found_len
    small = MAGIC + struct.pack(">I", 128) + b"\x00" * 120
    padded = pad_dtb(small, slot_len)
    assert len(padded) == slot_len
    assert struct.unpack(">I", padded[4:8])[0] == slot_len
    cand = splice(boot, off, slot_len, padded)
    assert cand[:off] == boot[:off]
    assert cand[off + slot_len :] == boot[off + slot_len :]
    assert len(cand) == len(boot)
    try:
        find_j613_slot(b"not a boot.bin")
    except SystemExit:
        pass
    else:
        raise SystemExit("expected missing-slot to fail")
    print("self-test ok")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--boot-bin")
    p.add_argument("--dtbo")
    p.add_argument("--write", action="store_true")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.boot_bin or not args.dtbo:
        p.error("--boot-bin and --dtbo are required (or --self-test)")
    patch(args.boot_bin, args.dtbo, args.write)


if __name__ == "__main__":
    main()
