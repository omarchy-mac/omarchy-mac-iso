# Plan: an Apple Silicon install image for Omarchy Mac

## Context

Installing Omarchy Mac today is two curl-to-bash scripts: the Asahi Alarm
installer from macOS (~8.5 min) and `omarchy-mac-setup` on the booted Arch
(~14 min, three reboots, two questions, and an in-place re-encryption that
rewrites every block of the root partition). It works, but it is a long tail of
network-dependent steps where any one failure lands the user in a half-built
machine, and it needs a working `nmtui` before anything can start.

Malik's proposal: do Asahi's one-time UEFI-only provision from macOS, then boot
our own USB straight into a live installer that pulls firmware from the internal
ESP and installs from bundled offline packages. **That is the right shape, and
the hard half is already built by Asahi upstream.** This plan covers what to
build, in what order, and which conventions to inherit from `omacom-io/omarchy-iso`.

Target: macOS step unchanged (~6-8 min, dominated by Apple's own stub download
and not compressible), then **one boot, one set of questions, one reboot,
~3-5 minutes**, fully offline, with encryption as a fresh `luksFormat` instead
of a full-partition rewrite.

Upstream's own `plans/aarch64-support.md` states **"Apple Silicon (Asahi) and
SBCs (U-Boot/rpi-firmware) are out of scope"** — this is our lane, not a
duplicate of work they are about to land.

## What was verified on hardware (2026-08-22, M2 Max)

Spikes live in `~/code/omarchy-mac-iso-spike/`. Reports:
`spike-usb-result.txt`, `spike-rootimg-result.txt`, `spike-uboot-usb-result.txt`.

| Claim | Evidence |
|---|---|
| Firmware comes from the internal ESP with no custom code | Stock `asahi` initcpio hook. Device-tree `asahi,efi-system-partition` is `bf93c7c5-…`. `/boot/vendorfw/firmware.cpio` is 32 MB. In the spike initramfs, `/vendorfw` and `/lib/firmware/vendor` listed `apple`, `asmedia`, `brcm`. |
| USB storage works in an initramfs **if `dwc3-apple` is present** | Three Type-C controllers bound to `dwc3-apple` (not `dwc3-of-simple`). Lexar stick appeared as `/dev/sda` at ~3.3 s. `130304c000.mux` bound to `apple-display-crossbar`. Deferred-device list empty. |
| The "USB-PD dependency cycle" dmesg is a red herring | Same `Fixed dependency cycle(s)` lines appear on a working full boot. `fw_devlink=permissive` is not required. |
| Stock `asahi-scripts` hook is stale | `asahi-scripts` 20260127.1 `initcpio/install/asahi` adds `dwc3? dwc3-of-simple?` and never `dwc3-apple?` or `mux-apple-display-crossbar?`. That is why an earlier spike loaded ten USB modules at refcount 0. Worth reporting upstream. |
| Loop-mount of a USB `root.img` works | 32 MB ext4 `root.img` on FAT label `OMARCHYSPK` → `losetup /dev/loop0` → mount ro → marker `omarchy-mac-live-ok` read. `result: PASS`. |
| U-Boot boots our stick | Interrupted autoboot, `usb start; bootflow scan -l usb; bootflow select 0; bootflow boot`. One valid bootflow: `usb_mass_storage.lun0` partition 1, `/EFI/BOOT/BOOTAA64.EFI`. Kernel cmdline carried `spike=uboot-usb`. Loop-mount still `PASS`. |
| NVMe is tried before USB | `boot_targets=nvme usb`, `bootdelay=1`, `bootcmd=bootflow scan -b`. A machine that already has Linux on NVMe **must** interrupt U-Boot; `bootflow scan -b` without `setenv boot_targets usb` boots Omarchy GRUB. A fresh UEFI-only machine has no NVMe EFI payload, so the stick should win automatically. Do not `saveenv`. |
| Built-in keyboard talks to U-Boot | `stdin=serial,usbkbd,spikbd,mtpkbd`. Typed the bootflow commands on the laptop keyboard. |
| We must not touch APFS | Asahi policy: altering APFS containers forces a DFU restore. UEFI-only leaves unallocated GPT space for a later root. |
| The medium needs its own ESP and must not manage `boot.bin` until installed | Asahi boot-process guide. USB `BOOTAA64.EFI` is standalone GRUB (`grub-mkstandalone`). After install we own the System ESP and may `update-m1n1`; the live installer must not. |
| UEFI-only free space, from source | `asahi-installer` `main.py` / `osinstall.py`: user **resizes APFS first**, then "install into free space". UEFI-only template is EFI only (`500MB`, no `expand: true`), plus a 2.5 GB APFS stub. Leftover of that free area stays unallocated. It does not create an empty Linux partition, and it does not ask "how much for the OS" because it is not expandable. Firmware still lands on the ESP (`copy_firmware: true`, `copy_installer_data: true`). |
| Os-package zip, from source | Raw zip: `esp/` tree + `root.img` (size multiple of 4 KiB). Optional `boot.img`, `icon`. `fdcopy` onto `/dev/rdiskNsM`. No sparse format. `INSTALLER_DATA` / `REPO_BASE` is the supported third-party hook. `supported_fw` filters IPSW versions (`12.3`, `12.3.1`, `13.5`, `14.8.3`), not kernel features. |
| Alarm size precedent is **Minimal**, not a desktop | Alarm Minimal `root.img` is 2,209,614,225 bytes; Desktop is 12.7 GB in a **1.88 GiB** zip. This machine's `@` subvolume is ~13 GB (`du -sx /` does not cross `@home`). A full Omarchy image will look like Desktop, not Minimal. GitHub Releases' 2 GiB per-file cap is tight. |

