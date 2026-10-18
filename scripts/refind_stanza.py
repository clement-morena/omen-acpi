# Copyright (C) 2026 Paolo De Marinis
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure rEFInd stanza edits.

This module does not read firmware, call iasl, or write a boot file. omen-acpi
uses it so an install can append one marked block and a removal can delete
that block without rewriting any other line.
"""

from __future__ import annotations

import re

BEGIN = "# BEGIN omen-acpi-refind s5"
END = "# END omen-acpi-refind s5"
DEFAULT_TITLE = "Pop!_OS (omen-acpi s5 fix)"
_UNSAFE_TITLE = set('"\r\n\\{}')

# Lines that select the default entry, the menu timeout, or what rEFInd scans.
# An append or removal must leave every one of these lines byte-identical.
_PROTECTED = re.compile(
    r"^[ \t]*(?:"
    r"default_selection|timeout|scanfor|scan_delay|use_nvram|"
    r"firmware_bootnum|dont_scan_\w*|also_scan_dirs"
    r")\b.*$"
)
_OPTION_LINE = re.compile(
    r'^"([^"]*)"[ \t]+"([^"]*)"[ \t]*$'
)
_GUID = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class StanzaError(ValueError):
    """The config change would not be an exact owned-block edit."""


def validate_title(title: str) -> str:
    """Return a menu title that can sit inside one quoted rEFInd menuentry."""

    if not isinstance(title, str) or not title or title != title.strip():
        raise StanzaError("menu title is empty or has surrounding whitespace")
    if len(title) > 80 or any(char in title for char in _UNSAFE_TITLE):
        raise StanzaError(
            "menu title must be 1-80 characters and must not contain "
            'quotes, braces, or backslashes'
        )
    return title


def menuentry_line(title: str) -> str:
    return f'menuentry "{validate_title(title)}"'


def debian_family(os_release: str) -> bool:
    """True when ID or ID_LIKE contains debian or ubuntu.

    Pop!_OS sets ID=pop and ID_LIKE="ubuntu debian", so it matches through
    ID_LIKE. A distribution that sets neither token does not.
    """

    tokens: list[str] = []
    for line in os_release.splitlines():
        if line.startswith("ID=") or line.startswith("ID_LIKE="):
            value = line.split("=", 1)[1].strip().strip('"').strip("'")
            tokens.extend(value.split())
    return any(token in {"debian", "ubuntu"} for token in tokens)


def protected_lines(text: str) -> tuple[str, ...]:
    return tuple(
        line for line in text.splitlines() if _PROTECTED.match(line)
    )


def parse_linux_options(text: str) -> str:
    """Return the first boot-option string from refind_linux.conf.

    The companion must copy that string. It must not invent options, and it
    must not accept a line that already names an initrd: rEFInd applies this
    file to every auto-detected kernel.
    """

    chosen = None
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = _OPTION_LINE.fullmatch(line)
        if match is None:
            raise StanzaError(
                f"refind_linux.conf line {line_number} is not a quoted "
                "description and option pair"
            )
        chosen = match.group(2)
        break
    if chosen is None:
        raise StanzaError("refind_linux.conf has no boot option line")
    if "initrd=" in chosen or "\n" in chosen or '"' in chosen:
        raise StanzaError(
            "refind_linux.conf options already name an initrd or contain "
            "a quote; refusing to copy them onto a manual stanza"
        )
    if not chosen or any(char in chosen for char in "{}\\"):
        raise StanzaError("refind_linux.conf options are empty or unsafe")
    return chosen


def render_stanza(
    *,
    kernel: str,
    partuuid: str,
    loader: str,
    initrd: str,
    options: str,
    title: str = DEFAULT_TITLE,
) -> str:
    entry = menuentry_line(title)
    for label, value in (
        ("kernel", kernel),
        ("partuuid", partuuid),
        ("loader", loader),
        ("initrd", initrd),
    ):
        if not value or any(char in value for char in " \t\r\n\"'{}\\"):
            raise StanzaError(f"unsafe {label} value")
    if _GUID.fullmatch(partuuid) is None:
        raise StanzaError(f"volume is not a PARTUUID: {partuuid}")
    if not loader.startswith("/") or not initrd.startswith("/"):
        raise StanzaError("loader and initrd paths must be volume-absolute")
    if ".." in (loader, initrd):
        raise StanzaError("loader or initrd path contains '..'")
    if parse_linux_options(f'"check" "{options}"\n') != options:
        raise StanzaError("stanza options failed the linux.conf checks")
    # rEFInd 0.13 stores one initrd token. A second initrd line replaces the
    # first, so the override must already be concatenated onto the front of
    # the stock initrd in that single file.
    return (
        f"{BEGIN}\n"
        f"# owned=v1 variant=s5 kernel={kernel} partuuid={partuuid}\n"
        "# Experimental. Not the default. Select the normal Linux icon to return to stock.\n"
        "# Single initrd: uncompressed ACPI CPIO concatenated in front of the stock initrd.\n"
        f"{entry} {{\n"
        f"    volume {partuuid}\n"
        f"    loader {loader}\n"
        f"    initrd {initrd}\n"
        f'    options "{options}"\n'
        "}\n"
        f"{END}\n"
    )


def _with_trailing_newline(text: str) -> str:
    if text == "" or text.endswith("\n"):
        return text
    return text + "\n"


def replace_owned_stanza(text: str, stanza: str) -> str:
    cleared = remove_stanza(text)
    updated = append_stanza(cleared, stanza)
    if protected_lines(updated) != protected_lines(text):
        raise StanzaError(
            "replacement would change default_selection, timeout, or scan options"
        )
    return updated


def _title_line(stanza: str) -> str:
    for line in stanza.splitlines():
        if line.startswith('menuentry "'):
            return line
    raise StanzaError("stanza has no menuentry")


def append_stanza(text: str, stanza: str) -> str:
    title_line = _title_line(stanza)
    if BEGIN in text or END in text or title_line in text:
        raise StanzaError(
            "refind.conf already contains an omen-acpi stanza; remove it first"
        )
    if not stanza.startswith(BEGIN + "\n") or not stanza.endswith(END + "\n"):
        raise StanzaError("refusing to append a block this companion does not own")
    if stanza.count(BEGIN) != 1 or stanza.count(END) != 1:
        raise StanzaError("stanza markers are not unique")
    updated = _with_trailing_newline(text) + stanza
    if protected_lines(updated) != protected_lines(text):
        raise StanzaError(
            "append would change default_selection, timeout, or scan options"
        )
    if not updated.endswith(stanza) or title_line not in updated:
        raise StanzaError("append did not place the stanza at the end")
    return updated


def remove_stanza(text: str) -> str:
    begin = text.find(BEGIN)
    end = text.find(END)
    if begin < 0 and end < 0:
        raise StanzaError("refind.conf has no omen-acpi stanza")
    if begin < 0 or end < 0 or end < begin or text.find(BEGIN, begin + 1) >= 0:
        raise StanzaError("omen-acpi stanza markers are missing or duplicated")
    end_of_block = end + len(END)
    if text[end_of_block:end_of_block + 1] == "\n":
        end_of_block += 1
    title_line = _title_line(text[begin:end_of_block])
    updated = text[:begin] + text[end_of_block:]
    if BEGIN in updated or END in updated or title_line in updated:
        raise StanzaError("removal left part of the omen-acpi stanza behind")
    if protected_lines(updated) != protected_lines(text):
        raise StanzaError(
            "removal would change default_selection, timeout, or scan options"
        )
    return updated
