# M3 Air — 7.1.6 NVMe installer test

First metal pass (2026-09-03): LUKS free-space install, then consume grew `OMARCHYROOT` 119.7G → 131.7G. APFS / Recovery stayed. Display was `simpledrm`.

Use this as a **checklist on the Mac** or as a **prompt for an agent sitting with you**. It is only the no-USB installer layout (hole + `omarchy-install` + TUI + consume). It is **not** the 7.2 / `apple-drm` display install.

The tree now auto-names the NVMe payload `omarchy-install` and own-modes GRUB when that slice is the live source. A payload built **before** that still needs the hand `parted name` and a `grub.cfg` that lists the new root first (this GRUB did not show `custom.cfg` entries).

The current Linux root on the Air is disposable. 7.2 / `appledrm` already lives on the builder (`~/code/research/j613/` and `linux-asahi`). Wipe **only** the Linux slice(s). Keep macOS, Recovery, and the Asahi ESP (`m1n1/` / `vendorfw/` / `asahi/`).

## If you are an agent

You are helping Scott test `omarchy-mac-iso` on an M3 Air (`apple,j613` / Mac15,12). Follow this file in order. Do not skip stop rules.

Never:

- `dd` onto `disk0` / `rdisk0` / the whole internal disk
- `diskutil eraseDisk`, `gpt destroy`, `mklabel`, or `wipefs` of a disk that has APFS / iBoot / Recovery
- Delete APFS, iBoot, Recovery, or the EFI slice that contains `m1n1/`
- Shrink or edit APFS from Linux
- Re-run Asahi (`alx.sh` / Alarm). UEFI-only is already done
- `update-m1n1`, or replace all of `m1n1/boot.bin`
- `saveenv` in U-Boot
- Treat a green `./test/unit` as metal proof

Expect **simpledrm** (2560×1600-ish, no GPU). Success is partitions + TUI + first-boot consume, not `apple-drm`.

## What this test proves

After a cold boot with **no USB**:

1. Live TUI from a GPT slice named `omarchy-install` at the **tail** of a hole
2. **Install into free space** fills the hole **in front** of that slice
3. First boot of the new root deletes **only** `omarchy-install` and grows
4. APFS / iBoot / Recovery / ESP `m1n1` are still there

## What you need on a stick or AirDrop

From the builder (today that host is 7.1.6). If `omarchy-mac-iso-make --usb --rootfs` dies on `V14_7`:

```bash
sudo OMARCHY_ALLOW_OLD_APPLEDRM=1 ./bin/omarchy-mac-iso-make --usb --rootfs
```

Copy the whole `release/omarchy-mac-iso-usb/` folder **and** `scripts/macos/place-nvme-installer.sh` onto the Mac. Minimum files in that folder:

| File | Why |
|------|-----|
| `payload.img` (or `.zst`) | live btrfs (`OMARCHYLIVE`) |
| `vmlinuz-linux-asahi` | 7.1.6 kernel |
| `initramfs-omarchy-usb.img` | live overlay initrd |
| `initramfs-linux-asahi.img` | installed-root initrd (LUKS) |
| `BOOTAA64.EFI` | live GRUB |
| `grub-nvme-installer.cfg` | NVMe live menu (fallback: `grub.cfg`) |

`initramfs-linux-asahi-plain.img` is optional. Without it, an unencrypted install may print a spurious LUKS line in the initrd; encrypt anyway for this test.

7.2 salvage is already on the builder (`vmlinuz-wip72`, `modules-7.2.2-omarchy-wip72+.tar`, overlay, `boot.bin.dcp`). You will not use it in this test.

## Disk plan (macOS)

Typical layout now:

```text
[APFS macOS] [ESP + m1n1] [Linux / Omarchy root] [Recovery]
```

The placer needs **unallocated** GPT space. A partition that already is the 7.2 root is not a hole. From macOS, delete **only** the Linux/Omarchy slice(s) so that space becomes `Unused`. Do not shrink APFS unless you want extra room.

```bash
diskutil list disk0
sudo gpt -r show disk0
```

Write down identifiers before deleting. Protected: Macintosh HD (APFS container), iBoot, Recovery (`Apple_Boot` / Recovery), the ~500 MB EFI that already has `m1n1/`. The Linux slice is the large non-APFS, non-EFI, non-Recovery partition after the ESP (often `disk0s5`).

```bash
# Example only — use the identifier you just wrote down.
sudo diskutil eraseVolume free none disk0sN
```

`eraseVolume free none` turns that slice into free space. It is not `eraseDisk`. If Disk Utility / `diskutil` refuses, stop; do not `gpt remove` unless you are sure of the index.

You want:

```text
[APFS] [ESP + m1n1] [Unused hole] [Recovery]
```

40 GiB+ unused is comfortable (12 GiB installer + 12 GiB copy + slack). 28 GiB is a tight floor.

The placer then puts `omarchy-install` at the **tail** of that hole:

```text
[APFS] [ESP + m1n1] [hole] [omarchy-install] [Recovery]
```

## macOS — place the installer (do not skip dry-run)

In Terminal, `cd` to the folder that contains `place-nvme-installer.sh` and the `omarchy-mac-iso-usb` files.

