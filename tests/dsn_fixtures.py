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
  - make_cache_pin_numbers -> _parse_cache_pin_numbers
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


def _component(
    cell, ref, value_idx=0, x=0, y=0, orient=0, page_pins=None,
    display_fields=None,
):
    """Build a placed component record with its reference property."""
    token = cell.encode("ascii") + b".Normal\x00"
    rb = ref.encode("ascii")
    placement = bytearray(22)
    struct.pack_into("<hh", placement, 6, x, y)
    struct.pack_into("<hh", placement, 12, x, y)
    placement[16:18] = bytes([0x30, orient])
    struct.pack_into("<H", placement, 20, len(display_fields or []))
    result = bytearray(
        token + bytes(placement)
    )
    for property_idx, off_x, off_y, rotation in display_fields or []:
        result += (
            RECORD_MARKER
            + struct.pack("<IIhhH", 0, property_idx, off_x, off_y, rotation << 14)
        )
    result += (
        bytes([0x18]) + struct.pack("<H", len(rb)) + rb + b"\x00"
        + struct.pack("<H", value_idx)
    )
    for pin_num, pin_x, pin_y, net_id in page_pins or []:
        result += (
            RECORD_MARKER
            + struct.pack("<I", 0)
            + struct.pack("<Hhh", pin_num, pin_x, pin_y)
            + bytes(4)
            + struct.pack("<I", net_id)
        )
    return bytes(result)


def _graphic_wrapper(color_idx, payload):
    """Wrap a page primitive with StructGraphicInst color metadata."""
    prefix = bytearray(37)
    prefix[0] = color_idx
    return bytes(prefix) + RECORD_MARKER + bytes(14) + payload


def _page_graphic(kind, coords, color_idx=48, *, line_style=0, line_width=3,
                  fill_style=1, points=None):
    tags = {
        "rectangle": b"\x01\x00\x28\x28\x28\x00",
        "line": b"\x01\x00\x29\x29\x20\x00",
        "ellipse": b"\x01\x00\x2b\x2b\x28\x00",
        "polygon": b"\x01\x00\x2c\x2c\x2e\x00",
    }
    if kind == "polygon":
        vertices = list(points or [])
        payload = bytearray(tags[kind] + bytes(14))
        payload += struct.pack("<I", fill_style)
        payload += bytes(4)
        payload += struct.pack("<H", len(vertices))
        for x, y in vertices:
            payload += struct.pack("<HH", y, x)
        return _graphic_wrapper(color_idx, bytes(payload))

    x1, y1, x2, y2 = coords
    payload = bytearray(tags[kind] + bytes(6) + struct.pack(
        "<iiii", x1, y1, x2, y2,
    ))
    if kind in {"rectangle", "ellipse"}:
        payload += struct.pack("<IIIi", line_style, line_width, fill_style, -1)
    else:
        payload += bytes(8)
    return _graphic_wrapper(color_idx, bytes(payload))


def _page_text(text, bbox, style_id=1, color_idx=48):
    text_bytes = text.encode("ascii")
    x1, y1, x2, y2 = bbox
    payload = bytearray(b"\x01\x00\x2e\x2e")
    payload += struct.pack("<II", 38 + len(text_bytes), 0)
    payload += struct.pack("<IIIIII", x1, y1, x2, y2, x1, y1)
    payload += struct.pack("<HHH", style_id, 0, len(text_bytes))
    payload += text_bytes
    return _graphic_wrapper(color_idx, bytes(payload))


def _power_symbol(
    record_name, hot_x, hot_y, rotation=0, display_prop=None,
):
    """Build a power-port placement with its electrical hotpoint at (x, y)."""
    upper = record_name.upper()
    is_ground = (
        upper in {
            "GND", "AGND", "PGND", "VSS", "DGND", "SGND", "ADAVSS",
            "GROUND", "GND_POWER", "AG",
        }
        or upper.startswith("GND")
        or upper.startswith("GROUND")
        or upper.endswith("_VSS")
    )
    anchor_x, anchor_y = 10, 0 if is_ground else 10
    width, height = 20, 10
    rotation %= 4
    if rotation == 0:
        x1, y1 = hot_x - anchor_x, hot_y - anchor_y
    elif rotation == 1:
        x1, y1 = hot_x - anchor_y, hot_y - (width - anchor_x)
    elif rotation == 2:
        x1, y1 = hot_x - (width - anchor_x), hot_y - (height - anchor_y)
    else:
        x1, y1 = hot_x - (height - anchor_y), hot_y - anchor_x

    name = record_name.encode("ascii")
    coords = (hot_y, hot_x, y1 + height, x1 + width, x1, y1)
    result = bytearray(
        RECORD_MARKER
        + struct.pack("<I", 0)
        + struct.pack("<I", 1)
        + struct.pack("<I", 0)
        + struct.pack("<H", len(name))
        + name
        + b"\x00"
        + struct.pack("<I", 1)
        + struct.pack("<6h", *coords)
        + struct.pack("<H", rotation << 8)
        + struct.pack("<HH", 0, 1 if display_prop else 0)
    )
    if display_prop:
        off_x, off_y, text_rotation = display_prop
        result += (
            RECORD_MARKER
            + struct.pack("<IIhhH", 0, 1, off_x, off_y, text_rotation << 14)
            + b"\x00"
        )
    return bytes(result)


def _off_page_connector(record_id, record_name, bbox, orientation=0):
    """Build an off-page connector whose hotpoint is one edge of bbox."""
    name = record_name.encode("ascii")
    x1, y1, x2, y2 = bbox
    coords = (y1, x1, y2, x2, x1, y1)
    display_prop = (
        RECORD_MARKER
        + struct.pack("<IIhhH", 0, 0, 0, 0, 0)
        + bytes(4)
    )
    return (
        RECORD_MARKER
        + struct.pack("<IIIH", 0, record_id, 0, len(name))
        + name
        + b"\x00"
        + struct.pack("<I6h", record_id, *coords)
        + bytes([0x30, orientation, 0x26, 0])
        + struct.pack("<H", 1)
        + display_prop
        + b"\x23"
        + bytes(5)
    )


