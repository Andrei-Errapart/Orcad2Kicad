# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Builders for synthetic OrCAD page/cache streams and ZIP-packaged fixtures.

`olefile` is read-only, so synthetic `.DSN` inputs are authored as ZIP archives
(see scripts/ole_zip.py) whose members are the OLE streams. ZIP removes the
*container* barrier; these helpers remove the *record-encoding* tedium by
emitting the exact binary records the dsn2kicad parsers read.

Each builder mirrors a specific parser in scripts/dsn2kicad.py and is covered by
round-trip tests in test_dsn_fixtures.py:
  - make_page  -> parse_page_header / parse_net_table / parse_wires / parse_components
  - make_cache -> parse_cache_cells
  - make_zip   -> ole_zip.ZipOleFile

Typical use:
    page = make_page("01_PWR", nets={5: "GND"}, wires=[(5, 0, 0, 100, 0)],
                     components=[("RES", "R1", 0)])
    cache = make_cache({"RES": [("1", -10, 10, 0, 10, 0x20)]})
    dsn = make_zip({"Views/SCHEMATIC1/Pages/Page1": page, "Cache": cache})
"""
import io
import struct
import zipfile

#: Page-stream record marker (see RECORD_MARKER in dsn2kicad.py).
RECORD_MARKER = b"\xff\xe4\x5c\x39"
#: 12-byte sequence that precedes a page's net-name table.
NET_TABLE_ANCHOR = b"\x30\x00\x00\x00\x05\x00\x00\x00\x03\x00\x00\x00"


def _page_header(name, paper):
    """marker + zeros(4) + name_len_u16 + name + NUL + paper_len_u16 + paper + NUL."""
    nb = name.encode("ascii")
    pb = paper.encode("ascii")
    return (RECORD_MARKER + b"\x00\x00\x00\x00"
            + struct.pack("<H", len(nb)) + nb + b"\x00"
            + struct.pack("<H", len(pb)) + pb + b"\x00")


def _net_table(nets):
    """anchor + extra_count_u16(0) + net_count_u16 + per-net(len_u16+name+NUL+id_u32)."""
    out = bytearray(NET_TABLE_ANCHOR)
    out += struct.pack("<H", 0)             # no skip list
    out += struct.pack("<H", len(nets))
    for net_id, name in nets.items():
        nb = name.encode("ascii")
        out += struct.pack("<H", len(nb)) + nb + b"\x00" + struct.pack("<I", net_id)
    return bytes(out)


def _wire(record_id, net_id, x1, y1, x2, y2):
    """marker + zeros(4) + record_id_u32 + net_id_u32 + 0x30_u32 + x1 y1 x2 y2 (i32)."""
    return (RECORD_MARKER + struct.pack("<I", 0)
            + struct.pack("<I", record_id)
            + struct.pack("<I", net_id)
            + struct.pack("<I", 0x30)
            + struct.pack("<iiii", x1, y1, x2, y2))


def _component(cell, ref, value_idx=0):
    """<cell>.Normal NUL + 16 placement bytes + 0x18 + ref_len_u16 + ref + NUL + value_idx_u16."""
    token = cell.encode("ascii") + b".Normal\x00"
    rb = ref.encode("ascii")
    return (token + bytes(16)
            + bytes([0x18]) + struct.pack("<H", len(rb)) + rb + b"\x00"
            + struct.pack("<H", value_idx))


def make_page(name, paper="A3", *, nets=None, wires=None, components=None):
    """Build a synthetic page stream.

    Args:
        name: page name (e.g. "01_PWR").
        paper: paper size string (A0..A4 / A..E); default "A3".
        nets: {net_id: net_name} for the net table; omitted if falsy.
        wires: list of (net_id, x1, y1, x2, y2); coords are OrCAD units, abs<5000.
            (Avoid x1==5 and y1==3 together — that byte pattern collides with the
            net-table anchor.)
        components: list of (cell, ref) or (cell, ref, value_idx).

    The header is emitted first (so parse_page_header reads it) and the net table
    last (so it wins as the "last anchor" parse_net_table selects).
    """
    parts = [_page_header(name, paper)]
    for i, (net_id, x1, y1, x2, y2) in enumerate(wires or []):
        parts.append(_wire(i + 1, net_id, x1, y1, x2, y2))
    for comp in components or []:
        cell, ref = comp[0], comp[1]
        value_idx = comp[2] if len(comp) > 2 else 0
        parts.append(_component(cell, ref, value_idx))
    if nets:
        parts.append(_net_table(nets))
    # Trailing padding: parse_components reads ~11 bytes of lookahead past a
    # component's ref record, which real streams always have (more records
    # follow). Pad so the final component parses even with nothing after it.
    parts.append(b"\x00" * 32)
    return b"".join(parts)


def make_cache(cells):
    """Build a synthetic Cache stream.

    Args:
        cells: {cell_name: [pin, ...]} where each pin is the tuple
            parse_cache_cells returns:
            (pin_name, hot_x, hot_y, body_x, body_y, pin_flags).
    """
    out = bytearray()
    for cell_name, pins in cells.items():
        out += cell_name.encode("ascii") + b".Normal\x00"
        for pin_name, hot_x, hot_y, body_x, body_y, pin_flags in pins:
            pb = pin_name.encode("ascii")
            out += (RECORD_MARKER + struct.pack("<I", 0)
                    + struct.pack("<H", len(pb)) + pb + b"\x00"
                    + struct.pack("<iiii", body_x, body_y, hot_x, hot_y)
                    + bytes([pin_flags]) + bytes(24))
    return bytes(out)


def make_zip(members):
    """Pack {member_name: bytes} into a ZIP archive and return its bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)
    return buf.getvalue()
