# Changelog

This fork of [paolo-de-marinis/omen-acpi](https://github.com/paolo-de-marinis/omen-acpi)
drops the original CachyOS and Limine installer. `omen-acpi` now installs the
upstream S5 DSDT override as a rEFInd menu entry on a Debian-based system.

The menu title defaults to `Pop!_OS (omen-acpi s5 fix)` and can be changed
with `--title` on `install` and `repair`.
