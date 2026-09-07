# Kernel input audit — 2026-09-07

Read-only audit for [managed kernel updates](../plans/managed-kernel-updates.md).
No kernel/image build, package installation, ESP write, or publication was run.
This inventories local evidence; it is not a new hardware validation.

## M3 candidate: source identified, build inputs need reconciliation

| Input | Observed value |
|---|---|
| Source repository | `https://github.com/AsahiLinux/linux.git` |
| Local source checkout | `~/code/research/linux-asahi` |
| Checked-out branch | `asahi-wip-7.2` |
| Commit | `236788cd2602a24c703fe7bdaddaf73ef77d2027` |
| Source modifications | No tracked modifications or untracked files reported by Git; generated/ignored configuration and build products are separate inputs |
| Tested release string | `7.2.2-omarchy-wip72+` |
| Image input | `~/code/research/j613/vmlinuz-wip72` |
| Module input | `~/code/research/j613/modules-tree/7.2.2-omarchy-wip72+` |
| Image compiler metadata | GCC `16.1.1 20260430`, GNU ld `2.46.0` |
| Embedded configuration toolchain | Rust `1.93.1`, Rust LLVM `21.1.8`; full dependency/container provenance not yet recorded |
| Important embedded settings | ARM64, 16 KiB pages, `CONFIG_DRM_APPLE=m`, `CONFIG_USB_DWC3_APPLE=m`, `CONFIG_DM_CRYPT=m`, `CONFIG_BTRFS_FS=m` |
| Release configuration | `CONFIG_LOCALVERSION="-omarchy-wip72"`, localversion-auto disabled; emitted release nevertheless includes `+` |
| Module options | Module version CRCs, module signing, and module compression disabled in the embedded configuration |

The source contains `drivers/gpu/drm/apple/iomfb_v14_7.c` and builds that
implementation into appledrm. The research handoff attributes the M3 display
change to the DT overlay, not a private patch to the display driver. A clean
Git status today cannot prove the complete historical build environment.

### Configuration mismatch discovered during this audit

The image at `arch/arm64/boot/Image`, the saved `vmlinuz-wip72`, and the final
installer's `release/omarchy-mac-iso-usb/vmlinuz-linux-asahi` are byte-identical.
However, extracting the image's embedded config with `scripts/extract-ikconfig`
and comparing it with the current source `.config` reveals exactly one setting:

```diff
-# CONFIG_TYPEC_SN201202X is not set
+CONFIG_TYPEC_SN201202X=m
```

The image is dated September 1; the current config and `sn201202x.ko` are later.
The later module exists under `kernel/drivers/usb/typec/tipd/` in the delivered
module input, and `modules.dep` references it. Its vermagic is
`7.2.2-omarchy-wip72+ SMP preempt mod_unload aarch64`. The earlier saved
`modules-7.2.2-omarchy-wip72+.tar` has no sn201202x module. Thus the old tarball
is not interchangeable with the module tree used for the final installer.
Matching vermagic alone does not establish a coherent full rebuild.

**Packaging decision:** preserve these artifacts as the working baseline, but
build the candidate Image and all modules together from a fresh output directory
with SN201202X enabled. Give that build a new, explicit kernel release identifier.
Do not claim it is byte-identical to the installed test build; retest on j613.

### Content identities

| Content | SHA-256 |
|---|---|
| Tested kernel Image | `056a43cba37909ed686fd2eb771ca374bc2673499f7a3266e03c54cc939830ac` |
| Config extracted from that Image | `cd5a260992d94a1108e17d611e53657bd31c21065b9cce1d52a1b2ccb76f0ea7` |
| Current source `.config` | `77d6560d086d1103d3b3479166800a2feab6b8df259afe1f7074f61903b1f5ce` |
| Later sn201202x module | `2b78d96b8fe122fad36bd5a5e39d130380b68e8ed28466ab10dd2c376d7b8416` |
| appledrm module in supplied tree | `ccbbe4f0b478fd1fb94d9eb37ff79165ed8094336613481f862913cd9aa9629b` |
| dm-crypt module in supplied tree | `7613255074de1a5afc6eacd32d40f599e3596b8708709eb2ef7ff2f9e4f62910` |
| Tracked j613 DCP overlay | `a317ece0e21d2f1b923e91f62350d2b8c90059a5daef2865bee75f9c36e88881` |

