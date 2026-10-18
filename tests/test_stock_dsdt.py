#!/usr/bin/env python3
#
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""The collector accepts only a stock HPQOEM 8E35 DSDT at revision 0x01072009."""

from __future__ import annotations

from hashlib import sha256
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
COLLECT = ROOT / "scripts" / "01-collect-acpi.sh"
OEM_ID = b"HPQOEM"
TABLE_ID = b"8E35    "
STOCK_REVISION = 0x01072009


def table(*, revision: int = STOCK_REVISION, oem: bytes = OEM_ID, table_id: bytes = TABLE_ID, broken_checksum: bool = False) -> bytes:
    header = bytearray(36)
    header[0:4] = b"DSDT"
    struct.pack_into("<I", header, 4, 36)
    header[8] = 2
    header[10:16] = oem
    header[16:24] = table_id
    struct.pack_into("<I", header, 24, revision)
    header[28:32] = b"INTL"
    checksum = (-sum(header)) & 0xFF
    header[9] = (checksum + 1) & 0xFF if broken_checksum else checksum
    return bytes(header)


class StockDsdtTest(unittest.TestCase):
    def run_check(self, data: bytes) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "DSDT"
            path.write_bytes(data)
            return subprocess.run(
                [str(COLLECT), "--internal-stock-dsdt-sha", str(path)],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_stock_table_returns_its_sha256(self) -> None:
        data = table()
        result = self.run_check(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), sha256(data).hexdigest())

    def test_override_revision_is_rejected(self) -> None:
        result = self.run_check(table(revision=0x0107200A))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0x0107200A", result.stderr)
        self.assertIn("0x01072009", result.stderr)

    def test_wrong_identity_is_rejected(self) -> None:
        result = self.run_check(table(oem=b"OEMID "))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HPQOEM", result.stderr)

    def test_bad_checksum_is_rejected(self) -> None:
        result = self.run_check(table(broken_checksum=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr)


if __name__ == "__main__":
    unittest.main()
