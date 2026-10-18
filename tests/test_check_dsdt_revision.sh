#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECK="$ROOT/scripts/check-dsdt-revision.sh"
export OMEN_ACPI_NOTIFY=0

loaded=$'ACPI: DSDT ACPI table found in initrd [kernel/firmware/acpi/DSDT.aml][0x1b025]\nACPI: DSDT 0x0000000069DA8000 Physical table override, new table: 0x000000007A752000\nACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200A INTL 20230628)\n'

expect_ok() {
    local name="$1" log="$2" output
    output="$("$CHECK" --journal - <<<"$log")" || {
        printf 'FAIL %s: expected success\n' "$name" >&2
        exit 1
    }
    [[ "$(tail -n 1 <<<"$output")" == "matching" ]] || {
        printf 'FAIL %s: missing verdict\n%s\n' "$name" "$output" >&2
        exit 1
    }
    grep -Fq '0107200A' <<<"$output" || {
        printf 'FAIL %s: header was not printed\n' "$name" >&2
        exit 1
    }
}

expect_fail() {
    local name="$1" log="$2" output
    if output="$("$CHECK" --journal - <<<"$log" 2>&1)"; then
        printf 'FAIL %s: expected a non-zero exit\n' "$name" >&2
        exit 1
    fi
    grep -Fxq 'not matching' <<<"$output" || {
        printf 'FAIL %s: missing not matching\n%s\n' "$name" "$output" >&2
        exit 1
    }
}

expect_ok "loaded override" "$loaded"
expect_ok "timestamp prefix" \
    "Oct 18 12:04:31 pop-monkey kernel: ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200A INTL 20230628)"
expect_ok "lowercase revision" \
    "ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200a INTL 20230628)"

expect_fail "stock revision" \
    "ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     01072009 INTL 20230628)"
expect_fail "initrd line only" \
    "ACPI: DSDT ACPI table found in initrd [kernel/firmware/acpi/DSDT.aml][0x1b025]"
expect_fail "two revisions" \
    $'ACPI: DSDT 0x0000000069DA8000 01A000 (v02 HPQOEM 8E35     01072009 INTL 20230628)\nACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200A INTL 20230628)\n'
expect_fail "empty log" ""

file_log="$(mktemp)"
trap 'rm -f -- "$file_log"' EXIT
printf '%s\n' "ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200A INTL 20230628)" >"$file_log"
output="$("$CHECK" --journal "$file_log")"
[[ "$(tail -n 1 <<<"$output")" == "matching" ]]

help_text="$("$CHECK" --help)"
grep -Fq 'DSDT OEM revision 0107200A' <<<"$help_text"

if "$CHECK" --not-an-option >/dev/null 2>&1; then
    printf 'FAIL unknown argument was accepted\n' >&2
    exit 1
fi

stock='ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     01072009 INTL 20230628)'

output="$(
    env -u DBUS_SESSION_BUS_ADDRESS OMEN_ACPI_NOTIFY=1 \
        "$CHECK" --journal - <<<"$loaded"
)" || {
    printf 'FAIL success without a session bus\n' >&2
    exit 1
}
[[ "$(tail -n 1 <<<"$output")" == "matching" ]] || {
    printf 'FAIL success without a session bus: missing verdict\n' >&2
    exit 1
}

output="$(
    env OMEN_ACPI_NOTIFY=1 DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/omen-acpi-no-notify-bus' \
        "$CHECK" --journal - <<<"$loaded"
)" || {
    printf 'FAIL success when the notification bus is unavailable\n' >&2
    exit 1
}
[[ "$(tail -n 1 <<<"$output")" == "matching" ]] || {
    printf 'FAIL success when the notification bus is unavailable: missing verdict\n' >&2
    exit 1
}

if output="$(
    env OMEN_ACPI_NOTIFY=1 DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/omen-acpi-no-notify-bus' \
        "$CHECK" --journal - <<<"$stock" 2>&1
)"; then
    printf 'FAIL stock revision was accepted while notifications were unavailable\n' >&2
    exit 1
fi
grep -Fxq 'not matching' <<<"$output" || {
    printf 'FAIL stock revision did not say not matching\n%s\n' "$output" >&2
    exit 1
}
grep -Fq 'ERROR: DSDT OEM revision is 01072009; expected 0107200A' <<<"$output" || {
    printf 'FAIL stock revision did not report the mismatch\n%s\n' "$output" >&2
    exit 1
}

success_trace="$(bash -x "$CHECK" --journal - <<<"$loaded" 2>&1 >/dev/null)" || {
    printf 'FAIL could not trace a matching revision\n' >&2
    exit 1
}
if grep -F 'notify_result' <<<"$success_trace" >/dev/null; then
    printf 'FAIL a matching revision tried to notify\n' >&2
    exit 1
fi

mismatch_trace="$(bash -x "$CHECK" --journal - <<<"$stock" 2>&1 >/dev/null || true)"
if ! grep -F 'notify_result' <<<"$mismatch_trace" >/dev/null; then
    printf 'FAIL a mismatched revision did not notify\n' >&2
    exit 1
fi

output="$("$CHECK" --startup --journal - <<<"$loaded")"
[[ "$(tail -n 1 <<<"$output")" == "matching" ]] || {
    printf 'FAIL startup match did not print matching\n%s\n' "$output" >&2
    exit 1
}

if output="$("$CHECK" --startup --journal - <<<"$stock" 2>&1)"; then
    printf 'FAIL startup mismatch was accepted\n' >&2
    exit 1
fi
grep -Fxq 'not matching' <<<"$output" || {
    printf 'FAIL startup mismatch did not say not matching\n%s\n' "$output" >&2
    exit 1
}

printf 'check-dsdt-revision: PASS\n'