The current module tree's sorted regular-file inventory under `kernel/` and
`dtbs/` hashes to `e1b764c4a80a8fdd0b74a21508bcff7cfd9ebce462d370c390ffbb6e9d9d6b39`.
This is the hash of the textual `sha256sum` inventory, not an archive hash:

```bash
# Run from the identified module directory.
find kernel dtbs -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
```

The final build's `BUILD_INFO` records `2026-09-07T16:14:01Z`, the source commit
above, and a dirty installer tree based on `af06c22`. It did **not** include
`linux-asahi.config`: the builder only copies an explicitly supplied config or
`$moddir/build/.config`, which was unavailable in that module tree. Future kernel
packages must require, not optionally collect, their config and source manifest.

## M1/M2 stable candidate: provenance gate still open

Located `~/code/research/j613/modules-7.1.6-1-1-ARCH.tar`. The archive contains a
versioned module/DTB tree, not a complete auditable kernel package recipe.
The exact corresponding 7.1.6 source revision, build config, source patches,
toolchain lock, and package provenance were not established in this audit.

Historical notes record a 7.1.6 M3 simpledrm install and earlier M2 installer
spikes. They do not validate the proposed managed-kernel package/update path on
M1 or M2. Do not label the stable track hardware-approved on that evidence.
Recover the upstream recipe/artifact provenance before building that track;
require new M1 and M2 tests before routine publication.

## Audited installation/update behavior

These observations refer to installer PR #19 revision
`4407c2ddbe75e6732e9709ce320d7d0125ffbf27` and the local artifacts above,
not a claim that all fixes are merged into `main`.

- `builder/build-rootfs.sh` excludes `linux-asahi`, `asahi-scripts`, `m1n1`,
  and `uboot-asahi` from pacstrap, then copies a selected module directory.
- The image builder uses one kernel selection and builds three initrds:
  live overlay, encrypted installed root, and plain installed root.
- Both the rootfs builder and `disable_unmanaged_mkinitcpio` remove the old
  linux-asahi preset and rename the standard mkinitcpio install/remove hooks.
  The desktop's placeholder `/etc/mkinitcpio.conf` is not the authoritative
  installed-image recipe.
- System-ESP installs mount it at `/boot/efi` and copy boot files into
  `EFI/omarchy/<root-uuid>/`. The managed aggregate currently **concatenates**
  root fragments; changing a fragment alone does not change the active menu.
- The existing normal and verbose entries use the same kernel and initrd.
  The verbose entry is not a previous-kernel recovery option.
- Wipe-USB installations have a different ESP-root layout. Supporting the
  System-ESP path alone must not be presented as covering that layout.
- The ARM repository already has native ARM workflows and shared publication
  serialization. Its generic publisher deletes package assets absent from the
  resulting database. It has no kernel-specific build, promotion, or recovery
  retention contract yet.

## Guardrails for subsequent work

Read only open-source kernel code, configuration, and permitted hardware
interface data. Do not inspect or redistribute the research firmware dumps.
Do not bundle `boot.bin`, vendor firmware, or a complete machine-specific DTB.
The existing tracked j613 overlay remains a separate installer prerequisite;
routine kernel updates must not rewrite even that DTB slot.

Evidence sources: the files/functions named above,
[the provisioning validation at the audited installer revision](https://github.com/omarchy-mac/omarchy-mac-iso/blob/4407c2ddbe75e6732e9709ce320d7d0125ffbf27/docs/provisioning-validation-20260907.md), and the
local research handoff. Upstream build reproducibility requirements are described
in the [Linux kernel documentation](https://docs.kernel.org/kbuild/reproducible-builds.html).
No new binary reproducibility or hardware-compatibility claim is made here.
