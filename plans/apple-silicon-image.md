# Apple Silicon image: architecture, status, and roadmap

Status checkpoint: 2026-09-07. This is the shared design overview, not release
approval or instructions to modify a disk. [README](../README.md) documents the
builder in the checked-out revision; [AGENTS.md](../AGENTS.md) sets safety rules.
Implementation details belong to the workstream plans linked below.

## Outcome and workstreams

Deliver Omarchy beside macOS with one Linux-side identity/password setup and
encryption at installation time, rather than installing a desktop and then
rewriting its root to encrypt it. Preserve macOS and Apple boot firmware.

| Workstream | Responsibility | Status at this checkpoint |
|---|---|---|
| Live image and standalone installer | Offline payload, USB/manual NVMe boot, Linux provisioning, per-root ESP files | Implemented; latest provisioning/ESP fixes and fresh M3 evidence are in open installer PR #19 |
| [Marcelo integration](asahi-installer-integration.md) | macOS front end and bound handoff to a prepared encrypted installation | Separate implementation workstream; not qualified by the standalone test |
| [Managed kernels](managed-kernel-updates.md) | Coherent kernel packages, board tracks, safe updates and retained fallback | Audit/design complete; implementation and qualification pending |

These streams can develop against explicit pinned revisions without waiting for
every merge. A documentation merge does not merge their code, change a dependency
lock in another worktree, or update a built image.

## Implemented baseline and evidence

