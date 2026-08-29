# Agents

This repo is **omarchy-mac-iso**: the Apple Silicon live USB and installer. It is not [omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) (the installed desktop). Edits here do nothing on a running machine until they are copied onto a USB (or into an installed ESP).

`plans/apple-silicon-image.md` is the destination design. `README.md` is how to build and flash.

## What an agent is allowed to touch

- Live USB image, initramfs, installer TUI, GRUB embeds, and tests in this tree
- A plugged-in live USB via `sudo ./bin/omarchy-mac-iso-refresh-live` when the user asked to try a change on metal

Never:

- `mklabel`, `wipefs`, or partition-delete on a disk that already has Apple GPT types (APFS / iBoot / Recovery). Shrinking APFS happens in **macOS only**. Altering APFS from Linux can force a DFU restore
- Put hostnames, USB brand names, or other machine-specific strings into shipped installer copy
- Open a PR unless the user asked for one
- Treat a successful `./test/unit` as a visual or metal proof

## Two artifacts, two initrds

The USB GPT is ESP (`OMARCHYISO`) + btrfs payload (`OMARCHYLIVE`, subvol `@`).

| Boot | ESP file | Initrd config |
|------|----------|----------------|
| Live installer | `initramfs-omarchy-usb.img` | `configs/usb-initcpio/mkinitcpio.conf` (overlay, `omarchy-usb-live`) |
| Installed disk | `initramfs-linux-asahi.img` (copied as `initramfs-omarchy-usb-root.img` or `EFI/omarchy/initramfs.img`) | `configs/usb-initcpio/mkinitcpio-install.conf` (wait + encrypt + Plymouth) |

`refresh-live` must rebuild **both** when the live USB is plugged in. Updating only the install initrd leaves live boot on a stale `initramfs-omarchy-usb.img`.

A full image is `sudo ./bin/omarchy-mac-iso-make --usb --rootfs` (pacstraps `omarchy-base.packages` plus sudo; 12GiB payload). The builder `pacman -Sy`s first and **fails** if a listed package is not in repos, not a remap, not a local tarball, and not in `packages-aarch64-skip`. Use refresh for installer scripts, GRUB cfg, and initrds on an existing stick. Refresh cannot grow the package set — that needs a rootfs rebuild. 1Password is not pre-installed; `omarchy-install-1password` after first boot sets the browser helper.

## Installer paths

`omarchy-mac-install` on the live overlay:

- **Wipe USB** / **free space** / **replace existing** — `mkfs.btrfs` then `tar` of used files from the overlay lowerdir (`/run/omarchy-root`). Not a `dd` of the payload
- **Clone** — still `dd` through the last partition; rewrite the clone btrfs UUID
- LUKS is offered on wipe, free-space, and replace. Same password as the desktop user. New LUKS volumes get label `OMARCHYROOT`
- Replace-existing looks for btrfs `OMARCHYROOT` **or** `crypto_LUKS` with that label / GPT name `root`. Asahi's own LUKS has neither — do not offer it
- Identity validation re-prompts. Full name and email are optional (git + XCompose). Before the copy, show a table of action, target, user, password stars, full name, email, hostname, encryption, then "Does this look right?"
- System ESP: **piggyback** (`custom.cfg` only) if `BOOTAA64.EFI` already exists; **own** if the ESP has none. Never rewrite `m1n1/`, `vendorfw/`, or `asahi/`

Free space needs an unallocated GPT hole (from a macOS APFS shrink or Asahi UEFI-only). If the hole is already a partition, use replace-existing.

## Tests

```
./test/unit
```

That runs `bash -n`, installer greps, `test/partition`, and `test/esp-grub`. It does not boot a Mac.

Grep tests must fail if the behavior is removed. Do not match a string that still exists in a comment after the real call is gone.

## Metal

- Firmware for Wi-Fi comes from the **internal** ESP (`asahi` hook). The stick does not ship it
- U-Boot: cold power on (warm reboot often misses Type-C). `usb reset` until storage appears. Do not `saveenv`. A machine that already has Linux on NVMe must interrupt U-Boot or NVMe GRUB wins
- A Mac with no Asahi/m1n1 cannot boot this USB. iBoot will not load it until macOS has run the Asahi **UEFI-only** provision (`kmutil`). That step is out of this repo
- Live boot should stay quiet (`loglevel=0`, `systemd.show_status=0`, live GRUB masks Plymouth/ldconfig). Installed disks keep `quiet splash` and Plymouth. Confirm on the live stick after refresh, not only in git

## Style

- `#!/bin/bash` in this repo's scripts
- Full English names
- `[[ ]]` for strings/files, `(( ))` for numbers
- Installer `fail` exits; user validation uses `retry` and loops

## Working from another machine

Unit tests and editing this git tree work on any host (including x86 Omarchy). `refresh-live` and live/install `mkinitcpio` need a machine that already runs `linux-asahi` (dwc3-apple, host modules, vendor firmware layout). After a wipe of the Asahi box, keep a clone of this repo on a second computer so the branch still exists even if the NVMe does not.
