#!/usr/bin/env bash
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

printf 'syntax checks...\n'
bash -n omen-acpi
bash -n scripts/01-collect-acpi.sh
bash -n scripts/02-build-dsdt.sh
bash -n scripts/check-dsdt-revision.sh
grep -Fq '[[ "$EUID" -eq 0 || -r "$REFIND_CONF" ]]' omen-acpi
python3 -m py_compile scripts/refind_stanza.py

printf 'rEFInd stanza checks...\n'
python3 "$ROOT/tests/test_refind_stanza.py"

printf 'transform checks...\n'
python3 "$ROOT/tests/test_transform.py"

printf 'stock DSDT check...\n'
python3 "$ROOT/tests/test_stock_dsdt.py"

printf 'DSDT revision check...\n'
bash "$ROOT/tests/test_check_dsdt_revision.sh"

printf 'login check...\n'
bash "$ROOT/tests/test_startup_check.sh"

if [[ -f "$ROOT/docs/nvde-audit.py" ]]; then
    printf 'NVDE audit self-test...\n'
    python3 "$ROOT/docs/nvde-audit.py" --self-test
fi

printf 'help text...\n'
help_text="$(./omen-acpi --help)"
grep -Fq 'omen-acpi {install|repair|status|remove}' <<<"$help_text"
grep -Fq 'Pop!_OS (omen-acpi s5 fix)' <<<"$help_text"
grep -Fq 'graphical login' <<<"$help_text"

printf 'all tests: PASS\n'
