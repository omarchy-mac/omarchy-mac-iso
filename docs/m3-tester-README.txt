Omarchy on Apple Silicon — installer preview
==============================================

This is an early Omarchy installer for Apple Silicon. It is not an ISO.
Do not dd omarchy-mac-usb.img onto the internal SSD.

This preview separates three different results:

  Installs   The live environment boots, the installer finishes, first
             boot succeeds, and macOS / Recovery remain intact.
  Usable     Keyboard, trackpad, networking, USB, audio, and the desktop
             are usable enough for ordinary testing.
  Enhanced   The machine has board-specific features beyond the generic
             fallback, currently full-resolution DCP display support.

The installer is intended for supported Apple Silicon machines, not only
M3. This test campaign starts with M3 because that is where support is
least proven. The j613 work is not a prerequisite for installation: it
enables the better display path on the 13-inch M3 Air. Other M3 machines
should fall back to simpledrm and CPU composition until their DCP data is
added. There is no AGX 3D acceleration on M3 yet.

Current compatibility evidence
------------------------------

  Machine                         Board    Installs       Usable         Enhanced
  M1 family                      various  needs retest   needs retest   upstream Asahi path
  M2 family                      various  needs tester   needs tester   upstream Asahi path
  13-inch MacBook Air (M3)        j613     confirmed      confirmed      DCP display
  15-inch MacBook Air (M3)        unknown  needs tester   needs tester   simpledrm expected
  14-inch MacBook Pro (M3)        unknown  needs tester   needs tester   simpledrm expected
  MacBook Pro (M3 Pro / M3 Max)   j514s*   needs tester   needs tester   simpledrm observed*
  iMac (M3)                       unknown  needs tester   needs tester   simpledrm expected

* A j514s Fedora hardware dump confirms baseline simpledrm boot. It does
  not yet count as an Omarchy installation or usability result.

The M1/M2 rows mean the installer has no deliberate M3-only runtime gate;
they are not yet metal results for this exact image. M3 Ultra (Mac Studio)
is not in scope for this first drop.

The most useful result is a matched pair of validation bundles: one from
the live environment before installation and one after first boot. A
simpledrm result is useful, not a failure.

You will wipe the Linux slice only. macOS, Recovery, and the Asahi EFI
(m1n1) stay. If you are not willing to do that, stop here.


0. What should be in this folder
--------------------------------
  payload.img.zst
  vmlinuz-linux-asahi
  initramfs-omarchy-usb.img
  initramfs-linux-asahi.img
  BOOTAA64-NVME.EFI
  grub-nvme-installer.cfg
  place-nvme-installer.sh
  BUILD_INFO
  SHA256SUMS
  README.txt (this file)
  ADT-DUMP.txt           optional private m1n1 ADT capture (second computer)
  src/                   kernel config, DCP overlay, dump scripts

Required: initramfs-linux-asahi-plain.img. The installer offers both encrypted
and unencrypted roots and refuses an unencrypted install without this file.

Verify the drop before using it:

  shasum -a 256 -c SHA256SUMS

On the Mac: brew install zstd   (the placer decompresses payload.img.zst)


1. Asahi UEFI-only (macOS), if you do not already have it
---------------------------------------------------------
A Mac that has never run the Asahi installer cannot boot this. iBoot
will not load our GRUB until m1n1 is on the internal EFI.

Use the current Asahi installer instructions and choose **UEFI environment
only**. Do not install Fedora or Alarm as the OS. Let it put firmware on
the ESP (m1n1, vendorfw, asahi). Shrink APFS in macOS so you have a
**hole of free space** for Linux. Aim for roughly twice the payload plus
slack — about 30 GB or more, and more for a useful Omarchy root.

If Linux is already in that hole from an earlier experiment, you can
turn **only** that Linux/LUKS slice back into free space:

  diskutil list disk0
  sudo diskutil eraseVolume free none disk0sN

N is the Linux identifier you just wrote down. Never eraseDisk. Never
touch APFS, Recovery, iBoot, or the roughly 500 MB EFI that has m1n1/.


2. Place the Omarchy installer (still macOS)
--------------------------------------------
Put the files from this folder in one directory, cd there, and dry-run
first:

  sudo ./place-nvme-installer.sh \
    --payload ./payload.img.zst \
    --esp-files .

You should see a plan like: hole in front, omarchy-install at the tail,
then Recovery. If that looks right:

  sudo ./place-nvme-installer.sh \
    --payload ./payload.img.zst \
    --esp-files . \
    --confirm

The script will not mklabel the disk. On the internal SSD, gpt add is
EPERM from macOS, so it uses diskutil instead. dd is only onto the new
slice, never rdisk0 or the whole disk. It copies live GRUB next to m1n1/;
m1n1, vendorfw, and asahi must stay byte-identical.

