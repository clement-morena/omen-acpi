#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Read the current boot's kernel log and require the loaded DSDT OEM
# revision of the s5 override. Stock firmware on this machine reports
# 01072009. The header line looks like:
#   ACPI: DSDT 0x000000007A752000 01B025 (v02 HPQOEM 8E35     0107200A INTL 20230628)
#
set -Eeuo pipefail
export PATH="/usr/bin:/bin"

readonly EXPECTED_REVISION="0107200A"
readonly HEADER_RE='ACPI: DSDT 0x[0-9A-Fa-f]+ [0-9A-Fa-f]+ \(v[0-9]{2} .{6} .{8} ([0-9A-Fa-f]{8}) .{4} [0-9A-Fa-f]{8}\)'

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: scripts/check-dsdt-revision.sh [--journal FILE]

Read the current boot kernel log and require DSDT OEM revision ${EXPECTED_REVISION}.
The kernel also prints ACPI: DSDT lines for the initrd copy and the physical
override. Those lines have no OEM revision; this command uses the table header.
A graphical session gets a desktop notification when the revision does not match.
That notification stays until it is closed. The terminal prints matching or not matching.
The revision check still completes when that notification cannot be shown.
Set OMEN_ACPI_NOTIFY=0 to skip that notification.

  --startup        Used by the login entry. Waits briefly for the notification
                   service before reporting a mismatch.
  --journal FILE   Read FILE instead of journalctl. FILE may be - for stdin.
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# GNOME Shell ignores the expire timeout and uses its own 4 second banner
# timer. A critical, resident notification skips that timer and stays until
# the close button. expire timeout 0 asks other notification servers to do
# the same. The attempt runs in a subshell: a missing bus, a missing gdbus,
# a daemon that rejects the call, or a hung bus must not change the revision result.
wait_for_notification_service() {
    local attempt
    ((startup == 0)) && return 0
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 0
    command -v gdbus >/dev/null 2>&1 || return 0
    for attempt in {1..15}; do
        if gdbus call --session \
            --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.GetNameOwner \
            org.freedesktop.Notifications >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 0
}

notify_result() {
    local icon="$1" summary="$2" body="$3"
    [[ "${OMEN_ACPI_NOTIFY:-1}" == 1 ]] || return 0
    wait_for_notification_service
    (
        [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || exit 0
        command -v gdbus >/dev/null 2>&1 || exit 0
        command -v timeout >/dev/null 2>&1 || exit 0
        timeout --foreground 2 gdbus call --session \
            --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            omen-acpi \
            0 \
            "$icon" \
            "$summary" \
            "$body" \
            [] \
            '{"urgency": <byte 2>, "resident": <true>}' \
            0
        exit 0
    ) >/dev/null 2>&1 || true
}

fail_check() {
    local message="$1"
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" >&2
    fi
    printf 'not matching\n' >&2
    notify_result dialog-error "DSDT OEM revision check failed" "$message"
    die "$message"
}

startup=0
journal_file=""
while (($#)); do
    case "$1" in
        -h|--help|help)
            (($# == 1)) || die "help takes no other arguments"
            usage
            exit 0
            ;;
        --startup)
            startup=1
            ;;
        --journal)
            shift
            (($#)) || die "--journal requires one file path"
            [[ -z "$journal_file" ]] || die "--journal was given twice"
            journal_file="$1"
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac
    shift
done

if [[ -n "$journal_file" ]]; then
    if [[ "$journal_file" == "-" ]]; then
        log="$(cat)"
    else
        [[ -f "$journal_file" && ! -L "$journal_file" && -r "$journal_file" ]] \
            || die "Journal file is missing, unreadable, or a symlink: ${journal_file}"
        log="$(cat -- "$journal_file")"
    fi
else
    need_cmd journalctl
    log="$(journalctl -k -b -o cat --no-pager)"
fi

headers="$(printf '%s\n' "$log" | sed -nE "/${HEADER_RE}/p")"
revisions="$(printf '%s\n' "$headers" | sed -nE "s/.*${HEADER_RE}.*/\1/p" | tr '[:lower:]' '[:upper:]' | sort -u)"

if [[ -z "$headers" || -z "$revisions" ]]; then
    fail_check "No DSDT table header in the current boot kernel log"
fi

revision_count="$(wc -l <<<"$revisions")"
if ((revision_count != 1)); then
    joined="${revisions//$'\n'/, }"
    fail_check "Current boot kernel log contains DSDT OEM revisions ${joined}; expected ${EXPECTED_REVISION}" "$headers"
fi

found="${revisions}"
if [[ "$found" != "$EXPECTED_REVISION" ]]; then
    fail_check "DSDT OEM revision is ${found}; expected ${EXPECTED_REVISION}" "$headers"
fi

printf '%s\n' "$headers"
printf 'OEM revision %s\n' "$EXPECTED_REVISION"
printf 'matching\n'
