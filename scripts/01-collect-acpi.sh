#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail
umask 077
export PATH="/usr/bin:/bin"

# Extracts only the decompiled DSDT source needed by this reproduction.
# Raw ACPI tables are kept in a private temporary directory and deleted on exit.
# The live DSDT must be the stock HPQOEM 8E35 table at OEM revision 0x01072009.

readonly EXPECTED_PRODUCT="OMEN Gaming Laptop 16-ap0xxx"
readonly EXPECTED_BOARD="8E35"
readonly EXPECTED_BIOS="F.13"
readonly LIVE_DSDT="/sys/firmware/acpi/tables/DSDT"
readonly ORIGINAL_OEM_ID="HPQOEM"
readonly ORIGINAL_TABLE_ID="8E35    "
readonly ORIGINAL_REVISION="0x01072009"
readonly ACPI_OVERRIDE_TAINT=256
MACHINE_PRODUCT=""
MACHINE_BOARD=""
MACHINE_BIOS=""
PACKAGE_FORMAT=""

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

usage() {
    printf 'Usage: %s\n' "$0"
    printf 'Extract the local DSDT source for the OMEN ACPI reproduction.\n'
}

refuse_acpi_override() {
    local taint
    [[ -r /proc/sys/kernel/tainted ]] || die "Kernel taint value is unreadable"
    taint="$(tr -d '[:space:]' < /proc/sys/kernel/tainted)"
    [[ "$taint" =~ ^[0-9]+$ ]] || die "Kernel taint value is not numeric"
    if (( (taint & ACPI_OVERRIDE_TAINT) != 0 )); then
        die "An ACPI table override is already loaded. Boot the normal rEFInd Linux icon and try again."
    fi
}

stock_dsdt_sha() {
    local dsdt_path="$1"
    [[ -f "$dsdt_path" && ! -L "$dsdt_path" && -r "$dsdt_path" ]] \
        || die "DSDT is unreadable: $dsdt_path"
    python3 - "$dsdt_path" "$ORIGINAL_OEM_ID" "$ORIGINAL_TABLE_ID" "$ORIGINAL_REVISION" <<'PY'
import hashlib
import struct
import sys
from pathlib import Path

path, expected_oem, expected_table, expected_revision = sys.argv[1:]
expected_revision = int(expected_revision, 0)

def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    data = Path(path).read_bytes()
except OSError:
    fail(f"DSDT is unreadable: {path}")

if len(data) < 36:
    fail("DSDT is too short to be a stock table")
signature = data[0:4]
length = struct.unpack_from("<I", data, 4)[0]
try:
    oem_id = data[10:16].decode("ascii", "strict")
    table_id = data[16:24].decode("ascii", "strict")
except UnicodeError:
    fail("DSDT OEM identity is not the stock HPQOEM 8E35 table")
revision = struct.unpack_from("<I", data, 24)[0]
if signature != b"DSDT" or length != len(data) or (sum(data) & 0xFF) != 0:
    fail("DSDT header or checksum is invalid")
if oem_id != expected_oem or table_id != expected_table:
    fail("DSDT OEM identity is not the stock HPQOEM 8E35 table")
if revision != expected_revision:
    fail(
        f"Live DSDT OEM revision is 0x{revision:08X}, expected 0x{expected_revision:08X}. "
        "Boot the normal rEFInd Linux icon and try again."
    )
print(hashlib.sha256(data).hexdigest())
PY
}

