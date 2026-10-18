# OMEN ACPI Toolkit

This repository is a fork of
[paolo-de-marinis/omen-acpi](https://github.com/paolo-de-marinis/omen-acpi).
The original project builds a checked DSDT override for an HP OMEN shutdown
problem and installs it as a Limine entry on CachyOS. This fork keeps that
project's DSDT collector and S5 builder, and installs the override as a rEFInd
menu entry on a Debian-based system.

On this machine the distribution is Pop!_OS. The same command is intended to
work on other Debian-based systems that boot with rEFInd, within the limits
below.

The change is the upstream S5 override: during shutdown, `_PTS(5)` sets
`PEGP.OMPR = 3` and calls `PEGP._PS3()`, which is the firmware path that can
reach `PG00._OFF()`. It does not write `NVDE`, flash the BIOS, or edit
`refind_linux.conf`. The upstream measurement of that path used NVIDIA Open
610 on an OMEN MAX 16-ap0006sl. This checkout's retail SKU is 16-ap0056nf with
NVIDIA Open 580. Matching DMI strings are not a physical validation of this
chassis. Details are in [`docs/nvde-analysis.md`](docs/nvde-analysis.md) and
[`patches/README.md`](patches/README.md).

## Requirements

- A Debian-based system. `/etc/os-release` `ID` or `ID_LIKE` must include
  `debian` or `ubuntu`. Pop!_OS matches through `ID_LIKE="ubuntu debian"`.
- rEFInd, with `/boot/efi/EFI/refind/refind.conf` and
  `/boot/refind_linux.conf`.
- This firmware identity: product `OMEN Gaming Laptop 16-ap0xxx`, board
  `8E35`, BIOS `F.13`, NVIDIA GPU at `0000:01:00.0`.
- Secure Boot disabled, and `mokutil` installed.
- `acpica-tools` (`acpidump`, `acpixtract`, `iasl`), Python 3, and `cpio`.
- A kernel with `CONFIG_ACPI_TABLE_UPGRADE=y`.
- Regular files `/boot/vmlinuz-<version>` and `/boot/initrd.img-<version>`
  on the root filesystem, not on a separate `/boot` partition.
- The normal rEFInd Linux icon as the current boot, so `/proc/cmdline` has
  exactly one `initrd=` token and it names that stock initrd.

Run the command from a checkout of this repository, as your normal user. It
asks for confirmation, then for `sudo` only when it writes boot files.

## Where it stops

`omen-acpi` exits before it changes boot files when any of these is true:

- The system is not Debian-based, as defined above.
- The current boot is GRUB or systemd-boot, or rEFInd's files are not at the
  paths above.
- `/boot/refind_linux.conf` is missing, its first option line is not a quoted
  description and option pair, or that option string already contains
  `initrd=`.
- Secure Boot is enabled, or `mokutil` is missing.
- `/boot` is a separate partition. Encrypted Debian and Ubuntu installs often
  use that layout.
- The versioned kernel or initrd is missing or is a symlink.
- The running command line does not have exactly one `initrd=` pointing at
  the stock initrd. Boot the normal rEFInd icon first.
- The kernel config cannot prove `CONFIG_ACPI_TABLE_UPGRADE=y`.
- The product, board, or BIOS differs from the identity above.
- The stock DSDT header, `_PTS` body, or `WQBZ` loops do not match the
  reference firmware.
- The NVIDIA device is not at `0000:01:00.0`.

## Install

Boot the normal rEFInd Linux icon, then:

```bash
./omen-acpi install
```

To use another menu name:

```bash
./omen-acpi install --title "Ubuntu (omen-acpi s5 fix)"
```

The default name is `Pop!_OS (omen-acpi s5 fix)`. Install appends the running
kernel version to that name, including when `--title` is set. For kernel
`7.1.5-76070105-generic` the entry is
`Pop!_OS (omen-acpi s5 fix) 7.1.5-76070105-generic`.

Install writes:

- `/boot/omen-acpi/s5-early.cpio`
- `/boot/omen-acpi/s5-initrd.img`, the ACPI CPIO followed by a copy of the
  stock initrd
- `/boot/omen-acpi/s5-manifest.txt`, including the menu title
- one marked block at the end of `/boot/efi/EFI/refind/refind.conf`

rEFInd keeps a single `initrd` token, so the stanza names `s5-initrd.img`.
The stock kernel, the stock initrd, `refind_linux.conf`,
`default_selection`, the timeout, scan options, NVRAM, and the Windows EFI
partition stay as they are. A one-time copy of `refind.conf` is kept at
`/boot/efi/EFI/refind/refind.conf.omen-acpi-s5-before`.

Reboot and select the new menu entry once. Then select the normal Linux icon
again. rEFInd can remember the last selection.

Confirm the override:

```bash
./scripts/check-dsdt-revision.sh
```

The script reads the current boot's kernel log and exits successfully only
when the loaded DSDT OEM revision is `0107200A`. The terminal prints
`matching` or `not matching`. A mismatch also raises a desktop notification
that stays until it is closed. The revision result is the same when a
notification cannot be shown. `OMEN_ACPI_NOTIFY=0` skips the notification.

`install` asks whether to run that check at each graphical login. Answering
yes writes `~/.config/autostart/omen-acpi-dsdt-check.desktop`. `remove`
deletes that entry. `status` reports whether it is enabled.

Private firmware archives stay in
`${XDG_DATA_HOME:-$HOME/.local/share}/omen-acpi-refind`. Do not publish them.

## Status

```bash
./omen-acpi status
```

This reports whether the marked stanza, the early CPIO, and the manifest are
present, whether the current boot used `s5-initrd.img`, and whether the
login revision check is enabled. An enabled check names the script it runs.

## Repair and updates

`repair` keeps the DSDT override already in `s5-early.cpio`. It concatenates
that file in front of a copy of the running kernel's stock initrd and
rewrites the owned stanza. It refuses to run from the test entry, and it
refuses unless the BIOS is still `F.13`.

```bash
./omen-acpi repair
./omen-acpi repair --title "Ubuntu (omen-acpi s5 fix)"
```

Without `--title`, `repair` reuses the `TITLE=` line in the manifest. With
`--title`, it uses that name plus the running kernel version.

| Change | What to do |
| --- | --- |
| NVIDIA driver only, same kernel | Boot the normal icon, install the driver, reboot to the normal icon if the package asks, then run `./omen-acpi repair`. Do not select the override entry until `repair` has finished. |
| Kernel or distribution upgrade | Boot the normal icon, run `./omen-acpi remove`, update, reboot to the normal icon. Run `./omen-acpi install` again only if you still want the override and the BIOS is still `F.13`. |
| BIOS change | Run `./omen-acpi remove`. The command refuses to continue unless the BIOS is still `F.13`. |

## Remove

From the normal Linux icon:

```bash
./omen-acpi remove
```

That deletes the marked stanza, `/boot/omen-acpi/s5-early.cpio`,
`/boot/omen-acpi/s5-initrd.img`, and `/boot/omen-acpi/s5-manifest.txt`. It
also deletes the login check
`~/.config/autostart/omen-acpi-dsdt-check.desktop` when install created it.
It leaves the rest of `refind.conf` in place, and it does not delete
`refind.conf.omen-acpi-s5-before`.