USB-to-USB `dd` (through last partition, not whole disk) is proven from
the installed Omarchy (2026-08-23): 14.9G Lexar → 14.5G stick, then that
stick booted to autologin root, `gum 2.0.0`, `fnmode=1`. Proven from a
booted live USB the same day: 14.5G stick → Lexar; U-Boot skipped
`05dc:c753` until `usb reset` twice, then the Lexar booted. Overlay +
`switch_root`, systemd userspace, and Wi-Fi association are done
(2026-08-23). Partition install (ESP + persistent USB root, no overlay) is proven on
metal (2026-08-24): 14.5G stick, GRUB `Omarchy Mac (USB root)`,
`omarchy-usb-wait` mounted the new UUID, hostname `omarchy-mac`. Free-space install is proven on the Lexar hole (2026-08-24): live
partitions kept, `OMARCHYROOT` 11.4G. Wipe-install 14.5G stick booted
warm, `root@omarchy-mac`, nmtui Rescan then `ping www.google.com`. NVMe
hole after macOS APFS shrink (2026-08-24): p7 46G, existing Omarchy still
boots, new GRUB entry `root@omarchy-mac`. Shrink APFS from macOS, never
from Linux. Not yet: LUKS or Omarchy packages on the new root.

## Architecture: one rootfs, two front doors

Build a single provisioned Omarchy root filesystem image, then ship it two ways:

1. **Live USB image** (`.img`, GPT + FAT32 ESP + payload). Boots via m1n1/U-Boot
   after a UEFI-only provision, runs a TUI installer, supports a fresh
   `luksFormat`, doubles as a repair/reinstall medium. This is the encrypted
   default and the path S1 unblocked.
2. **asahi-installer os package** (zip + our own `installer_data.json`) — the
   macOS one-liner offers "Omarchy Mac" directly, no USB stick. Unencrypted
   fast path. Encryption afterwards is `omarchy-system-btrfs-migrate --encrypt`
   **if** `/boot` is already the ESP — not a full `omarchy-mac-setup` run, which
   would try to install Omarchy again.

The payload is **one artifact**: `root.img`, a btrfs filesystem image with
`@` / `@home` / `@log` / `@factory`. Keep the image **uncompressed (or
`compress=none`)** so the published zip still shrinks; Alarm Desktop's 12.7 GB
image zipping to 1.88 GiB only works because the filesystem data is still
compressible. Internal btrfs zstd makes the zip larger, not smaller. After
install, new writes can compress.

Two layouts that S1 showed both work. **(a) is what `--usb` ships**, proven on
metal 2026-08-23 (`payload=/dev/sda2`, `OMARCHY_MAC_USB_USERSPACE pid=1`).
(b) was the spike and the first busybox image.

