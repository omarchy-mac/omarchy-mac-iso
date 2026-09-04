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

Writes `release/omarchy-mac-iso-usb/` — GPT image plus the files the NVMe placer copies:

- `omarchy-mac-usb.img` — GPT with ESP labelled `OMARCHYISO` (standalone GRUB, this host's `linux-asahi`, live initrd `initramfs-omarchy-usb.img`, install initrd `initramfs-linux-asahi.img`) and btrfs labelled `OMARCHYLIVE`, subvol `@`
- `payload.img` — that btrfs partition alone (what macOS `dd`s onto `omarchy-install`). **Not** the full GPT image
- `vmlinuz-linux-asahi`, both initrds, `BOOTAA64.EFI`, `grub-nvme-installer.cfg`

Live session is tty autologin (`multi-user.target`), not a graphical login. Default payload is 12GiB with zstd; a 16GB stick is the floor. Override with `OMARCHY_USB_PAYLOAD_BYTES`.

A 7.1.6 host `appledrm` has no V14_7; the builder **fails** unless you set `OMARCHY_ALLOW_OLD_APPLEDRM=1` (simpledrm) or point `OMARCHY_KVER` / `OMARCHY_VMLINUZ` / `OMARCHY_MODULES_DIR` at a ≥7.2 tree. Initrds in the release dir are `chmod a+r` so they can be copied off the builder.

Needs root, `arch-install-scripts`, a sibling `omarchy-mac` checkout (or `OMARCHY_PATH`) for `install/omarchy-base.packages`, and local `omarchy-*.pkg.tar.*` (default `~/.local/share/omarchy/build-output`). Does **not** pacstrap `linux-asahi` or `asahi-scripts` (those touch the host ESP). Vendor firmware is copied from the **internal** ESP at boot. `refresh-live` cannot add this package set — that needs a full `--usb --rootfs` rebuild.

`--usb` without `--rootfs` still writes a tiny busybox payload and is not the installer. Override payload size with `OMARCHY_USB_PAYLOAD_BYTES`; package search with `OMARCHY_LOCAL_PACKAGES`.

Flash (destroys the target stick):

```
sudo dd if=release/omarchy-mac-iso-usb/omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Copying files onto an existing FAT stick is not enough — the payload is its own partition.

### NVMe installer (no USB)

M3 Type-C often never appears in U-Boot. After Asahi **UEFI-only** (M3: `EXPERT=true` and `curl -L https://alx.sh/dev | sh`, firmware 14.8.3), you need an **unallocated** GPT hole (shrink APFS from macOS, or `diskutil eraseVolume free none` on an existing Linux slice only — never APFS / Recovery / the `m1n1` ESP). Hole size should be about **twice** the payload (copy + installer) plus slack.

Copy `payload.img`, the two initrds, `vmlinuz-linux-asahi`, `BOOTAA64.EFI`, and `grub-nvme-installer.cfg` onto the Mac, plus `scripts/macos/place-nvme-installer.sh`. Do **not** `dd` `omarchy-mac-usb.img` onto the internal disk.

```
# Dry-run first. --confirm writes.
sudo ./place-nvme-installer.sh \
  --payload ./payload.img \
  --esp-files .
```

On the internal SSD, `gpt add` / `gpt label` are **EPERM** while macOS is booted. The placer uses 4K native sectors, then `diskutil addPartition` a placeholder (the leading hole) + `omarchy-install` at the tail, then `eraseVolume free none` on the placeholder. `dd` is only onto the new `rdisk0sN`. Live GRUB is copied next to `m1n1/` (`m1n1` / `vendorfw` / `asahi` hashes must match).

macOS leaves the GPT **name** empty. The live TUI names the NVMe payload `omarchy-install` (needed for own-mode GRUB and consume). Cold power on, **Install into free space** into the hole in front of that slice, not replace-existing. First boot of the new root deletes **only** `omarchy-install` and grows.

Metal (M3 Air, 7.1.6): LUKS `OMARCHYROOT` 119.7G → 131.7G after consume; APFS/Recovery stayed; display was `simpledrm`. Detailed checklist: [docs/m3-716-nvme-installer.md](docs/m3-716-nvme-installer.md).

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

M3 (`apple,j613`) display needs `linux-asahi` **>= 7.2** (appledrm V14_7) plus the DCP nodes in m1n1's bundled DTB. A 7.1.6 image boots `simpledrm` only. Build on a 7.2 host, or set `OMARCHY_KVER` / `OMARCHY_VMLINUZ` / `OMARCHY_MODULES_DIR`. The installer then overlays `configs/m1n1/j613-dcp.dtbo` into the j613 slot of the existing `m1n1/boot.bin` (backup `.bak-predcp`). It does not use GRUB `devicetree` and does not write extlinux. Unencrypted roots get `initramfs-linux-asahi-plain.img` (no `encrypt` hook). `OMARCHY_ALLOW_OLD_APPLEDRM=1` forces a simpledrm-capable 7.1 image.

### Installer

On the live USB, tty1 autologin runs `omarchy-mac-install`. It never `mklabel`s a disk that already has Apple partition types.

It asks for a username, password (re-prompts on mismatch), hostname (empty → `omarchy`), full name and email (empty skips; used for git and XCompose), and whether to encrypt (default yes, same password as the user). Then it shows a table of every choice and **Does this look right?** before copying. Tokyo Night is seeded so the first graphical frame is not unthemed.

| Action | What it does |
|--------|----------------|
| **Install into free space** | `parted mkpart` in an existing GPT hole only. APFS/iBoot/Recovery stay. Needs unallocated space (macOS APFS shrink, Asahi UEFI-only leftover, or the hole in front of an `omarchy-install` slice) |
| **Reinstall an existing Omarchy root** | Formats that partition only — no `mkpart`, no `mklabel`. Finds btrfs `OMARCHYROOT` or a LUKS volume labelled `OMARCHYROOT` / GPT name `root`. Does not offer Asahi's own LUKS |
| **Wipe a USB stick and install** | GPT ESP (`OMARCHYBOOT`) + root filling the stick. Persistent desktop, no overlay |
| **Write GRUB for an existing Omarchy root** | Bootloader only. Skips encrypted roots (needs the inner UUID) |
| **Clone** | `dd` through the last partition onto another stick; rewrites the clone btrfs UUID |

Wipe, free-space, and replace **copy used files** (`tar` of the overlay lowerdir onto a fresh btrfs `@` / `@home` / `@log`). They do not `dd` the payload. After the copy the installer runs `omarchy-apply-system --first-install` and `omarchy-provision-user --first-install` in the target (same as `omarchy-mac/install.sh`). First graphical login still runs `omarchy-provision-first-run` for the welcome / timezone / Wi-Fi / update toasts. Clone is still a block copy.

LUKS is offered on wipe, free-space, and replace. New containers get label `OMARCHYROOT`. Install initrd runs Plymouth before `encrypt` so there is one branded unlock, not a text prompt then Plymouth.

### System ESP after a disk install

Never `mkfs` of the ESP, never `update-m1n1`:

- **Piggyback** — some other OS already owns `BOOTAA64.EFI`: write `grub/custom.cfg` only, leave the file bytes unchanged
- **Own** — UEFI-only ESP with no GRUB, **or** this NVMe live installer wrote `BOOTAA64.EFI`: write `BOOTAA64.EFI` and marker `/omarchy-mac-root`. Do not piggyback the live menu; this GRUB embed does not show `custom.cfg` entries (M3 Air: only “NVMe installer” appeared until `grub.cfg` listed the new root first)

Kernels live under `EFI/omarchy/` so a later `grub-mkconfig` on that ESP does not pick them up as stray entries. Backups of `BOOTAA64.EFI` / `grub.cfg` / `custom.cfg` are `*.omarchy-bak` on the ESP. `m1n1/` / `vendorfw/` / `asahi/` hashes must match after, except the j613 DTB slot in `m1n1/boot.bin`.

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
