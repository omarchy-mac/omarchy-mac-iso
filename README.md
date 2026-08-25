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

Systemd userspace plus the Omarchy *shell* packages — needs root,
`arch-install-scripts`, and local `omarchy-*.pkg.tar.*` (default
`~/.local/share/omarchy/build-output`):

```
sudo ./bin/omarchy-mac-iso-make --usb --rootfs
```

Autologin root on tty1 (`multi-user.target`, not SDDM). Payload is 8GiB
btrfs: NetworkManager, Asahi mesa / asahi-audio, gum, Hyprland, Quickshell,
SDDM, `omarchy` from those tarballs. Still does **not** pacstrap
`linux-asahi` or `asahi-scripts` (host ESP). Vendor firmware is copied from
the internal ESP at boot. Default `--usb` without `--rootfs` still hangs at
busybox pid 1. Override size with `OMARCHY_USB_PAYLOAD_BYTES`; package
search with `OMARCHY_LOCAL_PACKAGES`. Proven on metal 2026-08-25 (Lexar,
8GiB `OMARCHYLIVE`, `bootflow` `usb_mass_storage`): autologin
`root@omarchy-mac-live`, `pacman -Q` reported `omarchy 4.0.0-1`,
`hyprland 0.56.1-3`, `quickshell 0.3.1-1`, `sddm 0.21.0-7`. Still a tty,
not a graphical session.

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

Hiding NVMe `EFI/BOOT/BOOTAA64.EFI` (rename to `.omarchy-bak`; m1n1 stays)
makes U-Boot take USB GRUB — proven 2026-08-24 after `usb reset` (Type-C
still needs that). Restore from macOS if Linux will not boot: Apple picker
(hold power) → macOS. `diskutil mount "EFI - OMARC"` can fail even when
the volume is fine; then:

```
sudo mkdir -p /Volumes/esp
sudo mount -t msdos /dev/disk0s4 /Volumes/esp
mv /Volumes/esp/EFI/BOOT/BOOTAA64.EFI.omarchy-bak \
   /Volumes/esp/EFI/BOOT/BOOTAA64.EFI
sudo umount /Volumes/esp
```

Copy the pancake `BOOTAA64.EFI`, not the Lexar's `EFI/BOOT/` file (that is
USB GRUB). A spare copy lives on the live ESP as `omarchy-restore/`.

Wi-Fi: nmtui Rescan until SSIDs appear (a few rescans is normal), then
Activate. On the persistent USB root (2026-08-24) that was enough for
`ping www.google.com`; nmcli is optional.

### Clone vs install

On the live USB, `omarchy-mac-install` (refuses NVMe and Apple partition
GUIDs):

- **Clone** — `dd` through the last partition onto another stick (a 16GB-class
  stick is often smaller than the live USB). Unmounts source and target first
  unless this *is* the running live overlay. Rewrites the clone btrfs UUID.
  Proven from Omarchy and from the live USB (2026-08-23): Lexar ↔ 14.5G stick,
  `gum 2.0.0`, `fnmode=1`.
- **Install (wipe USB)** — GPT ESP (`OMARCHYBOOT`) + btrfs root filling the
  disk. Prompts for a desktop user, enables SDDM autologin
  (`omarchy.desktop` / Hyprland uwsm) and `graphical.target`. Live USB
  stays tty autologin. Proven on an M2 Max (2026-08-24): 14.5G stick,
  then console-only; graphical session not metal-proven yet. GRUB must
  search `/omarchy-usb-install`, not `/initramfs-linux-asahi.img`
  (that file is the NVMe LUKS initramfs).
- **Install into free space** — `parted mkpart` in an existing GPT hole only.
  Never `mklabel`/`wipefs`. Proven on the Lexar hole (keep live
  `OMARCHYISO`/`OMARCHYLIVE`, new `OMARCHYROOT` 11.4G) and on this NVMe
  after shrinking APFS **from macOS** (2026-08-24): p7 46G,
  `root@omarchy-mac`, existing Omarchy still the default GRUB entry.
  Parted whole-MiB starts can sit inside APFS on 4K NVMe — mkpart insets
  1MiB. Apple GPT snapshots use `lsblk -l` so tree glyphs do not abort
  after the new partition appears. Two System ESP modes: **piggyback** if
  `BOOTAA64.EFI` already exists (`custom.cfg` only, file unchanged);
  **own** if the ESP is UEFI-only (no GRUB) — same `grub-mkstandalone`
  recipe as wipe-USB, marker `/omarchy-mac-root`, never `mkfs` or
  `update-m1n1`. Kernel/initrd go in `EFI/omarchy/` so **any**
  `grub-mkconfig` on that ESP (pacman hook on the installed OS, not
  only the live USB) misses them. Legacy `vmlinuz-omarchy-usb-root` and
  `initramfs-omarchy-usb-root.img` on the ESP root are removed. `m1n1/` /
  `vendorfw/` / `asahi/` hashes must match after. Installer backups of
  `BOOTAA64.EFI` / `grub.cfg` / `custom.cfg` are `*.omarchy-bak` on the
  ESP (timestamped if a bak already exists). Kernel copies under
  `EFI/omarchy/` are not backed up — they are 50MiB and reproducible
  from the live USB. Other suffixes on this machine (`.iso-bak`,
  `.hand-*`, `.gen-badroot`) are ad-hoc restore copies, not installer. A fourth
  menu item writes GRUB for an existing `OMARCHYROOT` without `mkpart`.
  **Own-mode metal 2026-08-25:** hid NVMe GRUB, rebuilt live USB, free-space
  `mkpart` p7, wrote `BOOTAA64.EFI`, USB unplugged → `root@omarchy-mac`.
  U-Boot only loads one `BOOTAA64.EFI`; own-mode replaces an existing
  Omarchy GRUB. Restore pancake with the original file (not the live USB's)
  then `grub-mkconfig` so `quiet splash` brings the branded Plymouth unlock.
