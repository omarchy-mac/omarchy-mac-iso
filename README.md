# Omarchy Mac ISO

Install images for Omarchy on Apple Silicon. The shipped artifact is a GPT disk image (`.img`) with a FAT32 ESP, not an ISO9660 file — the repo name matches Omarchy's x86 ISO so people can find it.

This repo owns the live USB and installer. [omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) owns the installed desktop. Destination design: [plans/apple-silicon-image.md](plans/apple-silicon-image.md). How to work in this tree: [AGENTS.md](AGENTS.md).

Default branch is `main`. That is unrelated to `omarchy-mac`'s `main` (still v3.x); this tree has no v3 history.

A Mac with no Asahi/m1n1 cannot boot this USB. iBoot will not load it until macOS has run the Asahi **UEFI-only** provision. Shrink APFS from macOS, never from Linux.

## USB image (Apple Silicon host)

On a machine that already runs `linux-asahi`:

```
sudo ./bin/omarchy-mac-iso-make --usb --rootfs
```

Writes `release/omarchy-mac-iso-usb/omarchy-mac-usb.img` — GPT with:

- ESP labelled `OMARCHYISO` — standalone GRUB, this host's `linux-asahi`, live initrd (`initramfs-omarchy-usb.img`, `dwc3-apple`) and install initrd (`initramfs-linux-asahi.img`)
- btrfs labelled `OMARCHYLIVE`, subvol `@` — systemd userspace plus the same `omarchy-base.packages` set as the script-based install (sudo, Chromium, Docker, fonts, …), plus local `omarchy` tarballs. Live session is tty autologin (`multi-user.target`), not a graphical login. Default payload is 12GiB with zstd; a 16GB stick is the floor. Override with `OMARCHY_USB_PAYLOAD_BYTES`.

Needs root, `arch-install-scripts`, a sibling `omarchy-mac` checkout (or `OMARCHY_PATH`) for `install/omarchy-base.packages`, and local `omarchy-*.pkg.tar.*` (default `~/.local/share/omarchy/build-output`). Does **not** pacstrap `linux-asahi` or `asahi-scripts` (those touch the host ESP). Vendor firmware is copied from the **internal** ESP at boot. `refresh-live` cannot add this package set — that needs a full `--usb --rootfs` rebuild.

`--usb` without `--rootfs` still writes a tiny busybox payload and is not the installer. Override payload size with `OMARCHY_USB_PAYLOAD_BYTES`; package search with `OMARCHY_LOCAL_PACKAGES`.

Flash (destroys the target stick):