- **(a) Payload partition that *is* the btrfs image.** GPT: FAT32 ESP + one
  Linux partition labelled `OMARCHYLIVE`, subvol `@`. Live boot mounts that
  partition read-only and overlays a tmpfs, then `switch_root`. Install is
  `dd` of the partition onto the target.
- **(b) `root.img` as a file on the FAT ESP.** Live boot `losetup` + mount.
  Fine for development; extra loop layer in production. A real Omarchy root
  will not fit on the 512 MiB ESP.

Live boot command line: `systemd.unit=omarchy-mac-install.target` so only the
installer starts. Booting the default target later gives a live desktop for
free. The os-package path does not pass that unit, so the same image first-boots
into owner setup (`omarchy-provision-owner`).

Initramfs (small): `base asahi udev` plus an explicit module list that **does
not trust** the packaged asahi hook for USB:

```
dwc3-apple dwc3 phy-apple-atc mux-apple-display-crossbar
tps6598x typec xhci-plat-hcd xhci-hcd usb-storage uas loop
```

Then a hook that waits for the payload, sets up overlay, `switch_root`.

Install:

```
pick target free space → parted (read back the slot, never guess) →
optional fresh luksFormat → dd root.img → btrfs resize max →
btrfstune -u → personalize (fstab, crypttab, hostname, user, keymap, locale) →
mkinitcpio -P (asahi hook **and** dwc3-apple) → GRUB into the existing ESP
(EFI/BOOT and grub/ only) → @factory snapshot → reboot
```

Hard constraints, as refusals not comments:

- Never resize or touch APFS (`7C3457EF-…`), iBoot (`69646961-…`), or Recovery
  (`52637672-…`).
- Live installer never writes `m1n1/boot.bin`, `vendorfw/`, or `asahi/` on the
  internal ESP. Writing `EFI/BOOT/BOOTAA64.EFI` and `grub/` is required so the
  installed system boots. `asahi/` holds wifi/bt pairing; leave it.
- Never create a second ESP on the USB-after-UEFI-only path. The os-package
  path creates the one System ESP via asahi-installer; that is a different
  front door.
- After install the OS **does** own `update-m1n1`.

Deliberately **not** an ISO9660 hybrid and **not** archiso. Asahi wants a FAT32
ESP with `BOOTAA64.EFI`. If a custom mount hook fights us, copy archiso's
**overlay hook**, not mkarchiso.

### Divergence from upstream, stated deliberately

Upstream's ISO bundles a pruned offline pacman mirror and installs with
archinstall + pacstrap. We ship a prebuilt `root.img` because:

- the asahi-installer os-package path requires a `root.img` regardless;
- install collapses to a disk write instead of ~950 packages of pacman work;
- archinstall wants to own the disk, and our disk is owned by APFS plus an
  m1n1 ESP we must not manage.

Do **not** bake the pacman package cache into `root.img` by default (~2 GB here).
That fights the GitHub 2 GiB cap and the "dd in seconds" target. Optional apps
offline can be a second artifact later.

### Rejected: live root inside the initramfs

A 2–3 GB initramfs loaded by GRUB under U-Boot was a fallback when USB in the
initramfs looked impossible. USB works. That fallback is parked.

There is no documented 2 GiB integer cap on GRUB arm64-efi `initrd` (the
"initrd is too big" error is the x86 relocator; aarch64 uses a 32 GB window).
`CONFIG_SYS_BOOTM_LEN=8MB` in `apple_m1_defconfig` applies to U-Boot `bootm`,
not to GRUB-as-EFI. Unproven risks remain: contiguous EFI `AllocatePages`,
GRUB verifier double-buffering, unpack RAM on 8 GB machines. We do not need
to take them.

## Conventions to inherit from `omacom-io/omarchy-iso`

Same team, same style, cheap cross-pollination.

- **A separate repo**, not a directory in `omarchy-mac`.
  `github.com/omarchy-mac/omarchy-mac-iso` (2026-08-22, LICENSE only, default
  branch `main`). Layout still open: `bin/omarchy-mac-iso-{make,boot,test,release,upload}`,
  `builder/`, `configs/`, `plans/`, `test/{unit,integration.d}`. The "iso" name
  stays for discoverability even though the artifact is a `.img`.
- **`plans/*.md` as living design docs**, deleted once implemented. This file
  is `plans/apple-silicon-image.md`.
