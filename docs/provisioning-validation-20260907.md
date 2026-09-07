# Provisioning checkpoint — 2026-09-07

This checkpoint fixes target-chroot command resolution, propagates provisioning failures, retains installation logs in `@log`, restores installed-service settings, and protects shared ESP ownership. Chromium's software-GL wrapper must exist before user finalization: the browser desktop entry refers to it, and `xdg-settings` rejects a missing executable.

## Validation

- ISO `./test/unit` and `git diff --check`: pass.
- `test/provisioning-chroot` with the rebuilt desktop package, real bind mounts, chroot, and disposable btrfs `@log`: success and failure scenarios pass. Its setup commands are synthetic; it is not a full desktop installation test.
- The original image failed user finalization on an M3. A disposable-overlay rehearsal reproduced the failure with the old ordering and passed with the corrected ordering. The incomplete installation was then recovered successfully. The ESP checksum and partition table were unchanged by that recovery.
- A full `--usb --rootfs` build completed at `2026-09-07T11:59:20Z`, recreating the root filesystem, live/encrypted/plain initrds, and GRUB loaders. The delivered artifact is not the intermediate surgical payload patch.
- Kernel input: `7.2.2-omarchy-wip72+`, source ref `236788cd2602a24c703fe7bdaddaf73ef77d2027`, with matching module inputs. Desktop packages: `omarchy` and `omarchy-settings` `4.0.2-4`; video packages `avd-fw` `0.1-1` and `libva-v4l2_request-avd` `1.3-1`.
- Build checksums, packaged-source comparisons, initrd hooks and required modules, module vermagic, and final hardware database lookup: pass. The installer extracted directly from the raw payload matches source. Decompressing the delivered payload reproduces the verified raw-image hash.
- The portable tester drop was copied to the transfer volume, flushed, and every manifest entry verified. Older files were preserved.

The desktop companion changes avoid privileged permission changes for an already-correct Electron wrapper, refuse boot-to-ESP migration for shared/UUID-private layouts, and test the timezone notification's argument handling. Their focused tests pass. Earlier full desktop QA had five environment-dependent shell-test failures; this checkpoint does not claim that the entire desktop suite is green.

The builder emitted an intermediate hwdb hook error and kernel-image autodiscovery/optional-firmware warnings. Final hardware database and required initrd checks pass; those checks do not prove hardware firmware availability.

## Artifact identity

Tester folder: `omarchy-mac-apple-silicon-preview-20260907-wrapper-order`.

- Raw payload SHA-256: `ebc207bb1f2db40fce767e5d478c0a7483d0c1c7050577e467359676f0c8df32`.
- Compressed payload SHA-256: `abe636dae010c5dc1e77bbb8c89ea6b5823303763f3dc1a200555b3a40026015`.
- Packaged installer SHA-256: `3d499821312462593594f1296fcd3f38447cbe39f49ed66af27d6e03b4280e9d`.

The build predates this checkpoint commit and records its source as dirty. These hashes identify the tested artifact; no byte-for-byte reproducibility claim is made. Detailed local logs remain under the ignored `release/install-audit-20260907/` directory and are not required to run the committed regression tests.

## Hardware validation pending at the initial checkpoint

At commit time, a fresh installation of the rebuilt image is in progress. Before reboot, inspect the complete provisioning log, completion markers, and root-specific boot configuration. After reboot, validate LUKS unlock, first graphical login, absence of unattended sudo, notification actions, networking authorization, clock synchronization, and installer-slice consumption/growth. Recovery of the previous installation is not proof that this new image completes an end-to-end installation. This is a work-in-progress checkpoint, not a release sign-off.

## Subsequent first-boot findings and source follow-up

The fresh target completed system and user provisioning without recovery. Its wrapper/default-browser configuration, `finalize-user` marker, enabled services, shared-ESP notice, and `@factory` baseline passed read-only checks. It then booted the correct encrypted root using the UUID menu loaded manually from GRUB's command line. The temporary installer slice was consumed successfully and the root grew from approximately 119.7 GiB to 131.7 GiB. Networking, time synchronization, and Apple display output at 2560×1664 were observed working. These findings do not prove all desktop or hardware functionality.

