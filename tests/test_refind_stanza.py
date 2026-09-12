#!/usr/bin/env python3
# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import refind_stanza  # noqa: E402


OPTIONS = (
    "root=UUID=97561647-b568-454a-8477-d21017e2beb0 ro quiet "
    "loglevel=0 systemd.show_status=false splash nvidia-drm.modeset=1"
)
STOCK = """\
timeout 20
default_selection "+"
scanfor manual,external
menuentry "Existing" {
    loader /boot/vmlinuz-stock
}
"""


class RefindStanzaTest(unittest.TestCase):
    def stanza(self) -> str:
        return refind_stanza.render_stanza(
            kernel="7.1.5-76070105-generic",
            partuuid="bbe69c12-5d12-4cc8-8480-da3ca883be48",
            loader="/boot/vmlinuz-7.1.5-76070105-generic",
            initrd="/boot/omen-acpi/s5-initrd.img",
            options=OPTIONS,
        )

    def test_append_keeps_default_and_scan_lines(self) -> None:
        stanza = self.stanza()
        updated = refind_stanza.append_stanza(STOCK, stanza)
        self.assertEqual(
            refind_stanza.protected_lines(updated),
            refind_stanza.protected_lines(STOCK),
        )
        self.assertIn('menuentry "Existing"', updated)
        self.assertTrue(updated.endswith(stanza))
        self.assertEqual(updated.count("    initrd "), 1)
        self.assertIn("    initrd /boot/omen-acpi/s5-initrd.img\n", updated)
        self.assertNotIn("initrd /boot/initrd.img-", updated)
        self.assertNotIn("default_selection", stanza)
        with self.assertRaises(refind_stanza.StanzaError):
            refind_stanza.append_stanza(updated, stanza)

    def test_replace_keeps_protected_lines(self) -> None:
        first = self.stanza()
        installed = refind_stanza.append_stanza(STOCK, first)
        replacement = refind_stanza.render_stanza(
            kernel="7.1.5-76070105-generic",
            partuuid="bbe69c12-5d12-4cc8-8480-da3ca883be48",
            loader="/boot/vmlinuz-7.1.5-76070105-generic",
            initrd="/boot/omen-acpi/s5-initrd.img",
            options=OPTIONS,
        )
        updated = refind_stanza.replace_owned_stanza(installed, replacement)
        self.assertEqual(
            refind_stanza.protected_lines(updated),
            refind_stanza.protected_lines(STOCK),
        )
        self.assertEqual(updated.count("    initrd "), 1)

    def test_remove_restores_the_original_text(self) -> None:
        updated = refind_stanza.append_stanza(STOCK, self.stanza())
        self.assertEqual(refind_stanza.remove_stanza(updated), STOCK)

    def test_linux_conf_options_are_copied_and_initrd_is_rejected(self) -> None:
        text = (
            f'"Boot with standard options"  "{OPTIONS}"\n'
            '"Boot to single-user mode"    "ro single"\n'
        )
        self.assertEqual(refind_stanza.parse_linux_options(text), OPTIONS)
        with self.assertRaises(refind_stanza.StanzaError):
            refind_stanza.parse_linux_options(
                '"Boot"  "ro quiet initrd=boot\\\\omen-acpi\\\\s5-early.cpio"\n'
            )


if __name__ == "__main__":
    unittest.main()
