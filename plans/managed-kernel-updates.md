# Plan: managed Apple Silicon kernel tracks

Status: source-only design, 2026-09-07. Implementation, builds, publication,
and hardware changes are not authorized by completion of this document.
Companion to [the image design](apple-silicon-image.md).

## Pickup checklist — paused after planning

The audit and this design are complete; implementation has **not** started.
Kernel work was paused to address desktop PR #372 feedback. The plans and audit
are published together for review; code implementation remains separate. When
resuming from another branch, explicitly carry the reviewed documentation
revision rather than assuming that checkout contains it.

Resume by reading this document and
[`docs/kernel-input-audit-20260907.md`](../docs/kernel-input-audit-20260907.md),
then checking the current branch/status in both repositories. Preserve unrelated
untracked research and extracted-image files; do not stage whole directories.

Next bounded implementation task, when requested:

1. In `omarchy-pkgs-aarch64`, start a separate kernel feature branch from the
   reviewed base, not on the existing first-run packaging PR branch.
2. Capture the M3 source commit and full config identified in the audit, with
   SN201202X enabled, into reviewed build inputs. Lock the build environment.
3. Add the generation-specific M3 payload recipe, artifact verifier, and a
   build-only workflow. No release upload, automatic updater inclusion, selector
   rollout, image rebuild, or machine installation in that milestone.
4. Require a fresh Image/module build and compare embedded config, module
   identity, manifests and package paths. Record deviations from the historical
   test binary rather than claiming the new package is byte-identical.
5. Return for review before the deployment-manager/installer work below.

Known blockers/risks: the historical M3 image and later USB module have different
config histories; the exact 7.1 recipe/config provenance is unestablished;
kernel fallback must retain modules; current ISO roots have no managed update
hook. No access to a running Mac is needed for the next source-only milestone.

Planning estimate: roughly 5–10 focused engineering days plus hardware-test
turnaround for the full project. Build-only M3 packaging is estimated at 1–2
days; safe deployment/fallback and failure tests are the largest portion. These
are estimates, not measured execution times or a promise of completion.

At pause: ISO unit checks, Markdown local-link checks, and whitespace checks
passed. No kernel or image was rebuilt, no packages were published, and no
running-machine or ESP changes were made during the audit/planning work.

## Outcome and current evidence

Give ISO-installed roots a package-managed kernel update path without taking
ownership of another installation's GRUB or modifying Apple boot firmware.
Use separate stable and M3-preview tracks, not a permanent version freeze:

| Track | Initial candidate | Initial hardware gate |
|---|---|---|
| Stable | Asahi 7.1.6, subject to recovering exact build provenance | New M1 and M2 installation/upgrade/fallback tests |
| M3 preview | Asahi commit `236788cd2602a24c703fe7bdaddaf73ef77d2027`, 7.2.2 with SN201202X enabled | j613 only until other models are individually validated |

The [input audit](../docs/kernel-input-audit-20260907.md) identifies a working
M3 baseline but also finds that its Image and later USB module were not produced
with the same final config. A coherent new build is required; packaging the old
files is not equivalent to a clean rebuild. The stable candidate's source/config
provenance is still incomplete. Neither track is ready for publication today.

## Ownership and proposed interfaces

`omarchy-pkgs-aarch64` owns recipes, immutable build-input manifests, native ARM
build-only CI, artifact verification, and eventually separately approved promotion.
`omarchy-mac-iso` owns hardware selection, the root/ESP deployment contract,
initcpio sources, installer adoption, recovery behavior, and regression fixtures.

The installed deployment helper and its hook/config files must be an independently
versioned package built from a pinned ISO-repository commit, not loose copies
dependent on the next installer refresh. Proposed name: `omarchy-kernel-manager`.
Desktop updates can call its status/retry interface later; they must not duplicate
ESP-writing logic. No desktop source change is needed for the first build-only PR.

### Package structure and real fallback retention

Proposed track selectors: `linux-omarchy-asahi` and `linux-omarchy-asahi-m3`.
Use a small tracking package depending on a **generation-specific payload package**
and the compatible kernel manager. A new generation gets a new payload package
name and a unique kernel release/module directory, including for packaging/config
rebuilds of the same upstream kernel version.

