# Omarchy Mac ISO

Install images for Omarchy on Apple Silicon. The shipped artifact is a
GPT disk image (`.img`) with a FAT32 ESP, not an ISO9660 file — the
repo name matches Omarchy's x86 ISO so people can find it.

Destination design: [plans/apple-silicon-image.md](plans/apple-silicon-image.md).
That is m1n1 → U-Boot → GRUB `BOOTAA64.EFI` → `linux-asahi` → a `root.img`
payload, proven on an M2 Max. This repo owns the live boot environment and
installer; [omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) owns
the installed system.

Default branch is `main`. That is unrelated to `omarchy-mac`'s `main`
(still v3.x); this tree has no v3 history.

## M0 — QEMU boot harness

M0 proves a reproducible ARM64 build crosses a generic AArch64 UEFI
boundary under QEMU, reaches Linux userspace, and emits a readiness
signal. **It will not boot an Apple Silicon Mac.** There is no m1n1,
U-Boot, Asahi kernel, or USB ESP in this artifact.

```
source
  -> ./bin/omarchy-mac-iso-make
  -> release/omarchy-mac-iso-arm64/{vmlinuz,initramfs.img}
  -> ./bin/omarchy-mac-iso-boot
  -> AArch64 UEFI (edk2) on QEMU virt
  -> Linux kernel + initramfs
  -> live userspace
  -> "OMARCHY_MAC_ISO_READY" on the serial console
```

Alpine aarch64 and `linux-virt` are throwaway M0 content so the harness
can run on a laptop without Asahi hardware or Docker. They are not the
installer distribution. Do not grow the TUI, disk partitioning, or LUKS
on top of this userspace — the next milestone replaces the payload with
the GPT `.img` in the plan.

## Requirements (M0)

- macOS or Linux, x86_64 or aarch64
- [`qemu`](https://www.qemu.org/) on `PATH`
  - macOS: `brew install qemu` (includes AArch64 UEFI firmware)
  - Debian/Ubuntu: `apt install qemu-system-arm qemu-efi-aarch64`
  - Arch: `pacman -S qemu-system-aarch64 edk2-armvirt`
- `curl`, `tar`, `cpio`, `gzip`, `shasum`
- No root privileges and no virtual disks: M0 boots from RAM

Hardware acceleration is used when available (HVF on Apple Silicon, KVM
on Linux aarch64 with `/dev/kvm`) and falls back to TCG otherwise.

## Build / boot / test (M0)

```
./bin/omarchy-mac-iso-make
./bin/omarchy-mac-iso-boot          # Ctrl-A X to quit
./test/unit                        # fast, no network, no VM
./test/smoke                       # full build + boot + marker + teardown
```

`omarchy-mac-iso-make` downloads pinned, checksummed upstream artifacts
(cached under `~/.cache/omarchy-mac-iso/`) and writes
`release/omarchy-mac-iso-arm64/{vmlinuz,initramfs.img,BUILD_INFO}`.

On smoke failure, the serial log is printed and the run directory is
kept for debugging.

## USB image (Apple Silicon host)

On a machine that already runs `linux-asahi`:

```
./bin/omarchy-mac-iso-make --usb
```

Writes `release/omarchy-mac-iso-usb/omarchy-mac-usb.img` — GPT with a FAT32
ESP labelled `OMARCHYISO` (standalone GRUB, this host's `linux-asahi`,
initramfs with `dwc3-apple`) and a btrfs payload labelled `OMARCHYLIVE`
(subvol `@`, tiny busybox `/sbin/init` until S3). No root required. Copying
files onto an existing FAT stick is not enough — the payload is its own
partition.

Flash (destroys the target stick):

```
sudo dd if=release/omarchy-mac-iso-usb/omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

**Shutdown, then power on** — a warm reboot often leaves Type-C/PD
unenumerated in U-Boot (`0 Storage Device(s) found`). After a cold start,
interrupt U-Boot (~1s) if NVMe already has Linux, and load the stick's
GRUB explicitly (do not `saveenv`):

```
load usb 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI
bootefi ${kernel_addr_r} ${fdtcontroladdr}
```

`bootflow select` of the USB row can still load NVMe's
`/EFI/BOOT/BOOTAA64.EFI` (same path on both ESPs). `bootcmd_usb0` is not
defined on this U-Boot. A fresh UEFI-only Mac has no NVMe EFI payload, so
the stick should win automatically after a cold start.

USB GRUB prints `OMARCHY USB GRUB (not the NVMe ESP)` and has one entry.
Omarchy Linux / Advanced options means you are on NVMe.

Success prints `OMARCHY_MAC_USB_READY`, then `OMARCHY_MAC_USB_USERSPACE pid=1`,
and hangs. This is not yet a full Omarchy desktop or installer.