- **Build inside a container** driven by a thin host script, `./release` output,
  `chown` to `HOST_UID:HOST_GID`. Carry `--edge`, `--dev`, `--rc`,
  `--local-source <omarchy> <pkgs>`, `--no-cache`, `--debug` where they apply.
- **Partitioning pattern, not the file.** `disk-partitioning.sh` uses **parted**,
  never predicts a partition number, keeps `created_parts[]` +
  `rollback_created_parts()`, and works against an image file. Copy those
  rules. Do not import the Windows-ESP script and hope APFS GUIDs match.
- **Phase state machine + dashboard** as in `orchestrator/phases.py`.
- **Questions from the runtime.** Copy `install/provisioning/setup-form.sh` and
  fail the build if it is missing. Encrypt is **not** in that form (Ctrl+C side
  channel on the x86 ISO; a separate prompt in `omarchy-mac-setup`). Source
  keymap / user / hostname / password from the form; keep encrypt as its own
  question, default yes.
- **`cidata` autoinstall** — keep the volume label so tests rhyme with
  upstream. Do not blindly require archinstall's `user_configuration.json`.
  Define a small unattended schema (hostname, user, hash, encrypt, keymap).
- **CI shape:** `ubuntu-24.04-arm`, buildx, `jlumbroso/free-disk-space@v1.3.1`,
  nightly + `workflow_dispatch`. This Mac stays the release builder until a
  lean root is measured against the runner's ~14 GB disk.

`main` stays the default branch on this repo. Do not import `omarchy-mac`'s
`main` = v3.x rule. We have **write, not admin**.

## Build inputs

Repos as on this machine (`/etc/pacman.conf`):

- `[omarchy-aarch64]` — `github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge`
- `[asahi-alarm]` — `https://github.com/asahi-alarm/asahi-alarm/releases/download/$arch`
- `[core] [extra] [alarm] [aur]` — `http://mirror.archlinuxarm.org/$arch/$repo` (no valid TLS; archives are `.pkg.tar.xz`)

Asahi packages we must install ourselves: `linux-asahi`, `m1n1`, `uboot-asahi`,
`asahi-scripts`, `asahi-configs`, `asahi-fwextract`, `asahi-audio`,
`alsa-ucm-conf-asahi`, `mesa` (asahi), `asahi-meta`, plus `speakersafetyd` /
`pipewire-pulse`. `hid_apple fnmode=1` and `appledrm show_notch=1` belong in
the image, not first-boot. Notch *bar height* is runtime. Do not apply
`fix-brcmfmac-supplicant.sh` on Asahi (it wedges BCM4387).

Foreign packages today: `omarchy`, `omarchy-keyring`, `omarchy-settings`,
`ttf-jetbrains-mono-nerd-basic`, `voxtype`, `yay`. Prebuild voxtype / yay /
the nerd font into `[omarchy-aarch64]`. Build `omarchy` / `omarchy-settings`
at image-build time from `--local-source` or a pinned ref — do not treat the
binary repo as the ISO's source of truth for those.

## Build time and size

Measured on this machine (M2 Max, 12 cores, 30 GB RAM), for a package set of
this size:

| Stage | Cold | Warm |
|---|---|---|
| Download packages | ~1.5-2 min | ~0 |
| pacstrap ~950 packages | 5-8 min | 5-8 min |
| Build the AUR packages | 3-6 min | ~0 |
| Provisioning | 1-2 min | 1-2 min |
| Assemble `root.img` | 0.5-1 min | 0.5-1 min |
| **Total** | **~12-20 min** | **~7-11 min** |

Do not use btrfs `compress=zstd:19` on the golden image. zstd:3 vs -19 was
measured at ~500 MB/s vs 31 MB/s here; more importantly, compressing inside
the filesystem is the wrong lever for a zip we will publish.

**Measure a pacstrap of the real package list before anyone bikesheds
hosting.** A 2–3 GB artifact was inferred from Alarm Minimal and is likely
wrong. GitHub Releases is 2 GiB per file. Alarm Desktop already zips to 1.88
GiB. Trim, split, or R2 — Malik's call once we have a number.