def make_page(
    name, paper="A3", *, nets=None, wires=None, components=None,
    power_symbols=None, off_page_connectors=None, texts=None, graphics=None,
):
    """Build a synthetic page stream.

    Args:
        name: page name (e.g. "01_PWR").
        paper: paper size string (A0..A4 / A..E); default "A3".
        nets: {net_id: net_name} for the net table; omitted if falsy.
        wires: list of (net_id, x1, y1, x2, y2); coords are OrCAD units, abs<5000.
            (Avoid x1==5 and y1==3 together — that byte pattern collides with the
            net-table anchor.)
        components: list of (cell, ref), (cell, ref, value_idx),
            (cell, ref, value_idx, x, y, orient), or that six-tuple followed by
            page pin records [(pin_number, x, y, net_id), ...].
            An optional eighth item contains display fields as
            [(property_index, x_offset, y_offset, quarter_turns), ...].
        power_symbols: list of (record_name, hot_x, hot_y) or
            (record_name, hot_x, hot_y, quarter_turns, display_prop), where a
            display property is (x_offset, y_offset, text_quarter_turns).
        off_page_connectors: list of (record_name, (x1, y1, x2, y2)), optionally
            followed by an OrCAD orientation value (0..7). The connector's
            electrical hotpoint is derived from the bbox and orientation.
        texts: list of (text, bbox), optionally followed by style and color IDs.
        graphics: dictionaries accepted by `_page_graphic`.

    The header is emitted first (so parse_page_header reads it) and the net table
    last (so it wins as the "last anchor" parse_net_table selects).
    """
    parts = [_page_header(name, paper)]
    for i, (net_id, x1, y1, x2, y2) in enumerate(wires or []):
        parts.append(_wire(i + 1, net_id, x1, y1, x2, y2))
    for comp in components or []:
        cell, ref = comp[0], comp[1]
        value_idx = comp[2] if len(comp) > 2 else 0
        x = comp[3] if len(comp) > 3 else 0
        y = comp[4] if len(comp) > 4 else 0
        orient = comp[5] if len(comp) > 5 else 0
        page_pins = comp[6] if len(comp) > 6 else None
        display_fields = comp[7] if len(comp) > 7 else None
        parts.append(_component(
            cell, ref, value_idx, x, y, orient, page_pins, display_fields,
        ))
    for power_symbol in power_symbols or []:
        record_name, hot_x, hot_y = power_symbol[:3]
        rotation = power_symbol[3] if len(power_symbol) > 3 else 0
        display_prop = power_symbol[4] if len(power_symbol) > 4 else None
        parts.append(_power_symbol(
            record_name, hot_x, hot_y, rotation, display_prop,
        ))
    for record_id, connector in enumerate(off_page_connectors or [], start=1):
        record_name, bbox = connector[:2]
        orientation = connector[2] if len(connector) > 2 else 0
        parts.append(_off_page_connector(
            record_id, record_name, bbox, orientation,
        ))
    for text in texts or []:
        value, bbox = text[:2]
        style_id = text[2] if len(text) > 2 else 1
        color_idx = text[3] if len(text) > 3 else 48
        parts.append(_page_text(value, bbox, style_id, color_idx))
    for graphic in graphics or []:
        parts.append(_page_graphic(**graphic))
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


def make_cache_pin_numbers(cells):
    """Build ordered physical pin-number lists for Cache cells.

    Args:
        cells: {cell_name: [pin_number, ...]}. Each list needs at least two
            entries because that is the minimum accepted by the Cache parser.
    """
    out = bytearray()
    for cell_name, pin_numbers in cells.items():
        out += cell_name.encode("ascii") + b"\x00"
        out += struct.pack("<H", len(pin_numbers))
        for pin_number in pin_numbers:
            number_bytes = str(pin_number).encode("ascii")
            out += struct.pack("<H", len(number_bytes))
            out += number_bytes + b"\x7f"
    return bytes(out)


def make_library_styles(styles):
    """Build 60-byte LOGFONT-style Library records.

    Each style is (height, weight, italic, escapement, face).
    """
    out = bytearray()
    for height, weight, italic, escapement, face in styles:
        record = bytearray(60)
        struct.pack_into("<i", record, 0, -abs(height))
        struct.pack_into("<i", record, 8, escapement)
        struct.pack_into("<I", record, 16, weight)
        record[20] = 0xFF if italic else 0
        face_bytes = face.encode("ascii")[:29]
        record[28:28 + len(face_bytes)] = face_bytes
        out += record
    return bytes(out)


def make_library(values, styles=None):
    """Build the parsed prefix of an OrCAD Library stream."""
    out = bytearray(32)
    intro = b"OrCAD Windows Design"
    out[:len(intro)] = intro
    out += struct.pack("<HHIII", 1, 0, 0, 0, 0)
    out += struct.pack("<H", len(styles or []) + 1)
    out += make_library_styles(styles or [])
    out += struct.pack("<H", 0)
    out += bytes(8)
    for _ in range(8):
        out += struct.pack("<H", 1) + b"x\x00"
    out += bytes(156)
    out += struct.pack("<I", len(values))
    for value in values:
        encoded = value.encode("ascii")
        out += struct.pack("<H", len(encoded)) + encoded + b"\x00"
    return bytes(out)


def make_zip(members):
    """Pack {member_name: bytes} into a ZIP archive and return its bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)
    return buf.getvalue()
