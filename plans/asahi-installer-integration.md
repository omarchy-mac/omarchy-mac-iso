# Plan: Marcelo macOS front end + encrypted Omarchy installer

Status: integration design and handoff, 2026-09-07. Implementation is a separate
workstream; this documentation PR does not certify its progress or test results.
The plan does not authorize builds, disk operations, or publication.

This document supersedes the earlier proposal's permanent recovery slice,
optional encryption, label-authorized target selection, and requirement to wait
for merges or clean unrelated work. Read this repo's `AGENTS.md` before acting.

## 1. Outcome and locked decisions

Use Marcelo's [macOS application](https://github.com/maralcbr/omarchy-mx-mac)
as the product front door. Its Asahi engine handles macOS-side APFS shrinking,
allocation, stub/paired ESP creation, Apple boot provisioning, and Recovery
handoff. Our live installer boots from a temporary internal slice and installs
an encrypted root into the specifically prepared partition. No USB is required.

- Install beside macOS, using only the allocation approved in macOS.
- Asahi precreates the final root partition and temporary tail installer slice.
- Require LUKS2 for this integrated target; no encryption-off option. Keep the
  existing standalone installer's separate encryption choices unchanged.
- Collect identity and password in Linux. The desktop and encryption password
  are the same, as in the current installer. Never persist or transport secrets
  through macOS, the ESP, metadata, command arguments, or logs.
- Reclaim the temporary slice after a successful boot into the installed root.
  A permanent recovery slice is not part of v1.
- V1 is fresh coexistence only. No general reinstall, replacement, or repair
  workflow through the integrated target; narrowly scoped interrupted-install
  handling is required for safety.
- Contribute a cross-repository contract and patches, not a fork of the app.
  Marcelo owns app assembly, signing, catalog promotion, and publication.
- Start hardware qualification on M3 Air `apple,j613`, then M1 Pro
  `apple,j314s` and Scott's M2 14-inch (record its exact board identifier).
  Public v1 requires all three qualification results. M4 is outside that gate;
  unqualified models remain rejected.

## 2. Pickup, isolation, and pinned dependencies

Create the implementation worktree at
`/home/scott/code/omarchy-mac-iso-asahi-integration`, branch
`feat/asahi-installer-integration`, if it does not already exist; otherwise
inspect and continue its recorded baseline without resetting it. Leave the
main checkout, its tracked edits, untracked plans, extracted initramfs, and
troubleshooting scripts untouched. Do not clean, stash, stage everything, or
commit someone else's WIP. Worktree creation may require filesystem approval.

The following are the last inspected baselines, not claims about current remote
status. Recheck PR heads and merge state at pickup, and record full revisions.