CI on `ubuntu-24.04-arm` is 4 vCPU / ~14 GB disk. 16K-aligned userspace ELFs
generally run on a 4K kernel (the broken direction is 4K-assuming binaries on
a 16K kernel). Prove it with a throwaway `pacstrap` + `mkinitcpio` in that
container; do not boot `linux-asahi` there. Privileged docker is required for
loop devices. Until the root is lean, this Mac is the release builder.

## Not bricking our machines

Raised by Malik, 2026-08-22. First-class requirement.

Apple Silicon cannot be permanently bricked by software. The boot ROM is
immutable and DFU restore always recovers the machine. The real worst case is
"macOS is gone and I need a second Mac plus a USB-C cable", which is a ruined
day, not a dead laptop.

**Our code never performs the dangerous operation.** APFS, boot policy,
LocalPolicy, 1TR, and m1n1 stage-1 live inside Asahi's installer, which we do
not reimplement. We start from UEFI-only + unallocated space and only write
into that space.

Rails, cheapest first:

1. Partitioning unit-tested against loopback image files.
2. Refuse APFS / Apple Boot / Apple Recovery GPT types in code, not comments.
3. Only write to partitions this run created (`created_parts[]` + rollback).
4. `--dry-run` that prints every destructive command; require a clean dry run
   before a real one.
5. Develop against an external disk (`--target /dev/sdX`). USB storage works
   from a booted Omarchy and from our spike initramfs.
6. Backup the GPT off-machine (`sfdisk --dump`, `sgdisk --backup`) before any
   internal-disk test.
7. Assert the internal ESP is byte-identical for `m1n1/boot.bin`, `vendorfw/`,
   `asahi/` before and after an install.
8. Both maintainers have read the DFU procedure. Scott has an M4 Air as a DFU
   host (not an Asahi target). Malik has one Mac — so Scott takes every
   destructive internal-disk test; Malik takes builder, CI, loopback tests,
   external-disk installs, and review.

"Brick" is four rungs: Linux will not boot (reinstall); boot policy confused
(Recovery); DFU Revive (second Mac, **keeps data**); DFU Restore (second Mac,
**erases disk**). Rail 2 is what keeps us off rung 4.

## Stages

### S0 — Repo hygiene

`~/code/omarchy-mac` has an extracted initramfs strewn across the root (`init`,
`hooks/`, `usr/`, …). `--local-source` from that dirty tree will copy it.
Triage, do not bulk-delete: keep `ipcfix/`, `malikpr/`, `upstream-pr/`,
`tests/`. A clean clone is fine.

### S1 — Hardware spike — **done 2026-08-22**

USB through U-Boot, firmware from the internal ESP, `dwc3-apple` binds, loop
mount of `root.img`. Overlay + `switch_root` into busybox pid 1 is proven on
the `--usb` image (2026-08-23, `OMARCHY_MAC_USB_USERSPACE pid=1`). Still open
before S4: `iwctl`/`NetworkManager` in that environment.

A warm reboot often leaves Type-C unenumerated in U-Boot (`0 Storage
Device(s) found`). Cold start (shutdown, then power on) is required.
`bootflow select` of the USB row can still load NVMe's
`/EFI/BOOT/BOOTAA64.EFI`. Commands that worked on this NVMe-first machine:

```
load usb 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTAA64.EFI
bootefi ${kernel_addr_r} ${fdtcontroladdr}
```

### S2 — Populate the repo, and the builder container

Native `./bin/omarchy-mac-iso-make --usb` on this Mac produces a GPT image
(ESP + btrfs payload) that boots on metal (2026-08-23, payload partition
not a `root.img` loop). Then the same builder in
`docker --platform linux/arm64` from Arch Linux ARM with `[asahi-alarm]`
and `[omarchy-aarch64]`, then CI. `builder/build-rootfs.sh` (S3) replaces
the busybox tree on `@` with Arch `base` / systemd.

### S3 — The rootfs artifact

