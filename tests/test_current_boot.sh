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

printf '%s\n' \
    'root=UUID=97561647-b568-454a-8477-d21017e2beb0 ro quiet initrd=\boot\omen-acpi\s5-initrd.img' \
    >"$tmp/backslash"
[[ "$("$OMEN" --internal-current-boot "$tmp/backslash")" == s5-test ]]

printf '%s\n' \
    'root=UUID=97561647-b568-454a-8477-d21017e2beb0 ro quiet initrd=/boot/omen-acpi/s5-initrd.img' \
    >"$tmp/slash"
[[ "$("$OMEN" --internal-current-boot "$tmp/slash")" == s5-test ]]

printf '%s\n' \
    'root=UUID=97561647-b568-454a-8477-d21017e2beb0 ro quiet initrd=\boot\initrd.img-7.1.5-76070105-generic' \
    >"$tmp/stock"
[[ "$("$OMEN" --internal-current-boot "$tmp/stock")" == not-this-stanza ]]

printf '%s\n' \
    'root=UUID=97561647-b568-454a-8477-d21017e2beb0 ro quiet' \
    >"$tmp/none"
[[ "$("$OMEN" --internal-current-boot "$tmp/none")" == not-this-stanza ]]

printf '%s\n' \
    'ro quiet initrd=\boot\omen-acpi\s5-initrd.img.old' \
    >"$tmp/suffix"
[[ "$("$OMEN" --internal-current-boot "$tmp/suffix")" == not-this-stanza ]]

live="$("$OMEN" --internal-current-boot /proc/cmdline)"
if grep -Fq $'omen-acpi\\s5-initrd.img' /proc/cmdline; then
    [[ "$live" == s5-test ]]
fi

printf 'current-boot: PASS\n'
