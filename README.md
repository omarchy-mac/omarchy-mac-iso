# Omarchy Mac ISO

Live and installer artifacts for Omarchy on Apple Silicon. The default build is an NVMe-installer file set; an optional flashable USB artifact is a GPT disk image (`.img`) with a FAT32 ESP, not an ISO9660 file. The repo name matches Omarchy's x86 ISO so people can find it.

This repo owns the live USB and installer. [omarchy-mac](https://github.com/omarchy-mac/omarchy-mac) owns the installed desktop. Destination design: [plans/apple-silicon-image.md](plans/apple-silicon-image.md). How to work in this tree: [AGENTS.md](AGENTS.md).

Default branch is `main`. That is unrelated to `omarchy-mac`'s `main` (still v3.x); this tree has no v3 history.

A Mac with no Asahi/m1n1 cannot boot this USB. iBoot will not load it until macOS has run the Asahi **UEFI-only** provision. Shrink APFS from macOS, never from Linux.

The installer is Apple-Silicon-wide; it is not restricted to M3. M1 and M2 use the kernel/device-tree support supplied by Asahi. The `apple,j613` patch is a guarded enhancement for full-resolution display on the 13-inch M3 Air and exits without changing `boot.bin` on every other board. Current metal proof is strongest on that M3 Air, so other models remain validation targets rather than implied guarantees.

## USB image (Apple Silicon host)

On a machine that already runs `linux-asahi`:

```
sudo ./bin/omarchy-mac-iso-make --usb --rootfs
```

Writes `release/omarchy-mac-iso-usb/` — the files the NVMe placer copies (`payload.img`, `payload.img.zst`, `vmlinuz-linux-asahi`, the live, encrypted-install, and plain-install initrds, `BOOTAA64-NVME.EFI`, `grub-nvme-installer.cfg`). Testers on Drive or SHARE take the `.zst`, not the 12GiB raw image. It does **not** wrap `omarchy-mac-usb.img` unless you also pass `--disk-image`.

Every build writes `BUILD_INFO` with the full source commit, dirty/clean state, kernel version, and optional `OMARCHY_KERNEL_SOURCE_REF`, plus `SHA256SUMS` for the generated files. To make a self-contained tester directory without manually copying stale files:

```
./bin/omarchy-mac-iso-package-tester-drop \
  release/omarchy-mac-iso-usb \
  release/omarchy-mac-apple-silicon-preview-1
```

The destination must not already exist. The packager verifies the build manifest, reuses `payload.img.zst` from the build (or compresses `payload.img` if that file is missing), copies the current instructions and collectors, and generates a new manifest for the complete drop.

- `payload.img` — btrfs labelled `OMARCHYLIVE`, subvol `@` (builder copy; macOS `dd`s the decompressed image onto `omarchy-install`)
- `payload.img.zst` — same payload for Drive / SHARE / the macOS placer (`--payload payload.img.zst`)
- `omarchy-mac-usb.img` — only with `--disk-image`: GPT ESP `OMARCHYISO` + that payload, for `dd` onto a USB stick. Never onto the internal SSD

Live session is tty autologin (`multi-user.target`), not a graphical login. Default payload is 12GiB with zstd; a 16GB stick is the floor. Override with `OMARCHY_USB_PAYLOAD_BYTES`.

A 7.1.6 host `appledrm` has no V14_7; the builder **fails** unless you set `OMARCHY_ALLOW_OLD_APPLEDRM=1` (simpledrm) or point `OMARCHY_KVER` / `OMARCHY_VMLINUZ` / `OMARCHY_MODULES_DIR` at a ≥7.2 tree. Initrds in the release dir are `chmod a+r` so they can be copied off the builder.

Needs root, `arch-install-scripts`, a sibling `omarchy-mac` checkout (or `OMARCHY_PATH`) for `install/omarchy-base.packages`, and local `omarchy-*.pkg.tar.*` (default `~/.local/share/omarchy/build-output`). Does **not** pacstrap `linux-asahi` or `asahi-scripts` (those touch the host ESP). Vendor firmware is copied from the **internal** ESP at boot. `refresh-live` cannot add this package set — that needs a full `--usb --rootfs` rebuild.

`--usb` without `--rootfs` still writes a tiny busybox payload and is not the installer. Override payload size with `OMARCHY_USB_PAYLOAD_BYTES`; package search with `OMARCHY_LOCAL_PACKAGES`.

Optional USB stick image (destroys the target stick):

```
sudo ./bin/omarchy-mac-iso-make --usb --rootfs --disk-image
sudo dd if=release/omarchy-mac-iso-usb/omarchy-mac-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Copying files onto an existing FAT stick is not enough — the payload is its own partition.

### NVMe installer (no USB)

M3 Type-C often never appears in U-Boot. After Asahi **UEFI-only** (M3: `EXPERT=true` and `curl -L https://alx.sh/dev | sh`, firmware 14.8.3), you need an **unallocated** GPT hole (shrink APFS from macOS, or `diskutil eraseVolume free none` on an existing Linux slice only — never APFS / Recovery / the `m1n1` ESP). Hole size should be about **twice** the payload (copy + installer) plus slack.

Copy `payload.img.zst`, all three initrds, `vmlinuz-linux-asahi`, `BOOTAA64-NVME.EFI`, and `grub-nvme-installer.cfg` onto the Mac, plus `scripts/macos/place-nvme-installer.sh`. Do **not** upload `payload.img` (12GiB) or `dd` `omarchy-mac-usb.img` onto the internal disk.

```
# Dry-run first. --confirm writes.
sudo ./place-nvme-installer.sh \
  --payload ./payload.img.zst \
  --esp-files .
```

On the internal SSD, `gpt add` / `gpt label` are **EPERM** while macOS is booted. The placer uses 4K native sectors, then `diskutil addPartition` a placeholder (the leading hole) + `omarchy-install` at the tail, then `eraseVolume free none` on the placeholder. `dd` is only onto the new `rdisk0sN`. Before changing the GPT it verifies that the ESP has room for every temporary file plus write slack. NVMe live boot has its own EFI embed, `/omarchy-nvme-live` marker, and `grub/grub-nvme.cfg`; it cannot select a plugged-in USB's marker or config. Its temporary kernel and initrds use `*-omarchy-nvme-*` names, so an existing install's standard `/vmlinuz-linux-asahi` and `/initramfs-linux-asahi.img` remain byte-for-byte untouched. `m1n1` / `vendorfw` / `asahi` hashes must match.

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

M3 (`apple,j613`) display needs `linux-asahi` **>= 7.2** (appledrm V14_7) plus the DCP nodes in m1n1's bundled DTB. A 7.1.6 image boots `simpledrm` only. Build on a 7.2 host, or set `OMARCHY_KVER` / `OMARCHY_VMLINUZ` / `OMARCHY_MODULES_DIR`. The installer then overlays `configs/m1n1/j613-dcp.dtbo` into the j613 slot of the existing `m1n1/boot.bin` (backup `.bak-predcp`). It does not use GRUB `devicetree` and does not write extlinux. Unencrypted roots get `initramfs-linux-asahi-plain.img` (no `encrypt` hook). `OMARCHY_ALLOW_OLD_APPLEDRM=1` forces a simpledrm-capable 7.1 image. M3 Air Type-C PD is SPMI `sn201202x` (not I2C `tps6598x`); live and install initrds list `sn201202x?`. The kernel needs `CONFIG_TYPEC_SN201202X=m` or the ports stay in gadget mode until that module is loaded and the cable is replugged.

### Installer

On the live USB, tty1 autologin runs `omarchy-mac-install`. It never `mklabel`s a disk that already has Apple partition types.

It asks for a username, password (re-prompts on mismatch), hostname (empty → `omarchy`), full name and email (empty skips; used for git and XCompose), and whether to encrypt (default yes, same password as the user). Then it shows a table of every choice and **Does this look right?** before copying. Tokyo Night is seeded so the first graphical frame is not unthemed.

| Action | What it does |
|--------|----------------|
| **Install into free space** | `parted mkpart` in an existing GPT hole only. APFS/iBoot/Recovery stay. Needs unallocated space (macOS APFS shrink, Asahi UEFI-only leftover, or the hole in front of an `omarchy-install` slice) |
| **Reinstall an existing Omarchy root** | Formats that partition only — no `mkpart`, no `mklabel`. Finds btrfs `OMARCHYROOT` or a LUKS volume labelled `OMARCHYROOT` / GPT name `root`. Does not offer Asahi's own LUKS. Disabled while running from the temporary NVMe `omarchy-install` slice |
| **Wipe a USB stick and install** | GPT ESP (`OMARCHYBOOT`) + root filling the stick. Persistent desktop, no overlay |
| **Write GRUB for an existing Omarchy root** | Bootloader only. Skips encrypted roots (needs the inner UUID). Disabled while running from the temporary NVMe `omarchy-install` slice |
| **Clone** | `dd` through the last partition onto another stick; rewrites the clone btrfs UUID |

Wipe, free-space, and replace **copy used files** (`tar` of the overlay lowerdir onto a fresh btrfs `@` / `@home` / `@log`). They do not `dd` the payload. After the copy the installer runs `omarchy-apply-system --first-install` and `omarchy-provision-user --first-install` in the target (same as `omarchy-mac/install.sh`). First graphical login still runs `omarchy-provision-first-run` for the welcome / timezone / Wi-Fi / update toasts. Clone is still a block copy.

Target setup resolves command symlinks inside the chroot before temporarily binding offline stubs. System or user provisioning failures stop installation before the success/reboot prompt; they are not deferred to an unattended graphical login. Output is retained in the target's `@log/omarchy-install.log` (mounted at `/var/log/omarchy-install.log` after boot). The installed desktop restores NetworkManager authorization while preserving its selected Wi-Fi backend, removes live-console quieting overrides, and enables automatic clock synchronization. The payload includes `avd-fw` and `libva-v4l2_request-avd` so Apple video setup can complete offline; hardware decoding still depends on support for the specific chip.

Multiple Omarchy roots can coexist. Each root UUID gets its own `EFI/omarchy/<root-uuid>/` kernel/initramfs pair and `grub/omarchy-roots/<root-uuid>.cfg` menu fragment. Only UUID-named fragments are assembled into `grub/omarchy.cfg`; `grub/custom.cfg` sources that managed file, so a later `grub-mkconfig` by the GRUB-owning installation retains the additional roots. Installing into a second free-space hole preserves a still-present original root as the default. If macOS erased the previously managed default, a free-space reinstall transfers that default to the new root. Generated entries whose filesystem and LUKS container are both absent are omitted from the active menu; their fragments and kernel files remain recoverable. Locked LUKS roots are recognized through their outer UUID. Customized fragments and failed device discovery are preserved conservatively; unrelated owning menus/defaults are not claimed. Shared-ESP roots mount the full ESP at `/boot/efi`, not `/boot`, preventing their future kernel tools from overwriting another root's standard `/boot` files. Reinstall replaces the selected root only.

Standalone GRUB builds include and preload `test`, required by conditional menu includes. The installer checks for the known older ISO standalone loader that omitted `test.mod` before creating or formatting a root. For an NVMe placement it checks the saved owning loader, not the temporary live loader. That unsupported owner must be restored to a compatible GRUB before reinstalling; rebuilding the live image alone cannot repair it. The preflight does not replace its EFI executable, parse or rewrite its menu, or claim ownership of an unmarked default. A narrow migration of previously generated includes is not currently enabled.

The macOS NVMe placer does not copy or parse an existing `grub-mkconfig` output. It leaves `grub/grub.cfg` and `grub/custom.cfg` in place, saves the owning `BOOTAA64.EFI`, and temporarily installs the dedicated NVMe-live EFI executable. During installation it restores the saved executable and piggybacks the new UUID entry through `custom.cfg`, leaving the existing `omarchy-mac` menu and default logic under their original owner's control. If the UEFI-only ESP had no prior bootloader, the installer instead creates an owned GRUB using only its generated UUID fragments. Private NVMe files are removed only when that same-ESP placement is successfully consumed; a USB install cannot remove a pending placement.

The placer refuses an ESP containing the previous placer layout (`/omarchy-usb-live` or an NVMe-live title in the owning `grub.cfg`). Do not delete that marker alone: the old placer also replaced bootloader/config files. First restore the intended installed `BOOTAA64.EFI` and GRUB configuration from a known ESP backup, verify that installation boots, then remove the obsolete live marker and retry.

LUKS is offered on wipe, free-space, and replace. New containers get label `OMARCHYROOT`. Install initrd runs Plymouth before `encrypt` so there is one branded unlock, not a text prompt then Plymouth.

### System ESP after a disk install

Never `mkfs` of the ESP, never `update-m1n1`:

- **Piggyback** — some other OS owns GRUB, including after restoring the executable temporarily replaced by NVMe live boot: preserve its `grub.cfg` and existing `custom.cfg`, then add one `source /grub/omarchy.cfg` include
- **Own** — UEFI-only ESP with no pre-existing bootloader: atomically write an installer-owned `BOOTAA64.EFI`, `grub.cfg`, and marker `/omarchy-mac-root`

Kernels live under `EFI/omarchy/<root-uuid>/` so a later `grub-mkconfig` on that ESP does not pick them up as stray entries and one root cannot overwrite another root's initrd. Backups of `BOOTAA64.EFI` / `grub.cfg` / `custom.cfg` are `*.omarchy-bak` on the ESP. `m1n1/` / `vendorfw/` / `asahi/` hashes must match after, except the j613 DTB slot in `m1n1/boot.bin`.

Current limitation: ISO-installed roots deliberately ship no `linux-asahi` package or private-directory update hook, so their UUID-private kernel/initramfs remain at the installer version. Do not install/update a kernel until a hook exists to sync it into `EFI/omarchy/<root-uuid>/`. Also do not run `omarchy-system-boot-to-esp` from a shared-ESP ISO root: it would remount the ESP at `/boot` and replace the owning installation's GRUB. Installed shared roots contain `/etc/omarchy-mac-iso-shared-esp` as a warning marker.

Fresh desktop packages refuse `omarchy-system-boot-to-esp` when the shared-ESP marker or this root's UUID-private boot layout is present. The installer verifies the marker after provisioning. Build fresh desktop packages alongside installer changes; an older package does not gain this guard from refreshing installer scripts.

For a disposable provisioning rehearsal, run `bash test/provisioning-chroot /path/to/omarchy-VERSION-aarch64.pkg.tar.xz`. This uses actual packaged symlinks, chroots and bind mounts, with synthetic setup commands and proc/sys/dev fixtures in a private user namespace. To also exercise real pseudo-filesystem binds and a btrfs `@log` subvolume, run `sudo unshare --mount --propagation private bash test/provisioning-chroot --inside --btrfs /path/to/package`. It creates only a temporary filesystem image; it does not install onto a physical disk or prove desktop/boot behavior.

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
