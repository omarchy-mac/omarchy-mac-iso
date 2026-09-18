# Handoff and reclaim contract

Three stages install Omarchy on an Apple Silicon internal disk without a USB stick: **place** writes a temporary installer slice from macOS, **install** copies the system into the space in front of it, **reclaim** deletes the slice on first boot and grows the root into it. Handoff is the state one stage leaves for the next.

MUST, MUST NOT, and MAY are used as in RFC 2119. Rules are numbered (S-, H-, P-, I-, R-) so scripts and tests can cite them.

## Terms

- **Installer slice** — the GPT partition holding the live payload (btrfs, label `OMARCHYLIVE`), GPT name `omarchy-install`.
- **Hole** — unallocated GPT space in front of the installer slice.
- **Apple partitions** — APFS, iBoot, Recovery, and the ESP firmware trees `m1n1/`, `vendorfw/`, `asahi/`.
- **New root** — the Omarchy partition created by install.

## Handoff

Stage handoff uses these artifacts:

- H1. GPT name `omarchy-install` on the installer slice.
- H2. A package-owned reclaim helper and `omarchy-mac-consume-installer.service`, enabled in the new root (`multi-user.target`). The installer MUST only enable the vendor unit and write transaction state; it MUST NOT generate or overwrite the packaged helper or unit. Goal vs today: the installer copies the helper to `/usr/local/sbin` and the unit to `/etc/systemd/system`.
- H3. A versioned prepared-install manifest on the System ESP, at a path and with a schema agreed by the macOS producer and Linux consumer owners before implementation. It MUST identify the disk and installer slice by stable identifiers, record their expected GPT geometry, and contain SHA-256 digests for the payload and ESP artifacts. Unsupported schema versions MUST refuse. It MUST NOT contain passwords, password hashes, recovery keys, or other secrets. Goal vs today: the placer does not emit this manifest and the Linux installer does not consume it yet.

The ESP live marker and boot files select the boot path; they are not authority to identify a partition for mutation. Reclaim MAY keep private durable progress in the new root. That progress is internal state, not a producer-to-consumer handoff artifact, and MUST NOT contain secrets.

## Shared rules

- S1. Apple partitions MUST NOT be shrunk, erased, reformatted, or deleted. `m1n1/`, `vendorfw/`, and `asahi/` MUST be hash-identical after every stage.
- S2. Unclear or non-unique identity MUST refuse. No stage deletes by disk position, size, or elimination.
- S3. The unlock password MUST NOT be written anywhere: macOS, ESP, logs, installer slice.
- S4. Once H3 is implemented, every mutating stage MUST validate the manifest schema version, artifact digests, disk identity, PARTUUIDs, and expected geometry before its first mutation. Reclaim MUST re-check the identity and geometry expected for its current durable stage before each later mutation.

## Stage 1 — Place (macOS)

Preconditions: Asahi UEFI-only provision done (ESP has `m1n1/`). One GPT hole at least payload plus reserve in size.

Rules:

- P1. The installer slice MUST sit at the tail of the hole. The space in front MUST stay unallocated.
- P2. Only the payload image MUST be written to the slice, at the disk's native block size. The full USB image MUST NOT be written.
- P3. GPT name `omarchy-install` MUST be attempted. An empty name is acceptable; any other name is not.
- P4. The placer MAY replace `EFI/BOOT/BOOTAA64.EFI` and add kernels and initrds to the ESP. S1 holds.
- P5. The placer MUST dry-run unless `--confirm` is given.

Postconditions: `[hole] [installer slice] [Recovery]`. Payload on the slice. Live GRUB on the ESP.

## Stage 2 — Live install

Preconditions: booted from the installer slice on NVMe.

Rules:

- I1. On boot, the slice MUST be named `omarchy-install` if macOS left it empty (H1).
- I2. Install MUST target the hole only. The running slice MUST NOT be a target.
- I3. The new root MUST be LUKS with label `OMARCHYROOT`, unlocked by the user password. Goal vs today: the TUI still offers unencrypted with encryption as the default.
- I4. ESP mode: piggyback (`custom.cfg` only; `BOOTAA64.EFI` hash unchanged) when another loader owns `BOOTAA64.EFI`; own when none exists or the placer wrote it.
- I5. The reclaim service MUST be enabled in the new root (H2). Install MUST NOT delete the slice or grow.

Postconditions: encrypted root in the hole. Bootloader points at it. Installer slice present and named. Service enabled.

## Stage 3 — Reclaim (first boot)

Preconditions: root on NVMe. `/omarchy-mac-overlay-write` absent.

Rules:

- R1. While reclaim is incomplete, the target is exactly one partition on the root's disk with GPT name `omarchy-install`. Zero or multiple matches MUST refuse except for the R2 fallback or a durable stage at or after `installer-deleted`. The target MUST NOT be the running root, mounted, or an Apple partition type.
- R2. Fallback: when no partition has that name, a partition with filesystem label `OMARCHYLIVE` that is not the root MAY be named `omarchy-install` first. R1 still gates the delete. Goal vs today: the goal is exactly one candidate, else refuse; the code takes the first match.
- R3. The root MUST grow only into the hole the delete left, then `cryptsetup resize` if LUKS, then `btrfs filesystem resize max`. It MUST NOT grow to end of disk.
- R4. Before the first mutation, reclaim MUST durably snapshot every APFS, iBoot, Recovery, and System ESP GPT entry's PARTUUID, type GUID, start, end, size, attributes, and relative ordering. It MUST compare the current entries with that snapshot before and after every later mutation. Those fields MUST remain identical; any difference fails the run. Goal vs today: the current snapshot records only the kernel device name and type GUID.
- R5. Reclaim MUST record progress atomically in the new root using these durable stages: `validated`, `installer-deleted`, `partition-grown`, `luks-grown`, `btrfs-grown`, and `complete`. On every run it MUST verify observed disk state against the recorded stage and continue at the first incomplete stage. If an interruption completed the next mutation before its stage was recorded, reclaim MUST verify that exact expected result, advance the durable stage, and continue. Any other contradiction MUST refuse. It MUST NOT infer completion merely because `omarchy-install` is absent. Goal vs today: reclaim has no durable progress record.

Postconditions: no `omarchy-install` on the disk. GPT root, LUKS mapping when present, and btrfs all grown. Durable stage `complete`. Service disabled. A re-run MUST converge to these postconditions; it is a no-op only when they are already satisfied.