This extra layer is deliberate: upgrading a conventional single kernel package
removes its old modules. Retaining just an old Image/initrd on the ESP does not
provide a working fallback after the root has mounted. Versioned payloads let
the previous Image, initrd, module tree, and optional headers survive together.

- Payload: `/usr/lib/modules/<kernel-release>/` plus a namespaced kernel Image,
  config, source/license material, and manifest under
  `/usr/lib/omarchy-kernels/<generation>/`. No ESP paths or firmware payloads.
- Optional headers must match that payload exactly; DKMS integration is a
  separate acceptance gate, not an implied feature of the first package.
- Selectors update only through explicit track promotions. They must not
  automatically replace stock `linux-asahi` on existing non-ISO installations.
- Keep the deployed current, last known-good, and running kernel payloads
  installed. A pre-removal guard must reject deleting their packages or removing
  the manager while protected generations remain, including orphan-cleanup
  transactions. Test real pacman dependency/removal behavior before approval.
- An interrupted package upgrade leaves the previous boot generation and its
  modules intact. Failed post-transaction deployment does not roll pacman back;
  report a persistent pending deployment and offer a deterministic retry.
- No automatic payload garbage collection in the first iteration. Later cleanup
  is restricted to unreferenced generations with confirmed package ownership.

## Build input and artifact contract

For each candidate, commit a manifest containing source URL and full revision,
archive checksum, patch list/checksums, full resolved config/checksum, toolchain
versions/container digest, release naming, recipe revision, and supported boards.
Require license/source provenance. Record input and output hashes with artifacts.

Start the M3 candidate from the audited current config, with SN201202X enabled,
and build Image plus **all** modules/DTBs in a fresh output directory. Do not reuse
the research output directory, its old module archive, or host `uname -r` defaults.
Capture the old embedded config as historical evidence, not as the new USB-ready
configuration. Eliminate the accidental `+` release suffix through an explicit,
tested build identity. Set reproducible build user/host/time and prefix mappings;
an intentional identity/toolchain change requires new validation, not a claim of
byte identity with the historical Image.

Build verification must check:

- aarch64 Image and modules; 16 KiB-page Asahi config and required drivers;
- config extracted from Image equals the final config used for modules;
- exact kernel release, module vermagic, dependency resolution, compressed-module
  handling, and V14_7 support for the preview track;
- SN201202X present and enabled for j613, plus display, USB/NVMe, btrfs and LUKS
  module requirements; no symlinks back to the build host;
- complete package inventories and no `/boot`, EFI executables, firmware dumps,
  host identifiers in shipped copy, or unreviewed privileged scriptlets;
- all artifacts from one build, never mixed across reruns or tracks.

