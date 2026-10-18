#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OMEN="$ROOT/omen-acpi"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

config="$tmp/config"
desktop="$config/autostart/omen-acpi-dsdt-check.desktop"

XDG_CONFIG_HOME="$config" "$OMEN" --internal-enable-startup-check >/dev/null
[[ -f "$desktop" && ! -L "$desktop" ]]
grep -Fq 'X-OMEN-ACPI-Startup-Check=1' "$desktop"
grep -Fq 'Terminal=false' "$desktop"
grep -Fq -- "${ROOT}/scripts/check-dsdt-revision.sh --startup" "$desktop"

report="$(XDG_CONFIG_HOME="$config" "$OMEN" --internal-report-startup-check)"
[[ "$report" == "startup_check=enabled ${ROOT}/scripts/check-dsdt-revision.sh" ]]

removed="$(XDG_CONFIG_HOME="$config" "$OMEN" --internal-disable-startup-check)"
[[ ! -e "$desktop" ]]
grep -Fq 'Removed the login check' <<<"$removed"

absent="$(XDG_CONFIG_HOME="$config" "$OMEN" --internal-disable-startup-check)"
grep -Fq 'No login DSDT revision check was installed.' <<<"$absent"

disabled="$(XDG_CONFIG_HOME="$config" "$OMEN" --internal-report-startup-check)"
[[ "$disabled" == "startup_check=disabled" ]]

mkdir -p -- "$config/autostart"
printf 'not ours\n' >"$desktop"
kept="$(XDG_CONFIG_HOME="$config" "$OMEN" --internal-disable-startup-check 2>&1)"
[[ -f "$desktop" ]]
grep -Fq 'not the omen-acpi login check' <<<"$kept"

help_text="$("$OMEN" --help)"
grep -Fq 'graphical login' <<<"$help_text"
grep -Fq 'Run the DSDT revision check at each graphical login' <<<"$(
    # The question is in the install body, not --help. Confirm the source still asks it.
    grep -F 'ask_yes_no "Run the DSDT revision check at each graphical login?"' "$OMEN"
)"

printf 'startup-check: PASS\n'
