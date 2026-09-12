#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Repository-only companion for one Pop!_OS machine that already boots with
# rEFInd. It is not part of the Limine toolkit and it is not a public
# omen-acpi command.
#
# It reuses scripts/01-collect-acpi.sh and scripts/02-build-dsdt.sh unchanged.
# Those two commands fail closed if the stock DSDT header, _PTS body, or WQBZ
# loops do not match. This file does not loosen those checks, and it never
# calls omen-acpi, install.sh, or the Limine entry manager.
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly COLLECT="$SCRIPT_DIR/01-collect-acpi.sh"
readonly BUILD="$SCRIPT_DIR/02-build-dsdt.sh"
readonly STANZA_PY="$SCRIPT_DIR/refind_stanza.py"

readonly EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
readonly EXPECTED_BOARD="8E35"
readonly EXPECTED_BIOS="F.13"
readonly EXPECTED_NVIDIA_BDF="0000:01:00.0"
readonly S5_OEM_REVISION="0x0107200A"

readonly REFIND_CONF="/boot/efi/EFI/refind/refind.conf"
readonly REFIND_LINUX_CONF="/boot/refind_linux.conf"
readonly PAYLOAD_DIR="/boot/omen-acpi"
readonly EARLY_CPIO="$PAYLOAD_DIR/s5-early.cpio"
readonly COMBINED_INITRD="$PAYLOAD_DIR/s5-initrd.img"
readonly MANIFEST="$PAYLOAD_DIR/s5-manifest.txt"
readonly CONF_BACKUP="/boot/efi/EFI/refind/refind.conf.omen-acpi-s5-before"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

usage() {
    cat <<'EOF'
Usage: scripts/06-refind-s5.sh {install|repair|status|remove}

Pop!_OS / rEFInd companion for the S5-only DSDT override. This is not omen-acpi.

  install   Collect this machine's DSDT, build the s5 variant, and append one
            non-default rEFInd manual stanza. Does not edit refind_linux.conf.
  repair    Keep the existing override and rewrite the stanza so rEFInd 0.13
            actually loads it. A second initrd line is ignored by that version.
  status    Show whether the stanza and early CPIO are present.
  remove    Delete the marked stanza and /boot/omen-acpi/s5-early.cpio.

Do not run omen-acpi, install.sh, or scripts/03-manage-limine-entry.sh on this
machine. Those paths install Limine entries.

Stock return is the normal auto-detected Linux icon. rEFInd may remember the
last selection, so after a test pick that icon again. This companion does not
change default_selection, the menu timeout, scan options, or NVRAM boot order.
EOF
}

read_text() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] || die "Unreadable file: $path"
    tr -d '\r' < "$path"
}

dmi_value() {
    local path="$1" value
    [[ -r "$path" && ! -L "$path" ]] || die "DMI value is unreadable: $path"
    value="$(tr -d '\r\n' < "$path")"
    [[ -n "$value" && "$value" != *$'\n'* ]] || die "DMI value is empty: $path"
    printf '%s\n' "$value"
}

check_identity() {
    local product board bios
    product="$(dmi_value /sys/class/dmi/id/product_name)"
    board="$(dmi_value /sys/class/dmi/id/board_name)"
    bios="$(dmi_value /sys/class/dmi/id/bios_version)"
    [[ "$product" == "$EXPECTED_PRODUCT" \
        && "$board" == "$EXPECTED_BOARD" \
        && "$bios" == "$EXPECTED_BIOS" ]] \
        || die "This companion only runs on ${EXPECTED_PRODUCT}, board ${EXPECTED_BOARD}, BIOS ${EXPECTED_BIOS} (found ${product} / ${board} / ${bios})"
}

check_gpu() {
    local vendor="/sys/bus/pci/devices/${EXPECTED_NVIDIA_BDF}/vendor"
    [[ -r "$vendor" ]] || die "NVIDIA GPU is not visible at ${EXPECTED_NVIDIA_BDF}"
    [[ "$(tr -d '[:space:]' < "$vendor")" == "0x10de" ]] \
        || die "Unexpected PCI vendor at ${EXPECTED_NVIDIA_BDF}"
}

