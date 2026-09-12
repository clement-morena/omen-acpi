# rEFInd companion for the 16-ap0056nf

This page is for this checkout only. It is not part of the v2.4.0 release
archive, and it does not make the retail SKU a validated machine.

Do **not** run `omen-acpi`, `install.sh`, `update.sh`, `uninstall.sh`, or
`scripts/03-manage-limine-entry.sh` on this laptop. Those paths install Limine
entries for CachyOS. This machine boots with rEFInd 0.13.2. systemd-boot is
still present in NVRAM and is not the current boot. Windows Boot Manager is on
a different EFI partition and is not touched.

## What the companion writes

`scripts/06-refind-s5.sh` reuses `scripts/01-collect-acpi.sh` and
`scripts/02-build-dsdt.sh` unchanged. Those scripts fail closed if the stock
DSDT header, `_PTS` body, or `WQBZ` loops do not match the reference firmware.
The companion does not loosen those checks and does not build the combined
variant.

If the anchors match, install writes only:

- `/boot/omen-acpi/s5-early.cpio`, an uncompressed CPIO whose first table is
  `kernel/firmware/acpi/DSDT.aml`
- `/boot/omen-acpi/s5-initrd.img`, that CPIO concatenated in front of a copy of
  the stock initrd
- `/boot/omen-acpi/s5-manifest.txt`
- one marked block appended to `/boot/efi/EFI/refind/refind.conf`

The stanza is pinned to the kernel that is running at install time. rEFInd
0.13 keeps only one `initrd` token, and a second line replaces the first, so
the stanza names one file: `/boot/omen-acpi/s5-initrd.img`. That file is the
uncompressed ACPI CPIO concatenated in front of a copy of the stock initrd.
The stock initrd itself is not modified. The stanza copies the first option
string from `/boot/refind_linux.conf` and does not edit that file. Editing
`refind_linux.conf` would apply the override to every auto-detected kernel.

It does not change `default_selection`, `timeout`, scan options, NVRAM boot
order, the stock kernel, the stock initrd, the BIOS, or the Windows EFI
partition. A one-time copy of `refind.conf` is kept at
`/boot/efi/EFI/refind/refind.conf.omen-acpi-s5-before` and is not deleted by
removal.

Private source and build archives stay under
`${XDG_DATA_HOME:-$HOME/.local/share}/omen-acpi-refind`. They are
machine-derived firmware data. Do not publish them.

## Install

Install `acpica-tools` first if `acpidump`, `acpixtract`, or `iasl` is missing.
The companion does not install packages itself.

Boot the normal rEFInd Linux icon, not a test stanza, then:

```bash
./scripts/06-refind-s5.sh install
```

Run that as the normal user. It asks for confirmation, then for `sudo` only
when it writes the boot files. Reboot and select
`Pop!_OS (omen-acpi s5 test)` once. Do not make that stanza the default.

## Stock return

The normal auto-detected Linux icon still uses `/boot/refind_linux.conf` and
the stock initrd. Select that icon to boot the firmware DSDT again.

rEFInd can remember the last selection. After a test boot, the next unattended
boot may return to the test stanza. Pick the normal icon again. Do not assume
the menu default stayed put.

The test stanza does not follow a later kernel, Pop!_OS, or NVIDIA package.
See below. The auto-detected icon keeps booting stock.

## Repair

`repair` keeps the override already in `/boot/omen-acpi/s5-early.cpio`. It
does not collect a new DSDT. It concatenates that file in front of a copy of
the running kernel's stock initrd and rewrites only the owned stanza so it
has one `initrd` line.

Boot the normal Linux icon first, as the normal user. `repair` refuses to
run from the test stanza, and it refuses unless the BIOS is still `F.13`.
If the early CPIO is missing, run `install`, not `repair`.

Use it only in these two cases:

- The test icon booted the firmware DSDT. rEFInd 0.13 keeps one `initrd`
  token, so a stanza with two `initrd` lines never loaded the override.
- The NVIDIA driver was updated and the kernel did not change. The driver
  package rebuilds `/boot/initrd.img-*`. The test file is a separate copy
  and still contains the old module.

```bash
./scripts/06-refind-s5.sh repair
```

Reboot, select `Pop!_OS (omen-acpi s5 test)`, then confirm the override:

```bash
journalctl -k -b | grep 'ACPI: DSDT'
```

The OEM revision must be `0107200A`. Then select the normal icon again.

Do not use `repair` after a BIOS change, a Pop!_OS upgrade, or a kernel
update. Those use `remove`.

## Pop!_OS, kernel, and driver updates

Do not run `update.sh`. The normal icon follows package updates. The test
stanza stays pinned to the kernel and to the initrd copy made by `install`
or `repair`.

Before a Pop!_OS update or a kernel update, boot the normal icon and run
`remove`. Update through Pop Shop or `apt`. Reboot into the normal icon.
Install again later only if you still want the test and the BIOS is still
`F.13`. If the update also installs a new kernel, or you are not sure,
treat it as a kernel update and `remove` first.

A driver-only update does not change the DSDT. Boot the normal icon, install
the driver through Pop Shop or `apt`, and reboot into the normal icon if the
package asks for it. Then run `repair`. Do not select the test icon between
the driver update and `repair`. That boot would load the old NVIDIA module
from the copied initrd against the new userspace driver.

## Removal

From the normal Linux icon:

```bash
./scripts/06-refind-s5.sh remove
```

That deletes the marked stanza, `/boot/omen-acpi/s5-early.cpio`,
`/boot/omen-acpi/s5-initrd.img`, and `/boot/omen-acpi/s5-manifest.txt`. It
does not rewrite the rest of `refind.conf`, and it does not delete
`refind.conf.omen-acpi-s5-before`.

## NVIDIA 580 is not the measured case

The hardware observation that `NVDE` is re-armed after S3 was made with NVIDIA
Open kernel module 610 on the OMEN MAX 16-ap0006sl. This laptop uses NVIDIA
Open 580. Neither implemented ACPI variant writes `NVDE`. If `NVDE` is not 1,
`PG00._OFF()` returns without powering the GPU off even when the DSDT override
loads. That is a boot-test observation, not a reason to add an `NVDE` write.

The retail SKU is 16-ap0056nf (`D3SG2EA#ABF`). The DMI product, board `8E35`,
and BIOS `F.13` match the reference strings. That is not a physical validation
of this chassis.