check_machine() {
    MACHINE_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    MACHINE_BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
    MACHINE_BIOS="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    [[ -n "$MACHINE_PRODUCT" && -n "$MACHINE_BOARD" && -n "$MACHINE_BIOS" ]] \
        || die "DMI identity is missing, empty or unreadable"
    [[ "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\n'* \
        && "$MACHINE_PRODUCT$MACHINE_BOARD$MACHINE_BIOS" != *$'\r'* ]] \
        || die "DMI identity contains an invalid line break"

    if [[ "$MACHINE_PRODUCT" == "$EXPECTED_PRODUCT" \
        && "$MACHINE_BOARD" == "$EXPECTED_BOARD" \
        && "$MACHINE_BIOS" == "$EXPECTED_BIOS" ]]; then
        PACKAGE_FORMAT=2
    else
        [[ "${OMEN_ACPI_UNVALIDATED_OPT_IN:-}" == "1" ]] \
            || die "Unvalidated machine requires the internal CLI opt-in indicator"
        PACKAGE_FORMAT=3
    fi
}

if (($# > 0)); then
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        --internal-stock-dsdt-sha)
            shift
            (($# == 1)) || die "--internal-stock-dsdt-sha requires a DSDT path"
            need_cmd python3
            stock_dsdt_sha "$1"
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
fi

for command in sudo acpidump acpixtract iasl tar sha256sum mktemp install grep realpath awk python3; do
    need_cmd "$command"
done

check_machine
refuse_acpi_override

stamp="$(date +%Y%m%d-%H%M%S)"
temp_base="${TMPDIR:-/tmp}"
work="$(mktemp -d "$temp_base/omen-acpi-work.XXXXXX")"

cleanup() {
    if [[ -n "${work:-}" && -d "$work" ]]; then
        case "$(basename -- "$work")" in
            omen-acpi-work.*)
                rm -rf -- "$work"
                ;;
        esac
    fi
}
trap cleanup EXIT

raw_dir="$work/raw"
package_root="$work/package"
if [[ "$PACKAGE_FORMAT" == "2" ]]; then
    package_name="omen-ap0006sl-acpi-source-$stamp"
else
    package_name="omen-unvalidated-acpi-source-$stamp"
fi
package_dir="$package_root/$package_name"
output_dir="${OMEN_ACPI_OUTPUT_DIR:-$HOME}"
[[ -d "$output_dir" ]] || die "Output directory does not exist: $output_dir"
output_dir="$(realpath -- "$output_dir")"
archive="$output_dir/$package_name.tar.gz"

mkdir -p "$raw_dir" "$package_dir"

[[ -e "$LIVE_DSDT" && ! -L "$LIVE_DSDT" ]] || die "Live DSDT is missing: $LIVE_DSDT"
sudo -- cat -- "$LIVE_DSDT" > "$raw_dir/live-dsdt.dat"
original_dsdt_sha="$(stock_dsdt_sha "$raw_dir/live-dsdt.dat")"
[[ "$original_dsdt_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die "The original DSDT fingerprint could not be recorded"

printf 'Dumping firmware ACPI tables into a private temporary directory...\n'
sudo acpidump > "$raw_dir/acpidump.txt"

(
    cd "$raw_dir"
    acpixtract -a acpidump.txt > acpixtract.log 2>&1
)

[[ -r "$raw_dir/dsdt.dat" ]] \
    || die "acpixtract did not produce dsdt.dat"

dumped_dsdt_sha="$(sha256sum -- "$raw_dir/dsdt.dat" | awk '{print $1}')"
[[ "$dumped_dsdt_sha" == "$original_dsdt_sha" ]] \
    || die "The DSDT emitted by acpidump does not match the verified live stock DSDT"

printf 'Decompiling the DSDT with the available SSDT namespace...\n'
(
    cd "$raw_dir"

    shopt -s nullglob
    ssdt_tables=(ssdt*.dat)
    shopt -u nullglob

    set +e
    if ((${#ssdt_tables[@]} > 0)); then
        iasl -da -dl dsdt.dat "${ssdt_tables[@]}" > decompile-all.log 2>&1
    else
        iasl -d dsdt.dat > decompile-all.log 2>&1
    fi
    decompile_status=$?
    set -e

    if [[ ! -s dsdt.dsl ]]; then
        set +e
        if ((${#ssdt_tables[@]} > 0)); then
            iasl -e "${ssdt_tables[@]}" -d dsdt.dat > decompile-dsdt.log 2>&1
        else
            iasl -d dsdt.dat > decompile-dsdt.log 2>&1
        fi
        fallback_status=$?
        set -e

        [[ "$fallback_status" -eq 0 && -s dsdt.dsl ]] \
            || die "DSDT decompilation failed; the private temporary data will be removed"
    elif [[ "$decompile_status" -ne 0 ]]; then
        printf 'Warning: full namespace decompilation returned status %s, but dsdt.dsl was produced.\n' \
            "$decompile_status" >&2
    fi
)

source_dsl="$raw_dir/dsdt.dsl"
[[ -s "$source_dsl" ]] || die "dsdt.dsl was not produced"

expected_header='DefinitionBlock ("", "DSDT", 2, "HPQOEM", "8E35    ", 0x01072009)'
expected_external='External (_SB_.PCI0.GPP0.PEGP, DeviceObj)'

[[ "$(grep -Fxc "$expected_header" "$source_dsl" || true)" -eq 1 ]] \
    || die "The original DSDT header does not match OEM revision 0x01072009"
[[ "$(grep -Fc "$expected_external" "$source_dsl" || true)" -eq 1 ]] \
    || die "The expected NVIDIA PEGP external declaration is missing or duplicated"

install -m 0600 "$source_dsl" "$package_dir/dsdt.dsl"

{
    printf 'PACKAGE_FORMAT=%s\n' "$PACKAGE_FORMAT"
    printf 'DMI_PRODUCT=%s\n' "$MACHINE_PRODUCT"
    printf 'MAINBOARD=%s\n' "$MACHINE_BOARD"
    printf 'BIOS=%s\n' "$MACHINE_BIOS"
    printf 'ORIGINAL_DSDT_OEM_REVISION=0x01072009\n'
    printf 'ORIGINAL_DSDT_SHA256=%s\n' "$original_dsdt_sha"
} > "$package_dir/SOURCE.txt"

{
    printf 'This private archive contains the decompiled DSDT source required by the next build step.\n'
    printf 'It intentionally excludes the raw acpidump, unrelated ACPI tables, system logs, kernel command line and hardware identifiers.\n'
    printf 'The DSDT is still machine-derived firmware data. Review it manually before sharing it.\n'
} > "$package_dir/README.txt"

(
    cd "$package_dir"
    sha256sum README.txt SOURCE.txt dsdt.dsl > SHA256SUMS
)

tar -czf "$archive" -C "$package_root" "$package_name"
chmod 0600 "$archive"

if [[ -n "${OMEN_ACPI_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$archive" > "$OMEN_ACPI_RESULT_FILE"
    chmod 0600 "$OMEN_ACPI_RESULT_FILE"
fi

printf '\nSource archive created:\n%s\n' "$archive"
printf '\nKeep this generated archive private unless you have manually reviewed its contents.\n'