Native ARM CI need not boot an Asahi kernel to compile it. It cannot validate
hardware behavior or build a trustworthy machine-specific firmware initrd merely
by running in an ARM container. Record toolchain availability, disk/RAM/runtime
requirements with the first build before setting production resource limits.
Follow [upstream reproducibility guidance](https://docs.kernel.org/kbuild/reproducible-builds.html).

## Installer selection and migration

Detect board/SoC from the device tree, not CPU architecture alone or a hostname.
Use a tested allowlist of model identifiers; j613 is the only initial preview
entry. Unknown M3 models and future chips must not silently inherit j613's DTB
overlay or a supported status. Show chosen track/version in confirmation output.

Keep two explicit image profiles initially: stable and M3 preview. The current
builder accepts one kernel/module set. This avoids assuming the preview live
kernel already works on every M1/M2. A later universal medium can bundle both
live kernel sets and both offline target packages, but boot-time selection needs
its own tests; an installer decision cannot fix a live kernel that never boots.

For fresh installations, offline-bundle the selected payload, selector, manager,
and complete dependencies. Replace raw module copying only once package staging
is proven. Use an explicit target/chroot initialization mode: never discover or
write the builder's ESP. Compute fresh identity after formatting/UUID changes.

For existing ISO roots, provide an explicit, previewable adoption command:

1. Verify mounted btrfs root UUID, `@` subvolume, LUKS ancestry where applicable,
   exact ESP UUID/partition identity, ownership mode, and managed menu schema.
2. Validate and preserve the currently bootable Image/initrd **and complete
   matching module tree**, not just `uname -r`. Import them as a protected legacy
   generation without claiming pacman ownership of unrelated files.
3. Handle ownership collisions with copied files explicitly; never use a broad
   pacman `--overwrite`. New release names should avoid old module paths.
4. Install manager configuration and the chosen payload; deploy a candidate only
   after the legacy recovery path is complete. No silent track change.

Persist root/ESP/LUKS identity, layout schema, track, candidate and known-good
generation IDs in a machine-readable, versioned state file. Read it as data,
not shell code. Validate UUIDs and paths; reject stale clone identities,
symlinks, snapshot-root mismatches, missing/read-only/wrong ESP, and NVMe-live
placement. A clone must explicitly re-identify itself before updates.

Scope the first adopter to UUID-private System-ESP installs (owned and piggyback).
Wipe-USB/legacy ESP-root layouts require a separately tested migration or an
explicit refusal; do not silently advertise them as supported.

## Safe deployment and boot-menu design

Use immutable generations under:

```text
EFI/omarchy/<root-uuid>/
  generations/<generation>/vmlinuz
  generations/<generation>/initramfs.img
  generations/<generation>/manifest
  boot.cfg                         # small selector owned by this root
```

The root's managed menu fragment should become a versioned, recognizable source
stub for this private `boot.cfg`. Preserve the normal menu title/identifier so an
existing managed default still resolves. Give the previous-kernel entry a clearly
distinct title; verbose mode remains a diagnostic variant, not a fallback.

**Migration detail:** today's `grub/omarchy.cfg` concatenates fragments. Merely
editing `<root-uuid>.cfg` is ineffective until the aggregate is regenerated. A
one-time managed-format migration must update this root's stub and the managed
aggregate under a lock, preserving every other root's content/default and all
custom fragments. It must not run stale-root pruning during a kernel update.
Update `managed_root_is_stale` to understand legacy canonical entries and the new
schema conservatively. Subsequent kernel deployments change only the root's
private selector and generation files, not the shared aggregate or owner menu.

Do not replace `BOOTAA64.EFI`, run `grub-install`/`grub-mkconfig`/`update-m1n1`,
write `extlinux`, or touch `m1n1/`, `vendorfw/`, `asahi/`, Apple GPT or APFS.
Routine updates do not apply the j613 overlay; reject a candidate whose documented
firmware/DT prerequisites are not already met. Any prerequisite change is a
separate, explicitly authorized operation.

Deployment sequence:

1. Lock the expected ESP/root operation and revalidate identity, supported schema,
   mounted state, protected paths, free space for a new generation plus recovery
   files and slack, candidate package hashes, and retained module availability.
2. Build the installed initrd on the root filesystem using the selected kernel
   release and versioned manager configs, not the running kernel or the placeholder
   `/etc/mkinitcpio.conf`. Stage firmware through the existing Asahi hook read-only.
   Preserve wait/Plymouth/LUKS ordering; omit encrypt for a plain root. Reject live
   overlay hooks in an installed initrd. Verify essential contents before copying.
3. Copy into a new ESP generation directory, flush and reread hashes. Never
   overwrite either referenced generation. Keep last known-good modules locally.
4. Write and validate a new small root-local selector referencing the verified
   candidate and last known-good, then replace the selector with recovery metadata
   retained. Flush explicitly. A FAT rename is not a multi-file transaction or a
   guarantee against power loss; interruption and recovery tests are mandatory.
5. Record pending boot status. Do not mark a generation known-good just because
   deployment succeeded. A subsequent boot must match the candidate release,
   root UUID and generation, followed by operator confirmation during preview.

Keep a separately reachable known-good entry outside the mutable selector during
migration/deployment, and document recovery from the existing compatible owner
GRUB or live medium. Whether GRUB automatically retries a failed boot is **not**
part of this first milestone. Manually booted kernel fallback is not a userspace
rollback; btrfs snapshots and kernel-generation state must remain distinguishable.

## Pacman and initramfs integration

Design pre-transaction refusal and post-transaction deployment separately.
Pacman supports abort-on-failure only for pre-transaction hooks, and does not run
post-transaction hooks after an incomplete transaction. Do not promise rollback
from a failed post hook. [Pacman hook semantics](https://man.archlinux.org/man/alpm-hooks.5.en)

Use a preinstalled manager to guard updates/removals and a post hook to deploy a
verified new payload. Bootstrap explicitly in the installer/adopter because a new
package cannot be assumed to provide a pre-hook before its own first installation.
Test ordering with real disposable pacman transactions, not only shell stubs.

Audit the currently renamed mkinitcpio hooks, package upgrades that restore them,
and desktop/firmware commands that call `mkinitcpio -P`. Replace ad-hoc renaming
with package-managed, documented hook/preset behavior. The selected kernel manager
must be the single ESP deployment owner. Do not blindly re-enable the old preset
or globally suppress valid kernels belonging to other layouts.

Initramfs regeneration after initcpio/cryptsetup/firmware-policy changes must use
the same generation protocol even when the kernel package is unchanged. Record
initrd/config generations separately where needed. Preserve the old bootable
initrd until the replacement has actually booted.

## Delivery stages and acceptance gates

| Stage | Repository / deliverable | Required evidence before advancing |
|---|---|---|
| 0 — audit/plan | ISO docs, this document | Completed; provenance gaps explicitly recorded |
| 1 — build-only M3 package | ARM repo: locked inputs, versioned payload recipe, verification script, manual/PR workflow with read-only permissions | Fresh coherent build, package/config/module checks; no publishing job or generic update-matrix inclusion |
| 2 — deployment prototype | ISO repo: versioned manager, schema, fixture tests; ARM repo packages a pinned helper revision | Real disposable pacman transactions and FAT/btrfs/chroot tests including failures and retention |
| 3 — installer/adopter | ISO repo: offline package inputs, track allowlist, adoption and initcpio integration | Fresh and legacy fixtures, clone/snapshot refusal, both encryption modes, ownership preservation |
| 4 — M3 metal | Explicitly approved test machine | Fresh install, A→B upgrade, B→A fallback, matching modules after root mount, LUKS/plain boot and USB/display/network checks |
| 5 — stable track | ARM repo: recover 7.1 provenance, recipe, stable profile | Separate M1 and M2 installation/upgrade/fallback evidence |
| 6 — publication | ARM repo: manually approved promotion by artifact digest | Promote already-tested artifacts without rebuilding; dependency and retention checks; only later add update detection |

Stage 1's concrete first implementation is the **M3 payload recipe and build-only
workflow**, not publishing the tracking selector or changing the test Mac. Capture
the coherent config and full source/toolchain manifest in that PR. Keep stable
track work blocked on provenance rather than guessing a 7.1 source pin.

Before stage 6, make kernel publication use the same `edge-publish` serialization
as other repo writers. Stage the manager, payload, optional headers, and selector
as a verified dependency closure; upload assets before publishing database entries.
Keep prior payloads in the database or a deliberately separate recovery archive
so the existing publisher cannot delete recovery assets. Verify no downgrade,
cross-track replacement, same-version binary overwrite, or orphaned dependency.
Initial publication remains manual and requires hardware approval per track.
Review the repo's unsigned-package trust policy before broader distribution.

## Required regression and metal matrix

- Exact board detection, unknown boards, wrong track, config/Image disagreement,
  missing SN201202X/V14_7/crypto modules, mismatched kernel releases and host links.
- Owned/piggyback ESP; multiple roots; normal/verbose/previous menus; customized
  fragments; legacy unsupported loader; live NVMe placement; clone UUID changes.
- LUKS/plain roots; USB/NVMe storage; missing vendor hook; readonly/wrong/unmounted
  ESP; stale/snapshot root state; full ESP; concurrent invocation; tampered manifest.
- Failure before/after package extraction, during initrd generation, during each
  copy/flush/selector step, and before boot confirmation. Retry must be idempotent.
- Real package upgrade/removal/orphan-cleanup with old modules retained; failed
  deployment status; booting the previous generation after upgrading userspace.
- Cryptsetup and initcpio-triggered rebuilds without a new kernel; btrfs snapshot
  restore detection; adoption refusing unknown files and ownership conflicts.
- Hash every protected firmware/owner file before and after metal updates. Check
  cold boot, LUKS prompt, normal desktop, USB role changes, Wi-Fi and root growth
  compatibility, then deliberately boot the previous generation and load modules.

Passing unit tests or a generic ARM/QEMU boot is not M1/M2/M3 hardware proof.
Keep the recovery medium and current working kernel untouched until each test
operation has explicit approval.