If this ESP already boots an installation made by omarchy-mac, the placer
leaves its grub.cfg and custom.cfg in place and saves its GRUB executable.
The live system temporarily uses a separate NVMe-only EFI embed, marker,
config, kernel, and initrds. After installation the original EFI executable
is restored and the new UUID root is added through custom.cfg. The old menu
and its default remain owned by the old installation. Its
/vmlinuz-linux-asahi and /initramfs-linux-asahi.img are not overwritten.

For an installer-managed default, a free-space reinstall detects when the
previous root was erased in macOS and makes the new root the default.
Confirmed-absent generated roots are omitted from the active menu; their
saved fragments and kernels are retained. A still-present root, including
a locked encrypted root, keeps its default. Customized/foreign boot menus
remain under their original owner's control.


3. Boot and capture the pre-install result
------------------------------------------
Shut down, then power on. A warm reboot often misses Type-C. You do not
need a USB stick if placement succeeded: U-Boot should load NVMe
EFI/BOOT/BOOTAA64.EFI.

If the machine already had Linux on NVMe, interrupt U-Boot so the old
NVMe GRUB does not win. Do not saveenv.

Before installing, run:

  sudo omarchy-mac-validate --phase pre-install

Keep the tarball path it prints. The bundle is read-only and sanitized
by default: no hostname, MAC address, filesystem UUID, raw device tree,
or raw boot.bin is included.


4. Install and capture the post-install result
----------------------------------------------
In the live TUI choose **Install into free space**: the hole in front of
the installer slice. Do not choose replace-existing or wipe USB for this
layout. Reinstall-existing and write-GRUB are disabled while booted from
omarchy-install so a wrong choice cannot borrow the installed OS's kernel or
leave NVMe-live GRUB active.

Encryption is recommended. It uses the desktop user's password. Confirm
the review table carefully.

M3 Type-C: if a USB device does not appear, unplug it and plug it back in
after the desktop or live session is up.

First boot of the new root should delete only the temporary
omarchy-install slice and grow into that space. If `lsblk` shows the
LUKS partition larger than the btrfs inside it, run:

  sudo cryptsetup resize root
  sudo btrfs filesystem resize max /

After logging in, run:

  sudo omarchy-mac-validate --phase post-install

Send both validation tarballs and answer the short manual checklist in
the post-install bundle. In particular, say whether macOS still boots.

Multiple Omarchy roots are supported. Each root gets a UUID-specific
kernel and initramfs directory on the ESP and its own GRUB menu fragment.
A free-space install keeps the existing Omarchy root as the default. For
the safest M2 trial, keep the existing installation, create a second
unallocated hole in macOS, and choose **Install into free space**. Do not
choose reinstall/replace. Back up important data before any metal test.

Do not run omarchy-system-boot-to-esp from the new shared-ESP root. Its kernel
and initramfs are pinned to the installer copy until a UUID-private update hook
exists; do not install or update linux-asahi there yet.

If the placer refuses an old-style NVMe-live layout, stop. Do not merely remove
/omarchy-usb-live: that older placer also replaced GRUB files. Restore the
intended installed EFI executable and GRUB configuration from a known ESP
backup, verify it boots, and only then remove the obsolete marker and retry.


5. Hardware-only reports from another Linux distribution
----------------------------------------------------------
If you are not installing yet, or are booted in Fedora or another Linux,
copy src/omarchy-mac-dump-board to the machine and run:

  sudo bash src/omarchy-mac-dump-board

The default bundle is read-only and sanitized. It records board/model,
the graphics path, USB/Type-C state, and an m1n1 DTB-slot index. It does
not include raw boot.bin or raw device trees.

Only when a developer explicitly needs those files, run:

  sudo bash src/omarchy-mac-dump-board --raw-private

That opt-in archive can contain unique hardware identifiers. Treat it as
private and do not attach it to a public issue.

If the panel uses simpledrm, we may also request an ADT capture. It needs
a second Linux computer and a data-capable USB-C cable. This is optional,
always private, and described in ADT-DUMP.txt.


6. What a useful result looks like
----------------------------------
For every Apple Silicon board we want to record the three levels independently:

  Installs: yes / no, including whether first boot consumed the temporary
            installer slice without changing Apple partitions.
  Usable:   keyboard, trackpad, Wi-Fi, Bluetooth, audio, USB ports,
            suspend/resume, and desktop responsiveness.
  Enhanced: apple-drm and the panel's native modes, or simpledrm fallback.

On j613, a good enhanced result is apple-drm at roughly 2560x1664 with
the notch exposed. On every other M3, a successful simpledrm installation
is still a valuable baseline result.