The latest inspected installer baseline is
[PR #19](https://github.com/omarchy-mac/omarchy-mac-iso/pull/19), revision
`4407c2ddbe75e6732e9709ce320d7d0125ffbf27`; it remains open at this checkpoint.
Descriptions below refer to that baseline, not necessarily `main`. Companion
source revisions and package-building requirements are recorded in the
[integration dependency table](asahi-installer-integration.md#2-pickup-isolation-and-pinned-dependencies).

The [provisioning checkpoint at that revision](https://github.com/omarchy-mac/omarchy-mac-iso/blob/4407c2ddbe75e6732e9709ce320d7d0125ffbf27/docs/provisioning-validation-20260907.md)
records a full image rebuild completed at `2026-09-07T16:14:01Z`, followed by a
fresh encrypted installation on M3 Air `apple,j613`. Checks confirmed:

- Successful provisioning and normal encrypted-root boot, correct managed GRUB
  default/entries, and preservation of the existing owning EFI loader.
- Snapper root configuration, read-only factory snapshot, first-run completion,
  enabled required services, and no failed system/user units.
- Deletion of the temporary installer slice and root growth to approximately
  131.7 GiB. A separate, explicitly authorized legacy GRUB repair preceded the
  test; the installer does not automatically perform that repair.

The tester subsequently reported a successful reboot after desktop updates,
acceptable UI responsiveness, installed 1Password, and no repeated first-boot
alerts. Those later observations are user-reported, not a second SSH audit.

This is evidence for one standalone M3 installation, not the new macOS app
handoff, all M3 boards, M1/M2 release qualification, or kernel update/fallback.
The [kernel audit](../docs/kernel-input-audit-20260907.md) also found that the
historical Image and later USB module have different config histories. Working
hardware and matching vermagic do not prove a coherent reproducible build.

## One live payload, separate entry paths

The shared payload is `payload.img`: a provisioned btrfs filesystem with live
label `OMARCHYLIVE` and subvolume `@`. Live boot mounts it read-only and uses a
temporary overlay. The installed root gets its own filesystem identity and
provisioning; it does not retain the live overlay as its root.

### Standalone USB and manual NVMe paths

- USB uses GPT with a FAT ESP (`OMARCHYISO`) and btrfs payload partition
  (`OMARCHYLIVE`). It still requires prior Asahi UEFI provisioning from macOS;
  a stock Mac cannot boot it directly through iBoot.
- The existing macOS placer stages the payload at the tail of approved free
  space after UEFI-only provisioning. Linux installs into the preceding hole;
  first installed-root boot consumes only the temporary `omarchy-install`
  slice. This is distinct from the new prepared-root contract below.
- Wipe-USB, free-space, and replace-existing installation create a fresh btrfs
  filesystem and copy used files with `tar` from `/run/omarchy-root`. They do
  not `dd` the payload onto the final root. Clone remains a block-copy operation
  through the last partition, with a rewritten clone btrfs UUID.
- Standalone encryption choices remain separate from the mandatory-encryption
  integrated target. Identity is collected in Linux, optional name/email are
  supported, and an explicit summary precedes installation.

At the PR #19 baseline a full build produces raw/compressed payloads and boot
files; `--disk-image` additionally requests the complete USB disk image. A raw
payload is not a whole-disk image. Package-set changes require a full rootfs
rebuild; refreshing scripts or initrds cannot add packages.

### Intended product path: Marcelo's macOS app

The [integration contract](asahi-installer-integration.md) is authoritative for
this planned path. No USB is required:

```text
macOS app: approved allocation + Asahi provisioning + Recovery handoff
  → temporary live installer: validate bound target, collect identity, encrypt
  → installed-root boot: verify success, reclaim temporary slice, finish growth
```

Asahi prepares `stub APFS → paired ESP → expandable Root → temporary Installer`
within the allocation approved in macOS. The Root marker image is staging
evidence, never permission to format. Before persistent writes, Linux must
validate the immutable prepared-install manifest, its boot-bound digest and
installation ID, and exact board/disk/partition identities and geometry.
Integrated mode must not fall back to global labels or a general target picker.

V1 is fresh coexistence only: mandatory LUKS2 with the desktop password entered
in Linux, no permanent recovery partition, and no general replacement/repair.
Keep a temporary "Resume installation" boot path and durable progress journal.
After boot commit, never silently reformat; retry incomplete finalization.
Reclamation resumes across slice deletion and partition/mapper/filesystem growth
failures, stopping at the approved boundary. An absent slice is not completion.

Marcelo owns macOS allocation/provisioning, engine/UI changes, production boot
bundle assembly, signing, and publication. This repo owns the component bundle,
Linux validation/provisioning, and bounded resumable reclamation. The stock Asahi
harness without the bound manifest can test packaging/boot only, not authorize
destructive installation. Marcelo's agreement to the narrowly bounded Linux GPT
change is required before release.

## Boot artifacts and ownership

Live and installed boots require different initrds. The builder at the inspected
baseline creates all three variants:

| Purpose | Build artifact | Configuration |
|---|---|---|
| Live installer overlay | `initramfs-omarchy-usb.img` | `configs/usb-initcpio/mkinitcpio.conf` |
| Encrypted installed root | `initramfs-linux-asahi.img` | `configs/usb-initcpio/mkinitcpio-install.conf` |
| Plain installed root | `initramfs-linux-asahi-plain.img` | Installed-root variant without the encrypt hook |

Installed System-ESP files live in `EFI/omarchy/<root-uuid>/`; the encrypted or
plain installed initrd is copied there as `initramfs.img`. Never substitute the
live-overlay initrd. Live refresh must rebuild both live and installed boot
recipes, not leave the live boot stale. Live console quieting and installed
Plymouth/unlock behavior require separate hardware checks.

The PR #19 ownership contract is:

- Piggyback through `custom.cfg` when another OS owns GRUB. Preserve its EFI
  executable and menu; do not parse/rewrite the owner's `grub.cfg` to install us.
- For temporary NVMe live placement, restore the saved pre-live owning loader
  before piggybacking. Own the ESP bootloader only if none existed beforehand.
  Refuse unsupported legacy layouts rather than guessing a repair.
- Use root-private kernels and managed root fragments. Confirmed-absent canonical
  managed entries may be excluded during reinstall; locked LUKS roots, customized
  entries, and uncertain discovery must be preserved. Normal and verbose entries
  reference the same kernel: verbose is not a previous-kernel fallback.
- Never modify Apple partitions from Linux, replace complete `m1n1/boot.bin`,
  write `vendorfw/` or `asahi/`, or claim that installation grants permission to
  run `update-m1n1`. The existing narrowly guarded j613 DTB-slot overlay is the
  only `boot.bin` exception; it is not a general firmware-update mechanism.

Vendor firmware comes from the paired internal ESP via the existing Asahi hook,
not redistributed machine firmware in the payload. The image builder excludes
stock boot-management packages whose hooks could touch the builder's ESP.

## Kernel maintenance: explicit remaining dependency

ISO-installed roots currently have no managed update path for their UUID-private
kernel/initrd. Stock kernel installation or boot-to-ESP migration is not a safe
shortcut. Do not promise kernel updates from ordinary desktop package updates.

The [managed-kernel plan](managed-kernel-updates.md) proposes board-qualified
stable and M3-preview tracks, generation-specific payload packages, and one
versioned deployment manager. Initially j613 is the preview candidate; stable
7.1 provenance still needs recovery. Unknown boards must not inherit support.

Updates must preserve a bootable previous Image/initrd **and its modules**, use
root-private generation paths, and leave the owning bootloader and firmware
untouched. Require a new coherent Image/module/config build rather than repackaging
the mixed-history M3 artifacts. Kernel management is a separate implementation;
integration development can proceed, but public release requires safe update and
fallback evidence.

## Remaining delivery gates

1. Implement integration contract fixtures and zero-write validation/rejection
   tests before enabling prepared-root formatting. Pin explicit companion source
   and package inputs, including desktop review fixes; isolate concurrent work.
2. Test deterministic ZIP64 packaging, capacity calculations including retained
   live boot files, both boot recipes, and interrupted-operation recovery.
   Exercise destructive checkpoints on disposable loopback fixtures with Apple
   partition sentinels, not a physical disk by default.
3. Run existing installer/ESP/provisioning regressions and Marcelo's focused
   Python/Swift suites. Unit success is not visual, firmware, or Mac boot proof.
4. Qualify the integrated path first on j613, then recorded M1/M2 board IDs:
   macOS coexistence, Recovery handoff, cold boot, encrypted unlock, provisioning,
   bounded reclamation, interruption recovery, and repeated reboot.
5. Complete coherent managed-kernel builds and per-track update/fallback metal
   tests. Keep M4 and unqualified boards unsupported. Stable release requires
   evidence for the intended M1/M2/M3 matrix, not CPU-family inference.
6. Obtain owner agreement and record source revisions, artifact digests, test
   results, and remaining limitations before release assembly/signing/promotion.
   Publication, PR creation, and hardware operations remain separately authorized
   actions; writing a plan does not dispatch them.

## Historical design and measurements

The [earlier design at the installer checkpoint](https://github.com/omarchy-mac/omarchy-mac-iso/blob/4407c2ddbe75e6732e9709ce320d7d0125ffbf27/plans/apple-silicon-image.md)
preserves August USB/U-Boot/M2 experiments and the original S0–S7 proposal.
Treat its timings, partition numbers, recovery commands, and unfinished-stage
claims as historical observations, not present-day operating instructions.
Its direct unencrypted OS-image front door and blanket post-install m1n1
ownership claims are superseded by the contracts above. Historical experiments
remain useful evidence, but do not qualify today's integrated release.
