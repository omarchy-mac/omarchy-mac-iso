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
(subvol `@`, tiny busybox `/sbin/init`). No root required. Copying files
onto an existing FAT stick is not enough — the payload is its own partition.

Systemd userspace (not the Omarchy desktop) — needs root, `arch-install-scripts`:

```
sudo ./bin/omarchy-mac-iso-make --usb --rootfs
```

Autologin root on tty1. Payload has NetworkManager, `iwd`, Asahi mesa,
asahi-audio, gum, `hid_apple fnmode=1`, `appledrm show_notch=1`, parted,
gptfdisk, btrfs-progs, dosfstools, and grub. Vendor firmware is copied from
the internal ESP at boot. Default `--usb` without `--rootfs` still hangs at
busybox pid 1.

Flash (destroys the target stick):

```
sudo dd if=release/omarchy-mac-iso-usb/omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### U-Boot

**Shutdown, then power on** — a warm reboot often leaves Type-C/PD
unenumerated (`0 Storage Device(s) found`). Interrupt U-Boot (~1s) if NVMe
already has Linux. If `usb storage` is empty or U-Boot skips the stick
(`Cannot read configuration, skipping device 05dc:c753` on the Lexar),
`usb reset` until storage appears (twice on metal, 2026-08-23). Do not
`saveenv`.

```
usb reset
usb storage
load usb 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI
bootefi ${kernel_addr_r} ${fdtcontroladdr}
```

`bootflow select` of a USB *row* can still load NVMe's
`/EFI/BOOT/BOOTAA64.EFI` (same path). `bootflow scan -l` then select the
`usb_mass_storage` entry (seq 2 on metal, 2026-08-24) and `bootflow boot`
does load the stick. `load usb 0:1 …` / `bootefi` still works. `bootcmd_usb0`
is not defined. Live GRUB prints `OMARCHY USB GRUB`; installed GRUB prints
`OMARCHY USB INSTALL` / menu `Omarchy Mac (USB root)`. Omarchy Linux /
Advanced options means you are on NVMe.

Wi-Fi: nmtui Rescan until SSIDs appear, then Activate or
`nmcli device wifi connect 'SSID' password 'PSK'`.

### Clone vs install

On the live USB, `omarchy-mac-install` (refuses NVMe and Apple partition
GUIDs):

- **Clone** — `dd` through the last partition onto another stick (a 16GB-class
  stick is often smaller than the live USB). Unmounts source and target first
  unless this *is* the running live overlay. Rewrites the clone btrfs UUID.
  Proven from Omarchy and from the live USB (2026-08-23): Lexar ↔ 14.5G stick,
  `gum 2.0.0`, `fnmode=1`.
- **Install** — GPT ESP (`OMARCHYBOOT`) + btrfs root (`OMARCHYROOT`) filling
  the disk, copy the payload, `btrfs resize max`, GRUB with `root=UUID=`.
  Persistent root, no overlay, no LUKS, not Omarchy packages. Do not name
  the initrd `initramfs-linux-asahi.img` (NVMe ESP has that; GRUB then
  loads the LUKS initramfs). Proven on an M2 Max (2026-08-24): 14.5G stick,
  `omarchy-usb-wait` mounted `UUID=e68e2508-…`, systemd mounted
  `OMARCHYBOOT`/`OMARCHYROOT`, autologin `root@omarchy-mac`.