| Repository | Baseline | Last inspected state |
|---|---|---|
| omarchy-mac-iso | [PR #19](https://github.com/omarchy-mac/omarchy-mac-iso/pull/19), `4407c2ddbe75e6732e9709ce320d7d0125ffbf27` | Open; `fix/image-provisioning` into `main` |
| omarchy-mac | [PR #372](https://github.com/omarchy-mac/omarchy-mac/pull/372), `39629f3f65db671c7d866b4d94d8b9b092037e3a` | Open; Electron-wrapper review fixes included; targets `quattro`, not `main` |
| omarchy-pkgs-aarch64 | [PR #12](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/pull/12), merge `c9e2383d22ab839a5b3a27af288809dcf4fe6dd9` | Merged; recipe preparation available |

Branch from the inspected installer PR head instead of waiting for everything
to merge. Use isolated companion source checkouts and explicit build inputs.
The earlier desktop pin was `010b779345a288c1641f413911383054e133373a`.
Explicitly advance existing integration locks to the reviewed revision above,
then rebuild packages and rerun affected tests; changing this table does not
update another worktree's lock or its artifacts. Apply subsequent review fixes
through the same explicit baseline-update process. Reconcile the integration
branch with merged upstream history later; do not duplicate already-landed
provisioning or ESP fixes.

The earlier source inspection used Marcelo revision
`b6e7741f59454af3c3d7de738fa17327bdb9038a` and Asahi engine revision
`f0469cea0899f3efed8efead604174c7a53c4451`. Verify their current locks before
implementing companion patches. Read each companion repository's instructions.

### Package build checkpoint

- Pin both desktop source (`OMARCHY_PATH`) and verified package artifacts
  (`OMARCHY_LOCAL_PACKAGES`); source checkout alone does not pin installed bytes.
- #12 applies the carried upstream recipe fixes before building. It did not
  itself publish new package versions. Use that preparation for PR-head builds;
  do not disable #372's packaging tests to work around upstream recipe lag.
- The [general updater](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/blob/main/.github/workflows/update-packages.yml)
  is six-hourly; the relevant [Omarchy pair workflow](https://github.com/omarchy-mac/omarchy-pkgs-aarch64/blob/main/.github/workflows/update-omarchy-mac.yml)
  is hourly. Both can be manually dispatched, but the latter checks out a
  release tag, not an unmerged PR head, and skips an already-published version.
- Until a qualifying release exists, build from the pinned PR-head checkout
  using prepared recipes. Once one exists, use the existing workflow with
  `dry_run=true` to obtain verified artifacts without publishing. A manual run
  is not a force-rebuild or source-SHA override. Recheck workflow inputs first.
- Record all source/recipe revisions, package versions, kernel/config identity,
  and artifact hashes. Keep publication separate from build verification.

## 3. Shared artifact and handoff contract

### Packaging and layout

Add `--asahi-os-package` to the builder, requiring `--usb --rootfs`, plus a
standalone packaging helper that accepts an existing verified build. Produce a
component tree for Marcelo's assembly and a finished ZIP64 test package.

The new allocation is ordered: stub APFS, paired ESP (500 MiB), expandable
Root, fixed tail Installer (12 GiB). Existing macOS and Recovery remain intact.

- Root minimum: `max(32 GiB, live-used-bytes + 8 GiB)`; initialize it from a
  16 MiB `mkfs.btrfs --mixed -L OMARCHYTARGET` marker image, `target.img`.
- Installer image: existing raw `payload.img`, named `installer.img`, copied
  verbatim. The live lower filesystem remains `OMARCHYLIVE`.
- The marker is useful for staging verification, never authority to format.
  Linux authorization comes from the bound manifest below.
- At the 32 GiB root floor, EFI + Root + Installer total about 44.5 GiB,
  excluding the stub. The inspected Asahi expandable-layout recommendation
  doubles that to about 89 GiB, plus stub accounting. Derive displayed values
  from actual metadata; do not retain the old plan's 32.5/65 GiB estimates or
  equate total allocation with root capacity.
- Stage private live GRUB, kernel, and both live/installed initrd artifacts;
  retain `/omarchy-nvme-live` as a file. Metadata uses one recognized target,
  `omarchy_target: "apple-silicon-live-installer"`, per document. Keep engine
  operation `install` and existing catalog/request schemas.
- Emit `bundle-v1.json`, metadata and byte-identical sidecar, checksums, and
  build provenance. Use deterministic archive ordering/metadata and explicit
  ZIP64. Reject unsafe paths, symlinks, duplicate members, mismatched hashes,
  unaligned raw images, and images exceeding their destination before writes.
- Use a checksum-pinned UEFI-only bundle for standalone test assembly. The
  component output excludes `m1n1/boot.bin`; Marcelo supplies the production
  boot bundle. Never replace an existing machine's whole `boot.bin`. The
  existing guarded j613 DTB-slot patch remains the only Linux-side exception.

### Immutable prepared-install manifest

Define and fixture-test `prepared-install-v1.json`, stored on the paired ESP at
`/omarchy-installer/prepared-install-v1.json`, not under `asahi/` or the live
marker filename. Include:

- Schema version, random installation ID, approved plan and artifact digests.
- Exact supported board, disk GPT GUID, disk size, and logical sector size.
- Approved sector extent and ESP/root/live PARTUUIDs, GPT types, starts, sizes.
- Live filesystem UUID, boot artifact hashes, mandatory-encryption policy, and
  consume-after-success policy.

The macOS engine writes the finalized manifest and binds its SHA-256 and
installation ID through m1n1 stage-1 `/chosen` properties before Recovery
handoff. Validate that transport through the pinned boot chain. This binds the
intended handoff; do not describe it as complete verified boot over mutable
stage-2 files.

Discover the paired ESP from `asahi,efi-system-partition` in the device tree,
then use the bound live PARTUUID. Integrated boot must not fall back to a
global filesystem label, `/dev/sda2`, or an arbitrary existing ESP. Missing or
invalid binding leads to diagnostics, never a destructive legacy fallback.

## 4. Linux installer and resumable completion

Implement a dedicated prepared-install path using current formatting, lowerdir
copy, identity provisioning, and per-root ESP helpers. Keep legacy USB and
manual NVMe workflows separate and regression-tested.

Before any persistent write, validate the binding, exact board/disk/partition
identity, type and geometry, approved bounds, root/live adjacency, boot inputs,
and sufficient root/ESP capacity. Reject ambiguous duplicates and stale layouts.
Revalidate immediately before destructive operations. Dry-run must make zero
persistent writes, including GPT naming and ESP changes. Current startup calls
`ensure_installer_partlabel` before its dry-run exit: move/gate that behavior.

After validation and the explicit summary/confirmation, name only the validated
live slice `omarchy-install`, format only the prepared root as LUKS2 + btrfs,
copy used files from `/run/omarchy-root`, and apply existing provisioning.
Do not create/delete other partitions, shrink APFS, or offer a target picker
that can escape the approved allocation. Own only the newly provisioned paired
ESP; preserve all protected firmware and Apple boot data.

Retain the temporary live boot files and a narrowly labeled "Resume
installation" GRUB entry until successful installed-root boot. Gate both early
`esp_nvme_drop_unused_before_copy` and final `esp_cleanup_nvme_live` cleanup;
capacity calculations must include retained files rather than credit their
deletion. Insufficient capacity fails before formatting.

Keep a durable progress journal separate from the immutable manifest, on the
ESP with a copy in the installed root. Use durable intent/completion records
and reconcile actual state after interruption. Track formatting, copy and
provisioning, boot commit, successful installed-root boot, slice deletion,
partition growth, mapper growth, filesystem growth, and final cleanup.

- PARTUUID remains the target identity after formatting destroys the marker.
- Before boot commit, an incomplete target may be restarted only after explicit
  confirmation and re-entering secrets. Never silently erase a completed root.
- After boot commit, allow diagnostics or retry of incomplete finalization,
  not general destructive reinstall/repair.
- First-boot consume must prove the running root is the bound installed root,
  walking dm `slaves` for LUKS. Require the exact live PARTUUID, GPT name
  `omarchy-install`, Linux type, same disk, and sector adjacency before deletion.
- Grow only to the approved end of the former installer extent, not to the
  end of an arbitrary following hole. Check Apple partition snapshots before
  and after GPT changes; never delete APFS, iBoot, or Recovery partitions.
- Resume safely if the slice is already gone but any growth step is incomplete.
  The current "slice absent means done" shortcut is insufficient. Disable the
  service and remove temporary boot files only after all growth is verified.
- Never log encryption keys, including when exercising the mapper-resize path.

## 5. Marcelo-side changes and compatibility

Prepare a contribution branch/patch against the pinned app source, subject to
that repository's instructions; do not sign, publish, or open a PR implicitly.

- Recognize exactly one supported target in metadata and validate the layout
  keyed by target. Preserve existing full-OS behavior and reject cross-wired
  images. Enforce image/partition and ESP capacity before disk writes.
- Generate and bind the manifest above. Keep metadata hashing in the existing
  plan digest; no new operation or generic request-schema expansion is needed.
- Make UI progress/completion target-aware: macOS prepares the Linux installer;
  installation and encryption finish after booting Linux. Identity prefill is
  deferred, and passphrases always stay in Linux.
- Separate staging verification from final installed evidence: raw marker-image
  prefix checks cannot remain valid after LUKS formatting. Recognize both the
  staged stub/ESP/root/live layout and consumed stub/ESP/root layout to prevent
  duplicate installations. Do not thereby enable general replacement.
- Amend the safety contract to permit only the explicitly bounded Linux-side
  temporary-slice deletion/root growth; the old "Linux never edits GPT" rule
  conflicts with the chosen reclaim policy. Owner acceptance gates release.
- Resolve model/firmware support explicitly. In the inspected engine, j613
  firmware 14.8.3 requires expert support while the wrapper disables that route.
  Adding j613 to catalog metadata alone is insufficient. Add scoped, tested
  model/firmware capability, not a blanket expert-mode bypass.
- Marcelo regenerates locks, engine bundle, signatures, and catalog after
  reviewing changes and hardware evidence. Signing is not needed for our
  local contract tests or unsigned package/boot harness.

Stock Asahi can exercise packaging and boot through `INSTALLER_DATA` and
`REPO_BASE`, but without the bound-manifest integration it is diagnostic-only,
not a production formatting bypass. A fully offline harness also needs the
engine and IPSW assets (`IPSW_BASE`), with the OS ZIP under `REPO_BASE/os/`.

## 6. Implementation order and acceptance gates

1. Establish the isolated pinned baseline and run `./test/unit`. Record results
   rather than inheriting prior green claims. Save provenance and a reference to this plan in
   the integration worktree. It starts from a different branch; explicitly carry
   the reviewed documentation revision there rather than assuming it is present.
2. First bounded coding milestone: shared manifest/layout fixtures, read-only
   validator, and behavioral rejection tests. Prove no writes before adding
   the new formatting path. Implement packaging and artifact checks alongside
   these fixtures; no hardware or publication required.
3. Add prepared installation, retained live boot, durable journal, and bounded
   resumable consume. Reuse current provisioning and ESP behavior rather than
   rebuilding it. Add interruption tests with each new state transition.
4. Prepare companion engine/UI patches and unsigned end-to-end harness. Build
   exact packages and an integration image on an appropriate Asahi host; a
   package-set change requires rootfs rebuild, not merely live refresh.
5. Perform explicitly coordinated hardware tests, then hand off evidence and
   release prerequisites. Unit success does not establish visual/metal proof.

Required automated coverage:

- Existing unit, partition, ESP/GRUB, and provisioning regressions; checks must
  fail when behavior is removed, not pass on matching comments.
- Malformed/missing/stale manifest, wrong chosen binding, wrong ESP or board,
  duplicate IDs/labels, wrong GPT types/geometry, nonadjacent live slice,
  inadequate capacity, unsafe ZIP members, and cross-target metadata: no writes.
- Deterministic archive assembly from identical inputs, ZIP64/readback and raw
  image sizing; marker destruction must not break bound target identification.
- Failures at formatting, copy, provisioning, EFI commit, deletion, and each
  growth stage; interrupted retries never escape the same approved target.
- Disposable loopback layouts with Apple-type sentinel partitions: unchanged
  Apple entries and data, bounded growth, rerun after deletion, repeated success.
- Focused Python and Swift contract/UI tests under Marcelo's repo instructions.

Metal qualification records exact artifact hashes, board, firmware, and kernel:
macOS coexistence, Recovery handoff, cold live boot, confirmation and encryption,
first encrypted-root boot, successful reclaim/growth, repeated cold boot/unlock,
unchanged protected firmware, and relevant display/input/network/USB behavior.
Complete M3 j613 first, then the exact M1 and M2 boards. No unsupported-model
claims based solely on CPU generation or catalog additions.

### Separate kernel-update dependency

[Managed kernel updates](managed-kernel-updates.md) and the
[kernel input audit](../docs/kernel-input-audit-20260907.md) are separate
workstream documents, not implemented features. Reuse their eventual reviewed
kernel packaging/deployment contract rather than duplicating it here. Public
release requires coherent Image/modules/config provenance, safe per-root ESP
kernel/initrd updates, retained working fallback, and update/fallback metal tests.
Historical M3 boot evidence does not prove a fresh reproducible kernel build.
Keep stable and M3-preview image qualification distinct until a common live
kernel is demonstrated. Integration source work need not wait for this release
gate, but public-ready status must.

## Handoff boundaries

The implementation agent should return a branch/commit summary, pinned input
manifest, test results, produced artifact hashes, companion patches, and an
explicit list of remaining hardware/owner gates. Do not silently dispatch a
publishing workflow, merge PRs, alter the main checkout, install on a machine,
or modify protected boot firmware. Those are separate coordinated actions.