```bash
# Dry-run only. Read the plan. Stop if it wants to use rdisk0 as --disk,
# or if the hole is smaller than installer + reserve, or if APFS would move.
sudo ./place-nvme-installer.sh \
  --payload ./omarchy-mac-iso-usb/payload.img \
  --esp-files ./omarchy-mac-iso-usb
```

Confirm all of this in the printed plan:

- `name=omarchy-install`
- installer `start` is at the **end** of the hole (not right after the ESP unless the hole itself is there)
- a leading unallocated region remains (the TUI’s target)
- `dd` target is a **new** `rdisk0sN`, never `rdisk0`

Then:

```bash
sudo ./place-nvme-installer.sh \
  --payload ./omarchy-mac-iso-usb/payload.img \
  --esp-files ./omarchy-mac-iso-usb \
  --confirm
```

This **replaces** `EFI/BOOT/BOOTAA64.EFI` with live installer GRUB (m1n1 / vendorfw / asahi hashes must match). Old NVMe GRUB is no longer the default. That is expected.

Stop if the script says `m1n1/vendorfw/asahi changed`.

## Boot the live TUI

1. Shut down (not reboot).
2. Power on. Do not need a USB stick.
3. If U-Boot is about to boot the old NVMe GRUB and you still see “Omarchy Linux / Advanced options”, you did not take the new `BOOTAA64.EFI`. Hold to pick the Linux volume if the picker appears.
4. You want GRUB text **OMARCHY NVMe installer GRUB** (or live USB-style quiet boot into a tty installer), then tty1 autologin.

Wi-Fi: nmtui **Rescan** a few times, then Activate. Firmware comes from the internal ESP; the stick/payload does not ship it.

macOS cannot set GPT names (`gpt label` is EPERM). Images from this PR run `ensure_installer_partlabel` in the TUI. An older payload still needs:

```bash
lsblk -o NAME,SIZE,LABEL,PARTLABEL
sudo parted /dev/nvme0n1 name 5 omarchy-install
lsblk -o NAME,PARTLABEL
```

## TUI choices

Run `omarchy-mac-install` if welcome did not already start it.

| Ask | Answer for this test |
|-----|----------------------|
| How should this machine be installed? | **Install into free space** |
| Which free region? | The hole **on the internal NVMe**, in front of `omarchy-install`. Not a USB stick. |
| Username / password / hostname | Yours. Empty hostname → `omarchy`. |
| Encrypt? | **Encrypt** (default). Same password as the user. |
| Does this look right? | Read the table. Target is a MiB range on NVMe, existing partitions stay. |

Do **not** pick **Reinstall an existing Omarchy root** — that path skips consume/grow. There should be no Omarchy root left after you freed the Linux slice.

When it finishes, reboot when asked.

## First boot of the new root

Unlock LUKS (Plymouth). Desktop user as you typed.

Then, as root (or after `sudo`):

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,UUID
findmnt /
uname -r
# expect 7.1.6
cat /sys/class/drm/card0/device/uevent
# expect simpledrm / simple-framebuffer, not apple-drm
systemctl status omarchy-mac-consume-installer.service --no-pager
```

Pass:

- `PARTLABEL=omarchy-install` is **gone**
- the new root (`OMARCHYROOT` or LUKS labelled `OMARCHYROOT`) is **larger** than just after the copy
- APFS / Recovery / ESP still present
- consume service ran once and disabled itself (or “already consumed”)

If consume did not run:

```bash
sudo /usr/local/sbin/omarchy-mac-consume-installer
```

It must refuse if `/omarchy-mac-overlay-write` exists (still on the live overlay). Reboot into the installed root first.

## If it goes wrong

| Symptom | What to do |
|---------|------------|
| Still “Omarchy Linux / Advanced options” | Live `BOOTAA64.EFI` did not win. From macOS: mount the ESP (`mount_msdos` / `diskutil`), check for `omarchy-usb-live` and `initramfs-omarchy-usb.img`. |
| TUI says no free GPT space | The hole is already a partition, or you booted USB-style skip. `lsblk` / `parted /dev/nvme0n1 unit MiB print free`. Do not `mkpart` by hand over APFS. |
| Display is simpledrm / 2560×1600 | **Pass** for 7.1.6. |
| macOS missing | ESP/`m1n1` damage or wrong `dd`. Do not keep writing. |
| Consume wants to `rm` Recovery | Script bug — Ctrl-C. `PARTLABEL` must be exactly `omarchy-install`. |

Hold power → Options → Macintosh HD still gets macOS. Do not copy a random USB `boot.bin` over `m1n1/`.

## After this test (not now)

A later image built on 7.2 (`OMARCHY_KVER=7.2.2-omarchy-wip72+`, no `ALLOW_OLD_APPLEDRM`) is what should first-boot `apple-drm`. Do not hand-copy that kernel onto this 7.1.6 root and call the installer done.

## Prompt blurb (paste)

```text
Follow docs/m3-716-nvme-installer.md on this M3 Air. 7.1.6 NVMe installer
only. The Linux root is disposable (7.2/appledrm is already on the builder).
From macOS, eraseVolume free none on the Linux slice only — never APFS,
Recovery, iBoot, or the m1n1 ESP. Place omarchy-install at the tail of that
hole, boot it, Install into free space (not replace-existing), confirm
consume deleted only omarchy-install and grew the new root. Never dd
whole disk0, never re-run Asahi. simpledrm is the expected display.
```
