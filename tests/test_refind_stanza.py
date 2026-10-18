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

    def test_default_title_and_custom_title(self) -> None:
        self.assertIn(
            'menuentry "Pop!_OS (omen-acpi s5 fix)" {',
            self.stanza(),
        )
        custom = refind_stanza.render_stanza(
            kernel="7.1.5-76070105-generic",
            partuuid="bbe69c12-5d12-4cc8-8480-da3ca883be48",
            loader="/boot/vmlinuz-7.1.5-76070105-generic",
            initrd="/boot/omen-acpi/s5-initrd.img",
            options=OPTIONS,
            title="Ubuntu (omen-acpi s5 fix)",
        )
        installed = refind_stanza.append_stanza(STOCK, custom)
        self.assertIn('menuentry "Ubuntu (omen-acpi s5 fix)" {', installed)
        self.assertEqual(refind_stanza.remove_stanza(installed), STOCK)
        with self.assertRaises(refind_stanza.StanzaError):
            refind_stanza.validate_title('bad "title"')

    def test_title_is_suffixed_with_the_kernel_version(self) -> None:
        kernel = "7.1.5-76070105-generic"
        default = refind_stanza.title_with_kernel(
            refind_stanza.DEFAULT_TITLE,
            kernel,
        )
        custom = refind_stanza.title_with_kernel(
            "Ubuntu (omen-acpi s5 fix)",
            kernel,
        )
        self.assertEqual(
            default,
            f"Pop!_OS (omen-acpi s5 fix) {kernel}",
        )
        self.assertEqual(custom, f"Ubuntu (omen-acpi s5 fix) {kernel}")
        self.assertIn(
            f'menuentry "{custom}" {{',
            refind_stanza.render_stanza(
                kernel=kernel,
                partuuid="bbe69c12-5d12-4cc8-8480-da3ca883be48",
                loader="/boot/vmlinuz-7.1.5-76070105-generic",
                initrd="/boot/omen-acpi/s5-initrd.img",
                options=OPTIONS,
                title=custom,
            ),
        )
        with self.assertRaises(refind_stanza.StanzaError):
            refind_stanza.title_with_kernel("Ubuntu (omen-acpi s5 fix)", "6.8 0")
        with self.assertRaises(refind_stanza.StanzaError):
            refind_stanza.title_with_kernel("U" * 70, kernel)

    def test_debian_family_ids(self) -> None:
        self.assertTrue(refind_stanza.debian_family('ID=debian\n'))
        self.assertTrue(refind_stanza.debian_family('ID=ubuntu\nID_LIKE=debian\n'))
        self.assertTrue(
            refind_stanza.debian_family('ID=pop\nID_LIKE="ubuntu debian"\n')
        )
        self.assertTrue(
            refind_stanza.debian_family('ID=linuxmint\nID_LIKE="ubuntu debian"\n')
        )
        self.assertFalse(refind_stanza.debian_family('ID=arch\nID_LIKE=archlinux\n'))
        self.assertFalse(refind_stanza.debian_family('ID=pop\n'))

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