check_table_upgrade() {
    local config="/boot/config-$(uname -r)"
    if [[ -r /proc/config.gz ]]; then
        need_cmd gzip
        gzip -dc /proc/config.gz | grep -qx 'CONFIG_ACPI_TABLE_UPGRADE=y' \
            || die "Running kernel does not have CONFIG_ACPI_TABLE_UPGRADE=y"
        return
    fi
    [[ -r "$config" ]] || die "Cannot read kernel config to prove CONFIG_ACPI_TABLE_UPGRADE=y"
    grep -qx 'CONFIG_ACPI_TABLE_UPGRADE=y' "$config" \
        || die "Running kernel does not have CONFIG_ACPI_TABLE_UPGRADE=y"
}

check_secure_boot() {
    local state
    need_cmd mokutil
    state="$(mokutil --sb-state 2>/dev/null || true)"
    [[ "$state" == *"SecureBoot disabled"* ]] \
        || die "Secure Boot must be disabled; the override initrd is not signed"
}

kernel_version() {
    local version
    version="$(uname -r)"
    [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Refusing unusual kernel version: ${version}"
    printf '%s\n' "$version"
}

partuuid_of() {
    local source="$1" name uevent value
    name="$(basename -- "$source")"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unexpected block device name: ${source}"
    uevent="/sys/class/block/${name}/uevent"
    [[ -r "$uevent" ]] || die "Cannot read PARTUUID for ${source}"
    value="$(awk -F= '$1 == "PARTUUID" { print $2 }' "$uevent")"
    [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || die "PARTUUID missing or invalid for ${source}"
    printf '%s\n' "$value"
}

volume_layout() {
    local version="${1-}" kernel_file initrd_file mount source partuuid
    local loader stock_rel early_rel cmdline_initrd
    version="${version:-$(kernel_version)}"
    kernel_file="/boot/vmlinuz-${version}"
    initrd_file="/boot/initrd.img-${version}"
    [[ -f "$kernel_file" && ! -L "$kernel_file" ]] || die "Kernel is missing or is a symlink: ${kernel_file}"
    [[ -f "$initrd_file" && ! -L "$initrd_file" ]] || die "Initrd is missing or is a symlink: ${initrd_file}"

    mount="$(findmnt -no TARGET -T "$kernel_file")"
    source="$(findmnt -no SOURCE -T "$kernel_file")"
    [[ -n "$mount" && -n "$source" && "$source" != *"["* ]] \
        || die "Cannot identify the filesystem that contains ${kernel_file}"
    [[ "$(findmnt -no SOURCE -T "$initrd_file")" == "$source" ]] \
        || die "Kernel and initrd are not on the same volume"
    [[ "$(findmnt -no SOURCE -T /boot)" == "$source" ]] \
        || die "/boot is not on the same volume as the kernel"

    partuuid="$(partuuid_of "$source")"
    loader="/$(realpath --relative-to="$mount" "$kernel_file")"
    stock_rel="$(realpath --relative-to="$mount" "$initrd_file")"
    early_rel="$(realpath --relative-to="$mount" "$EARLY_CPIO" 2>/dev/null || true)"
    if [[ -z "$early_rel" ]]; then
        early_rel="$(python3 - "$mount" "$EARLY_CPIO" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)"
    fi
    [[ "$early_rel" != .. && "$early_rel" != ../* ]] \
        || die "Early CPIO would not live on the kernel volume: ${EARLY_CPIO}"

    cmdline_initrd="$(awk '{
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^initrd=/) {
                print substr($i, 8)
                count++
            }
        }
        if (count != 1) exit 1
    }' /proc/cmdline)" || die "Expected exactly one initrd= token on the running command line"
    [[ "${cmdline_initrd//\\//}" == "$stock_rel" ]] \
        || die "Running boot initrd (${cmdline_initrd}) is not the stock file this stanza would use (${stock_rel}). Boot the normal rEFInd icon first."

    VOLUME_MOUNT="$mount"
    VOLUME_PARTUUID="$partuuid"
    VOLUME_LOADER="$loader"
    VOLUME_STOCK="/${stock_rel}"
    VOLUME_EARLY="/${early_rel}"
    VOLUME_COMBINED="/$(dirname -- "$early_rel")/s5-initrd.img"
    VOLUME_KERNEL="$version"
}

linux_options() {
    [[ -f "$REFIND_LINUX_CONF" && ! -L "$REFIND_LINUX_CONF" ]] \
        || die "refind_linux.conf is missing or is a symlink"
    python3 - "$STANZA_PY" "$REFIND_LINUX_CONF" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.parse_linux_options(open(sys.argv[2], encoding="utf-8").read()))
PY
}

write_stanza() {
    local destination="$1" options="$2"
    python3 - "$STANZA_PY" "$destination" "$VOLUME_KERNEL" "$VOLUME_PARTUUID" \
        "$VOLUME_LOADER" "$VOLUME_COMBINED" "$options" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
stanza = module.render_stanza(
    kernel=sys.argv[3],
    partuuid=sys.argv[4],
    loader=sys.argv[5],
    initrd=sys.argv[6],
    options=sys.argv[7],
)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(stanza)
PY
    chmod 0600 "$destination"
}

# rEFInd 0.13 keeps one initrd token. The uncompressed ACPI CPIO has to be the
# first archive in that single file so the kernel scans it before the stock
# initramfs. Do not modify the stock initrd itself.
write_combined_initrd() {
    local early="$1" stock="$2" destination="$3" size
    [[ -f "$early" && ! -L "$early" ]] || die "Early CPIO is missing or is a symlink: ${early}"
    [[ -f "$stock" && ! -L "$stock" ]] || die "Stock initrd is missing or is a symlink: ${stock}"
    [[ "$stock" != "$destination" && "$early" != "$destination" ]] \
        || die "Refusing to overwrite the stock initrd"
    size="$(stat -c '%s' -- "$early")"
    (( size > 0 && size % 4 == 0 )) \
        || die "Early CPIO is empty or not 4-byte aligned; refusing to concatenate it"
    python3 - "$early" <<'PY'
from pathlib import Path
import sys
magic = Path(sys.argv[1]).read_bytes()[:6]
if magic != b"070701":
    raise SystemExit("Early CPIO is not an uncompressed newc archive")
PY
    cat -- "$early" "$stock" > "$destination"
    chmod 0600 "$destination"
}

confirm() {
    local prompt="$1" answer
    [[ -r /dev/tty && -w /dev/tty ]] || die "Refusing to change boot files without a terminal confirmation"
    printf '%s [y/N] ' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || die "Confirmation was not read"
    case "$answer" in
        y|yes|Y|YES) ;;
        *) die "No changes made" ;;
    esac
}

preflight() {
    local command
    for command in python3 findmnt awk basename realpath grep tr uname mokutil; do
        need_cmd "$command"
    done
    check_identity
    check_gpu
    check_table_upgrade
    check_secure_boot
    volume_layout
    linux_options >/dev/null
    [[ ! -e "$REFIND_LINUX_CONF" || -f "$REFIND_LINUX_CONF" ]]
    [[ "$VOLUME_EARLY" == "/boot/omen-acpi/s5-early.cpio" ]] \
        || die "Derived early path ${VOLUME_EARLY} is not /boot/omen-acpi/s5-early.cpio; refusing a different volume layout"
    [[ "$VOLUME_COMBINED" == "/boot/omen-acpi/s5-initrd.img" ]] \
        || die "Derived combined initrd path ${VOLUME_COMBINED} is not /boot/omen-acpi/s5-initrd.img"
}

artifact_dir() {
    local root="${XDG_DATA_HOME:-$HOME/.local/share}/omen-acpi-refind"
    mkdir -p "$root"
    chmod 0700 "$root"
    printf '%s\n' "$root"
}

verify_s5_aml() {
    python3 - "$1" "$S5_OEM_REVISION" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
expected = int(sys.argv[2], 16)
if len(data) < 36 or data[:4] != b"DSDT":
    raise SystemExit("AML is not a DSDT")
if struct.unpack_from("<I", data, 4)[0] != len(data) or sum(data) & 0xFF:
    raise SystemExit("AML header length or checksum is invalid")
if data[10:16] != b"HPQOEM" or data[16:24] != b"8E35    ":
    raise SystemExit("AML OEM identity is not HPQOEM / 8E35")
revision = struct.unpack_from("<I", data, 24)[0]
if revision != expected:
    raise SystemExit(f"AML OEM revision is 0x{revision:08X}, expected {sys.argv[2]}")
PY
}

build_early_cpio() {
    local aml="$1" destination="$2" early_dir
    early_dir="$(dirname -- "$destination")/early"
    rm -rf -- "$early_dir"
    mkdir -p "$early_dir/kernel/firmware/acpi"
    install -m 0644 "$aml" "$early_dir/kernel/firmware/acpi/DSDT.aml"
    (
        cd "$early_dir"
        printf '%s\0' \
            kernel \
            kernel/firmware \
            kernel/firmware/acpi \
            kernel/firmware/acpi/DSDT.aml \
        | cpio --null --create --format=newc --owner=0:0 --quiet \
        > "$destination"
    )
    chmod 0600 "$destination"
}

collect_and_build() {
    local root="$1" source_archive build_archive extracted tool
    for tool in acpidump acpixtract iasl; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "Missing command: ${tool}. Install the acpica-tools package; this companion will not install it."
    done
    need_cmd tar
    need_cmd sha256sum
    [[ -x "$COLLECT" && -x "$BUILD" ]] || die "Collector or builder is missing"
    unset OMEN_ACPI_UNVALIDATED_OPT_IN
    export OMEN_ACPI_OUTPUT_DIR="$root"
    export OMEN_ACPI_RESULT_FILE="$root/collect-result.txt"
    "$COLLECT"
    source_archive="$(tr -d '[:space:]' < "$OMEN_ACPI_RESULT_FILE")"
    [[ -f "$source_archive" && "$source_archive" == "$root/"* ]] \
        || die "Collector did not return a private source archive"
    export OMEN_ACPI_RESULT_FILE="$root/build-result.txt"
    "$BUILD" s5 "$source_archive"
    build_archive="$(tr -d '[:space:]' < "$OMEN_ACPI_RESULT_FILE")"
    [[ -f "$build_archive" && "$build_archive" == "$root/"* ]] \
        || die "Builder did not return a private s5 archive"
    extracted="$root/extracted"
    rm -rf -- "$extracted"
    mkdir -p "$extracted"
    tar -xzf "$build_archive" -C "$extracted"
    mapfile -t aml_files < <(find "$extracted" -type f -name DSDT.aml -print)
    ((${#aml_files[@]} == 1)) || die "Expected one DSDT.aml in the s5 build archive"
    verify_s5_aml "${aml_files[0]}"
    install -m 0600 "${aml_files[0]}" "$root/DSDT.aml"
}

cmd_install() {
    local options root tool
    (($# == 0)) || die "install takes no arguments"
    ((EUID != 0)) || die "Run install as the normal user. It will ask for sudo only to write the boot files."
    preflight
    for tool in sudo cpio install sha256sum tar; do
        need_cmd "$tool"
    done
    printf '%s\n' \
        "This will collect this machine's DSDT and, only if the stock _PTS and WQBZ anchors match, write:" \
        "  ${EARLY_CPIO}" \
        "  one marked stanza at the end of ${REFIND_CONF}" \
        "It will not edit ${REFIND_LINUX_CONF}, default_selection, timeout, scan options, NVRAM, or Windows." \
        "The NVIDIA 580 driver is not the measured 610 case. If NVDE is not 1, the loaded override can still leave the GPU powered." \
        "After a test, select the normal rEFInd Linux icon again. rEFInd may remember the last choice."
    confirm "Append the s5 test stanza?"
    sudo -- "$0" --internal-preflight
    root="$(artifact_dir)"
    collect_and_build "$root"
    options="$(linux_options)"
    write_stanza "$root/stanza.txt" "$options"
    sudo -- "$0" --internal-install "$root/DSDT.aml" "$root/stanza.txt"
    printf '\nInstalled. Reboot and select "Pop!_OS (omen-acpi s5 test)" once.\n'
    printf 'Then select the normal Linux icon. Do not make the test stanza the default.\n'
}

cmd_repair() {
    (($# == 0)) || die "repair takes no arguments"
    ((EUID != 0)) || die "Run repair as the normal user. It will ask for sudo only to rewrite the owned boot files."
    need_cmd sudo
    preflight
    [[ -f "$EARLY_CPIO" && ! -L "$EARLY_CPIO" ]] \
        || die "The early CPIO is missing. Run install, not repair."
    printf '%s\n' \
        "rEFInd 0.13 kept only the last initrd line, so the previous test booted the stock initrd." \
        "This rewrites the owned stanza to one initrd file: the override concatenated in front of the stock initrd." \
        "It does not edit ${REFIND_LINUX_CONF}, default_selection, timeout, scan options, or Windows." \
        "It does not modify ${VOLUME_STOCK}."
    confirm "Rewrite the s5 test stanza?"
    sudo -- "$0" --internal-repair
    printf '\nRepaired. Reboot and select "Pop!_OS (omen-acpi s5 test)" again.\n'
    printf 'After boot, journalctl -k -b | grep "ACPI: DSDT" should show 0107200A.\n'
}

cmd_status() {
    (($# == 0)) || die "status takes no arguments"
    if [[ -r "$REFIND_CONF" ]]; then
        "$0" --internal-status
    else
        need_cmd sudo
        sudo -- "$0" --internal-status
    fi
}

cmd_remove() {
    (($# == 0)) || die "remove takes no arguments"
    ((EUID != 0)) || die "Run remove as the normal user. It will ask for sudo only to delete the owned files."
    need_cmd sudo
    printf '%s\n' \
        "This deletes the marked omen-acpi stanza and ${EARLY_CPIO}." \
        "It does not edit ${REFIND_LINUX_CONF}, default_selection, timeout, scan options, or Windows."
    confirm "Remove the s5 test stanza?"
    sudo -- "$0" --internal-remove
}

internal_preflight() {
    ((EUID == 0)) || die "internal preflight must run as root"
    [[ -f "$REFIND_CONF" && ! -L "$REFIND_CONF" ]] || die "rEFInd config is missing or is a symlink: ${REFIND_CONF}"
    python3 - "$STANZA_PY" "$REFIND_CONF" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text = open(sys.argv[2], encoding="utf-8").read()
if module.BEGIN in text or module.END in text or module.TITLE in text:
    raise SystemExit("refind.conf already contains an omen-acpi stanza; remove it before installing again")
PY
    printf 'rEFInd config is present and has no omen-acpi stanza.\n'
}

internal_install() {
    local aml="$1" stanza_file="$2" work options
    ((EUID == 0)) || die "internal install must run as root"
    (($# == 2)) || die "internal install expects an AML path and a stanza file"
    [[ -f "$aml" && ! -L "$aml" && -f "$stanza_file" && ! -L "$stanza_file" ]] \
        || die "Install payload is missing or is a symlink"
    preflight
    need_cmd cpio
    need_cmd install
    need_cmd sha256sum
    verify_s5_aml "$aml"
    options="$(linux_options)"
    volume_layout
    [[ "$VOLUME_EARLY" == "/boot/omen-acpi/s5-early.cpio" ]] \
        || die "Refusing to install an early CPIO outside /boot/omen-acpi"
    need_cmd cmp

    work="$(mktemp -d /tmp/omen-acpi-refind.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$work")" RETURN
    write_stanza "$work/live-stanza.txt" "$options"
    cmp -s "$work/live-stanza.txt" "$stanza_file" \
        || die "Stanza file does not match the stanza derived from the live boot files"
    build_early_cpio "$aml" "$work/s5-early.cpio"
    if [[ -e "$PAYLOAD_DIR" ]]; then
        [[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] || die "Payload path is not a directory: ${PAYLOAD_DIR}"
    else
        install -d -o root -g root -m 0755 "$PAYLOAD_DIR"
    fi
    if [[ -e "$EARLY_CPIO" || -e "$COMBINED_INITRD" || -e "$MANIFEST" ]]; then
        die "Payload files already exist. Remove them before installing again: ${PAYLOAD_DIR}"
    fi
    write_combined_initrd "$work/s5-early.cpio" "/boot/initrd.img-${VOLUME_KERNEL}" "$work/s5-initrd.img"
    install -o root -g root -m 0644 "$work/s5-early.cpio" "$EARLY_CPIO"
    install -o root -g root -m 0644 "$work/s5-initrd.img" "$COMBINED_INITRD"
    {
        printf 'VARIANT=s5\n'
        printf 'KERNEL=%s\n' "$VOLUME_KERNEL"
        printf 'PARTUUID=%s\n' "$VOLUME_PARTUUID"
        printf 'AML_SHA256=%s\n' "$(sha256sum -- "$aml" | awk '{print $1}')"
        printf 'CPIO_SHA256=%s\n' "$(sha256sum -- "$EARLY_CPIO" | awk '{print $1}')"
        printf 'COMBINED_SHA256=%s\n' "$(sha256sum -- "$COMBINED_INITRD" | awk '{print $1}')"
    } > "$work/manifest.txt"
    install -o root -g root -m 0644 "$work/manifest.txt" "$MANIFEST"

    if [[ ! -f "$CONF_BACKUP" ]]; then
        install -o root -g root -m 0600 "$REFIND_CONF" "$CONF_BACKUP"
    fi
    if ! python3 - "$STANZA_PY" "$REFIND_CONF" "$stanza_file" <<'PY'
import importlib.util
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = sys.argv[2]
try:
    stanza = open(sys.argv[3], encoding="utf-8").read()
    original = open(config, encoding="utf-8").read()
    updated = module.append_stanza(original, stanza)
except module.StanzaError as exc:
    raise SystemExit(str(exc))
directory = os.path.dirname(config)
mode = os.stat(config).st_mode & 0o777
fd, temporary = tempfile.mkstemp(prefix=".refind.conf.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fchmod(handle.fileno(), mode)
    os.replace(temporary, config)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
    then
        rm -f -- "$EARLY_CPIO" "$COMBINED_INITRD" "$MANIFEST"
        die "Did not append the stanza; removed the staged payload"
    fi
    printf 'Appended the s5 stanza. Stock icon, scan options, and default_selection were not rewritten.\n'
}

rewrite_owned_stanza() {
    local stanza_file="$1"
    python3 - "$STANZA_PY" "$REFIND_CONF" "$stanza_file" <<'PY'
import importlib.util
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = sys.argv[2]
try:
    stanza = open(sys.argv[3], encoding="utf-8").read()
    original = open(config, encoding="utf-8").read()
    updated = module.replace_owned_stanza(original, stanza)
except module.StanzaError as exc:
    raise SystemExit(str(exc))
directory = os.path.dirname(config)
mode = os.stat(config).st_mode & 0o777
fd, temporary = tempfile.mkstemp(prefix=".refind.conf.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fchmod(handle.fileno(), mode)
    os.replace(temporary, config)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
}

internal_repair() {
    local work options stock
    ((EUID == 0)) || die "internal repair must run as root"
    (($# == 0)) || die "internal repair takes no arguments"
    [[ -f "$REFIND_CONF" && ! -L "$REFIND_CONF" ]] || die "rEFInd config is missing or is a symlink"
    [[ -f "$EARLY_CPIO" && ! -L "$EARLY_CPIO" ]] || die "Early CPIO is missing or is a symlink"
    preflight
    need_cmd cmp
    stock="/boot/initrd.img-${VOLUME_KERNEL}"
    work="$(mktemp -d /tmp/omen-acpi-refind.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf -- $(printf '%q' "$work")" RETURN
    write_combined_initrd "$EARLY_CPIO" "$stock" "$work/s5-initrd.img"
    install -o root -g root -m 0644 "$work/s5-initrd.img" "$COMBINED_INITRD"
    options="$(linux_options)"
    write_stanza "$work/stanza.txt" "$options"
    rewrite_owned_stanza "$work/stanza.txt"
    printf 'Rewrote the s5 stanza to load %s\n' "$COMBINED_INITRD"
    printf 'The stock initrd was not modified: %s\n' "$stock"
}

internal_status() {
    ((EUID == 0 || -r "$REFIND_CONF")) || die "Cannot read ${REFIND_CONF}"
    python3 - "$STANZA_PY" "$REFIND_CONF" "$EARLY_CPIO" "$MANIFEST" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text = open(sys.argv[2], encoding="utf-8").read()
print("stanza=" + ("present" if module.BEGIN in text and module.END in text else "absent"))
PY
    if [[ -f "$EARLY_CPIO" && ! -L "$EARLY_CPIO" ]]; then
        printf 'cpio=present %s\n' "$(sha256sum -- "$EARLY_CPIO" | awk '{print $1}')"
    else
        printf 'cpio=absent\n'
    fi
    if [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]]; then
        printf 'manifest=%s\n' "$MANIFEST"
        cat -- "$MANIFEST"
    else
        printf 'manifest=absent\n'
    fi
    if grep -q 'omen-acpi/s5-early.cpio' /proc/cmdline 2>/dev/null; then
        printf 'current_boot=s5-test\n'
        printf 'Select the normal Linux icon on the next boot. rEFInd may remember this choice.\n'
    else
        printf 'current_boot=not-this-stanza\n'
    fi
}

internal_remove() {
    ((EUID == 0)) || die "internal remove must run as root"
    [[ -f "$REFIND_CONF" && ! -L "$REFIND_CONF" ]] || die "rEFInd config is missing or is a symlink"
    python3 - "$STANZA_PY" "$REFIND_CONF" <<'PY'
import importlib.util
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location("refind_stanza", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = sys.argv[2]
original = open(config, encoding="utf-8").read()
if module.BEGIN not in original and module.END not in original and module.TITLE not in original:
    print("stanza=absent")
    raise SystemExit(0)
try:
    updated = module.remove_stanza(original)
except module.StanzaError as exc:
    raise SystemExit(str(exc))
directory = os.path.dirname(config)
mode = os.stat(config).st_mode & 0o777
fd, temporary = tempfile.mkstemp(prefix=".refind.conf.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fchmod(handle.fileno(), mode)
    os.replace(temporary, config)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
print("stanza=removed")
PY
    if [[ -L "$EARLY_CPIO" || -L "$COMBINED_INITRD" || -L "$MANIFEST" || -L "$PAYLOAD_DIR" ]]; then
        die "Refusing to delete a symlink in ${PAYLOAD_DIR}"
    fi
    [[ ! -e "$EARLY_CPIO" || -f "$EARLY_CPIO" ]] || die "Early CPIO path is not a regular file"
    [[ ! -e "$COMBINED_INITRD" || -f "$COMBINED_INITRD" ]] || die "Combined initrd path is not a regular file"
    [[ ! -e "$MANIFEST" || -f "$MANIFEST" ]] || die "Manifest path is not a regular file"
    rm -f -- "$EARLY_CPIO" "$COMBINED_INITRD" "$MANIFEST"
    if [[ -d "$PAYLOAD_DIR" ]]; then
        if [[ -n "$(ls -A -- "$PAYLOAD_DIR")" ]]; then
            printf 'Left %s in place because it still contains files.\n' "$PAYLOAD_DIR" >&2
        else
            rmdir -- "$PAYLOAD_DIR"
        fi
    fi
    printf 'Removed the owned s5 payload. %s was not edited.\n' "$REFIND_LINUX_CONF"
    printf 'A one-time copy, if created, remains at %s.\n' "$CONF_BACKUP"
}

if (($# < 1)); then
    usage >&2
    exit 2
fi

command="$1"
shift
case "$command" in
    -h|--help|help)
        usage
        ;;
    install)
        cmd_install "$@"
        ;;
    repair)
        cmd_repair "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    remove)
        cmd_remove "$@"
        ;;
    --internal-preflight)
        internal_preflight "$@"
        ;;
    --internal-install)
        internal_install "$@"
        ;;
    --internal-repair)
        internal_repair "$@"
        ;;
    --internal-status)
        internal_status "$@"
        ;;
    --internal-remove)
        internal_remove "$@"
        ;;
    *)
        usage >&2
        die "Unknown command: ${command}"
        ;;
esac