`builder/build-rootfs.sh` via `./bin/omarchy-mac-iso-make --usb --rootfs`
(needs root, `arch-install-scripts`). First cut **proven on metal
2026-08-23**: pacstrap Arch `base` onto `@`, `switch_root` into systemd,
autologin root shell, `nmtui` + brcmfmac scan, then `ping www.google.com`.
wlan0 is missing until nmtui Rescan; after that both nmtui Activate and
`nmcli … password` have worked. `gum` 0.17.0 and `hid_apple fnmode=1`
proven on metal. Not the Omarchy desktop. Asahi mesa / asahi-audio /
speakersafetyd / gum and `fnmode=1` / `show_notch=1` go in this payload
(not `asahi-scripts`).
Then the fork's package set →
provisioning with hardware-specific work that is *not* per-machine done at
build time (audio stack, `fnmode`, notch modprobe) → defer keymap / user /
hostname / anything that reads this panel to first boot or the installer →
produce `root.img` (btrfs, minimal, sparse, **not** internally zstd'd for
publication).

Regenerate the btrfs UUID at install (`btrfstune -u`).

### S4 — The installer

TUI, gum, phases. Questions from `setup-form.sh` plus encrypt.

Overlay + `switch_root` on the live payload, then the install pipeline above.
`@factory` as `install.sh` already does in `snapshot_factory_baseline`.

### S5 — asahi-installer os package

Same `root.img` plus `esp/` (GRUB, `vmlinuz-linux-asahi`, initramfs — kernel
**on the ESP**, or encrypt-afterwards hits `grub rescue>` as `docs/btrfs.md`
describes). Copy Alarm's entry shape. `supported_fw: ["12.3", "12.3.1", "13.5"]`
unless we test M3 (`14.8.3`).

### S6 — CI and hosting

`workflow_dispatch` green before nightly. Measure image size before picking
GitHub Releases vs R2 vs split assets.

### S7 — Testing

- `test/unit` — partitioning against loopback files; installer logic.
- Hardware, non-destructive: USB first; internal NVMe only into a hole
  left by shrinking APFS **from macOS**. This machine's p7 is that hole
  (2026-08-24).
- No Apple SoC QEMU. `cidata` plus `test/acceptance.d` after first boot.

## Verification

1. **S1 (done):** USB through U-Boot, vendor firmware present, `dwc3-apple`
   bound, overlay + `switch_root` into busybox pid 1. Layout (a) on metal
   2026-08-23: btrfs `OMARCHYLIVE` on `/dev/sda2`,
   `OMARCHY_MAC_USB_READY payload=/dev/sda2`, then
   `OMARCHY_MAC_USB_USERSPACE pid=1` with marker and overlay write.
   `--usb --rootfs` on metal 2026-08-23: `gum` 0.17.0, `fnmode=1`, nmtui
   Rescan (first scan may time out), then `nmcli device wifi connect`
   associated and `ping www.google.com` succeeded (`brcmf join_pref -52`
   is noise). Pixel USB tether enumerates as `enu1`/`cdc_ncm`.
2. `./bin/omarchy-mac-iso-make --usb` produces a GPT ESP + payload image on
   this Mac and boots; `test/unit` green; `bash -n` over every script.
   Container still open.
3. Install to an external disk, unencrypted then encrypted. Boot each. Confirm
   Wi-Fi, GPU/Quickshell bar at notch height, audio, media keys,
   `omarchy snapshot restore` sees `@factory`.
4. Internal ESP `m1n1/boot.bin`, `vendorfw/`, `asahi/` byte-identical before
   and after.
5. UEFI-only provision on a machine with free space, end to end, timed against
   the current 8.5 + 14 minute path.
6. CI green on `workflow_dispatch` before nightly.

## Coordination

Work lands in `omarchy-mac/omarchy-mac-iso`, not as a PR into
`codeberg/quattro`. `omarchy-mac-setup` stays the supported path for anyone
already on Asahi Alarm and remains the fallback while the image matures.

**This document is the first PR.** Two items are Malik's call: putting
"Omarchy Mac" in the macOS installer list (S5), and hosting a multi-GB image.
Note also `omarchy-mac/omarchy-mac-fedora` in the same org — no image-building
machinery to reuse.

## Parked follow-ups in omarchy-mac (not ISO work)

1. `tests/` is invisible to `./test/all` / AGENTS.md. Wire it, after fixing
   `bin/omarchy-mac-setup`'s hardcoded `SELF` so `tests/test-mac-setup.sh` is
   not red on a machine that has already installed.
2. Report the `dwc3-apple` omission to asahi-scripts, and carry the extra
   modules in our live initramfs regardless.
3. Restore this machine's `GRUB_TIMEOUT` (currently 20 s) and drop the spike
   GRUB entry once we no longer need it.