Three further defects were identified:

- The preserved standalone EFI loader lacks `test.mod`, which supplies the `[` command used by conditional menu includes. That prevents the managed menu from appearing; its original default also points to a previous root. New standalone builds now include and preload `test`. Reinstalling does not replace a preserved owner's EFI executable, so the installer now rejects this known old standalone layout before formatting instead of reporting a successful installation with unreachable entries. The NVMe check examines the saved owning loader, not the temporary live loader. No migration of its configuration or unmarked default is authorized by this source change.
- The settings package omitted `omarchy-brightness-keyboard-auto.service` from systemd's unit directory despite first-run setup requiring it. The corresponding stable/development package recipes now install it; tests exercise real package staging and every service requested by first-run setup.
- The ARM desktop package did not depend on Snapper. The old setup leaf hid the missing-command errors and mislabeled the root as unsupported. Snapper is now a shared dependency in the stable/development package recipes. Setup detects non-btrfs roots separately and preserves actual Snapper diagnostics and failure status on btrfs.

At this follow-up checkpoint, the source changes had not repaired the running installation. A new image and subsequent reinstall were still required to validate the package changes on hardware. The existing legacy GRUB owner also required an explicitly authorized compatibility migration or restoration before the stricter installer would proceed; neither an image rebuild nor a transfer-volume copy changes that owner.

## Final rebuild and fresh-install validation

A separately authorized, backed-up GRUB-only repair restored the existing owner's conditional menu support before this test. The source installer does not automatically perform that legacy repair.

The final follow-up also handles a free-space reinstall after the old Linux root has been erased: a confirmed-absent managed default transfers to the new root, and confirmed-absent canonical root entries are omitted from the active menu. Present roots, locked LUKS roots, customized fragments, and uncertain device discovery are preserved. Inactive fragments and kernel files remain available for recovery or reconnection.

- A full `--usb --rootfs` build completed at `2026-09-07T16:14:01Z`, rebuilding the root filesystem, all three initrds, and both standalone GRUB loaders. This was not a surgical payload patch.
- Kernel inputs remained `7.2.2-omarchy-wip72+` at source ref `236788cd2602a24c703fe7bdaddaf73ef77d2027`. The locally built desktop/settings packages were `4.0.2-5`, with Snapper `0.13.1-3` installed.
- Packaged-source comparisons, required initrd hooks/modules, module vermagic, hardware database checks, and `test.mod` presence in both GRUB loaders passed.
- `./test/unit` passed. The reinstall regression suite passed all 154 assertions, including when run against the helper extracted from the freshly built payload. Removing default transfer or stale-menu filtering made the regression suite fail.
- Desktop focused Snapper tests and all eight actual package-staging combinations passed (stable/development recipes, ARM/x86, current source/actual stable pin). Aggregate desktop QA still had three environment-dependent failures; this is not a claim that the entire suite passed.
- Tester drop: `omarchy-mac-apple-silicon-preview-20260907-reinstall-default`. Its `SHA256SUMS` manifest has SHA-256 `5c2dedb1352968cee7422ae9182a82d90e383af7a8a980b801aba83087606e81`. The transfer-volume copy was flushed and every manifest entry verified; older bundles were preserved.
- A fresh M3 (j613) encrypted installation completed provisioning and booted normally. Read-only checks confirmed the new managed default, only the new root's two active menu entries, preserved owning EFI loader, Snapper root configuration, read-only factory snapshot, completed first-run marker, enabled required user services, and no failed system/user units. Installer-slice consumption succeeded and the root grew to approximately 131.7 GiB.
- After desktop package updates, the tester reported another successful reboot, acceptable UI responsiveness, successful 1Password installation, and no repeated first-boot alerts. These final observations are user-reported, not a second post-reboot SSH audit.

The build records a dirty source tree based on `af06c22`; these artifact identities and source comparisons identify what was tested without claiming byte-for-byte reproducibility. This is a successful fresh-install test on one M3, not a release sign-off for every Apple Silicon model. Detailed build, QA, and metal evidence remains in the ignored local audit directory.