```
sudo dd if=release/omarchy-mac-iso-usb/omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Copying files onto an existing FAT stick is not enough — the payload is its own partition.

### Refresh an existing live USB

Does not add packages. Updates installer scripts, GRUB cfg, systemd quieting, and rebuilds **both** initrds (live and install):

```
sudo ./bin/omarchy-mac-iso-refresh-live
```

Plug in the live stick (`OMARCHYISO` + `OMARCHYLIVE`). It can also update a wipe-installed USB (`OMARCHYBOOT`) and `/boot/EFI/omarchy/initramfs.img` on a machine that already has Omarchy. You want `copied installer onto the live USB` and `wrote …/initramfs-omarchy-usb.img`.

### U-Boot

**Shutdown, then power on** — a warm reboot often leaves Type-C unenumerated. Interrupt U-Boot (~1s) if NVMe already has Linux; a UEFI-only Mac with no NVMe EFI should take the stick. If `usb storage` is empty, `usb reset` until it appears. Do not `saveenv`.

```
usb reset
usb storage
load usb 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI
bootefi ${kernel_addr_r} ${fdtcontroladdr}
```

`bootflow scan -l` then the `usb_mass_storage` entry also works. `bootflow select` of a USB *row* can still load NVMe's `BOOTAA64.EFI` (same path). Live GRUB prints `OMARCHY USB GRUB`. "Omarchy Linux / Advanced options" means you are on NVMe.

Live boot is meant to be quiet (`loglevel=0`, systemd status off, Plymouth and ldconfig masked on the installer USB only). Installed disks keep `quiet splash` and branded Plymouth.

### Installer

On the live USB, tty1 autologin runs `omarchy-mac-install`. It never `mklabel`s a disk that already has Apple partition types.

It asks for a username, password (re-prompts on mismatch), hostname (empty → `omarchy`), full name and email (empty skips; used for git and XCompose), and whether to encrypt (default yes, same password as the user). Then it shows a table of every choice and **Does this look right?** before copying. Tokyo Night is seeded so the first graphical frame is not unthemed.

| Action | What it does |
|--------|----------------|
| **Install into free space** | `parted mkpart` in an existing GPT hole only. APFS/iBoot/Recovery stay. Needs unallocated space (macOS APFS shrink or Asahi UEFI-only leftover) |
| **Reinstall an existing Omarchy root** | Formats that partition only — no `mkpart`, no `mklabel`. Finds btrfs `OMARCHYROOT` or a LUKS volume labelled `OMARCHYROOT` / GPT name `root`. Does not offer Asahi's own LUKS |
| **Wipe a USB stick and install** | GPT ESP (`OMARCHYBOOT`) + root filling the stick. Persistent desktop, no overlay |
| **Write GRUB for an existing Omarchy root** | Bootloader only. Skips encrypted roots (needs the inner UUID) |
| **Clone** | `dd` through the last partition onto another stick; rewrites the clone btrfs UUID |

Wipe, free-space, and replace **copy used files** (`tar` of the overlay lowerdir onto a fresh btrfs `@` / `@home` / `@log`). They do not `dd` the payload. After the copy the installer runs `omarchy-apply-system --first-install` and `omarchy-provision-user --first-install` in the target (same as `omarchy-mac/install.sh`). First graphical login still runs `omarchy-provision-first-run` for the welcome / timezone / Wi-Fi / update toasts. Clone is still a block copy.

LUKS is offered on wipe, free-space, and replace. New containers get label `OMARCHYROOT`. Install initrd runs Plymouth before `encrypt` so there is one branded unlock, not a text prompt then Plymouth.

### System ESP after a disk install

Two modes, never `mkfs` of the ESP, never `update-m1n1`:

- **Piggyback** — `BOOTAA64.EFI` already exists: write `grub/custom.cfg` only, leave the file bytes unchanged
- **Own** — UEFI-only ESP with no GRUB: write `BOOTAA64.EFI` and marker `/omarchy-mac-root`

Kernels live under `EFI/omarchy/` so a later `grub-mkconfig` on that ESP does not pick them up as stray entries. Backups of `BOOTAA64.EFI` / `grub.cfg` / `custom.cfg` are `*.omarchy-bak` on the ESP. `m1n1/` / `vendorfw/` / `asahi/` hashes must match after.

### Wi-Fi on the live USB

nmtui **Rescan** until SSIDs appear, then Activate. A few rescans is normal.

## Tests

```
./test/unit
```

Syntax, installer greps, partition loopback, ESP GRUB loopback. No network, no Mac. `./test/smoke` is the M0 QEMU harness.

## M0 — QEMU boot harness

M0 proves a reproducible ARM64 build crosses a generic AArch64 UEFI boundary under QEMU. **It will not boot an Apple Silicon Mac.** There is no m1n1, U-Boot, Asahi kernel, or USB ESP in that artifact.

```
./bin/omarchy-mac-iso-make
./bin/omarchy-mac-iso-boot          # Ctrl-A X to quit
```

Alpine aarch64 and `linux-virt` are throwaway so the harness can run without Asahi hardware. Do not grow the installer TUI on top of that userspace.

Requirements: `qemu` on PATH (HVF or KVM when available, else TCG), `curl`, `tar`, `cpio`, `gzip`, `shasum`. No root. Artifacts cache under `~/.cache/omarchy-mac-iso/`.
