#!/usr/bin/env python3
"""Convert OrCAD Capture DSN schematics to KiCad format.

Parses the OLE compound document (.DSN file) to extract:
  - Net table from each page stream
  - Wire segments with net assignments
  - Component placements (cell name, reference, position, orientation)
  - Power symbol placements (GND, VCC, etc.)
  - Text annotations

Generates KiCad schematic files (.kicad_sch) with:
  - Proper wire segments
  - Net labels at wire endpoints
  - Component symbols from KiCad standard libraries
  - Power symbols
  - Text annotations

Usage:
    scripts/dsn2kicad [--kicad-power] [--debug-bbox] [--debug-ref-val]
                      [--debug-symbol] <file.DSN> [output_dir]
"""

import json
import math
import os
import hashlib
import random
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

try:
    import olefile
except ImportError:
    print("olefile not found. Install with: pip install olefile",
          file=sys.stderr)
    sys.exit(1)


# OrCAD coordinate unit: 10 mils = 0.254 mm
UNIT_TO_MM = 0.254

# OrCAD GlobalSymbol primitive coordinates use 5 mil units.
POWER_SYMBOL_UNIT_TO_MM = 0.127

# KiCad's outline-font renderer scales glyphs by this factor, so a `(size H H)`
# renders ~1.4*H tall. Divide a target rendered height by it when emitting (size).
KICAD_FONT_SIZE_COMPENSATION = 1.4

# Record marker in DSN page streams
RECORD_MARKER = bytes([0xFF, 0xE4, 0x5C, 0x39])

# Cell name pattern: name.Normal or name.Convert
CELL_RE = re.compile(rb'([A-Za-z0-9_./+\-()]+)\.(Normal|Convert)\x00')

# Reference designator pattern
REF_RE = re.compile(r'^[A-Z]{1,8}\d+[A-Z]?$')
GUID_RE = re.compile(r'^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-'
                     r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
                     r'[0-9A-Fa-f]{12}\}$')


_uuid_rng = random.Random(0)


def seed_uuid_rng(data: bytes, filename: str = ''):
    h = hashlib.sha256(data)
    if filename:
        h.update(filename.encode('utf-8'))
    _uuid_rng.seed(h.digest())


def new_uuid():
    b = bytes(_uuid_rng.getrandbits(8) for _ in range(16))
    b = bytearray(b)
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    return f"{b[0:4].hex()}-{b[4:6].hex()}-{b[6:8].hex()}-{b[8:10].hex()}-{b[10:16].hex()}"


def dsn_to_mm(coord):
    return round(coord * UNIT_TO_MM, 2)


def _top_level_child_spans(sexpr_text):
    """Yield (start, end) spans for direct children of the root S-expression."""
    depth = 0
    child_start = None
    in_string = False
    escape = False

    for i, ch in enumerate(sexpr_text):
        if in_string:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True
            continue
        if ch == '(':
            if depth == 1:
                child_start = i
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 1 and child_start is not None:
                yield child_start, i + 1
                child_start = None


def _replace_power_reference_in_block(block, ref):
    block = re.sub(
        r'(\(property\s+"Reference"\s+")#PWR\d*(")',
        rf'\g<1>{ref}\2',
        block,
        count=1,
    )
    block = re.sub(
        r'(\(reference\s+")#PWR\d*(")',
        rf'\g<1>{ref}\2',
        block,
        count=1,
    )
    return block


def annotate_power_references_in_schematic(content, start_index=1):
    """Assign deterministic unique references to top-level power symbols.

    KiCad annotates power symbols as hidden references such as #PWR0001 when
    opening a schematic. Doing it here keeps generated projects ready to open
    and makes test snapshots repeatable.

    Returns (annotated_content, next_index).
    """
    replacements = []
    next_index = start_index

    for start, end in _top_level_child_spans(content):
        block = content[start:end]
        if not block.startswith('(symbol') and not block.startswith('\t(symbol'):
            continue
        if not re.search(r'\(\s*lib_id\s+"power:', block):
            continue
        ref = f"#PWR{next_index:04d}"
        new_block = _replace_power_reference_in_block(block, ref)
        if new_block != block:
            replacements.append((start, end, new_block))
        next_index += 1

    if not replacements:
        return content, next_index

    parts = []
    pos = 0
    for start, end, new_block in replacements:
        parts.append(content[pos:start])
        parts.append(new_block)
        pos = end
    parts.append(content[pos:])
    return ''.join(parts), next_index


# ---------------------------------------------------------------------------
# DSN file parsing
# ---------------------------------------------------------------------------

def get_page_streams(ole):
    pages = []
    for entry in ole.listdir(streams=True, storages=False):
        path = "/".join(entry)
        if path.startswith("Views/SCHEMATIC1/Pages/"):
            pages.append(path)
    pages.sort()
    return pages


def parse_page_header(data):
    """Parse page header to extract page name and paper size.

    After the first ff e4 5c 39 marker + 4 zero bytes, the structure is:
      name_len(2) + name(name_len) + null(1) + paper_len(2) + paper(paper_len) + null(1)
    """
    page_name = ""
    paper_size = "A3"

    idx = data.find(RECORD_MARKER)
    if idx >= 0 and idx + 12 < len(data):
        name_pos = idx + 8
        name_len = struct.unpack_from('<H', data, name_pos)[0]
        if 1 <= name_len <= 50:
            name_start = name_pos + 2
            name_end = name_start + name_len
            if name_end < len(data):
                raw = data[name_start:name_end]
                if all(32 <= b < 127 for b in raw):
                    page_name = raw.decode('ascii')
                    paper_pos = name_end + 1
                    if paper_pos + 2 < len(data):
                        paper_len = struct.unpack_from('<H', data, paper_pos)[0]
                        if 1 <= paper_len <= 5:
                            paper_start = paper_pos + 2
                            paper_end = paper_start + paper_len
                            if paper_end < len(data):
                                ps = data[paper_start:paper_end].decode('ascii', errors='replace')
                                if ps in ('A0','A1','A2','A3','A4','A','B','C','D','E'):
                                    paper_size = ps

    if not page_name:
        strings = _extract_strings(data[:100], 3)
        for _, s in strings:
            if re.match(r'^\d{2}_', s) or len(s) > 3:
                page_name = s
                break

    return page_name, paper_size


def _extract_strings(data, min_len=2):
    strings = []
    current = bytearray()
    for i, b in enumerate(data):
        if 32 <= b < 127:
            current.append(b)
        else:
            if len(current) >= min_len:
                strings.append((i - len(current), current.decode("ascii")))
            current = bytearray()
    if len(current) >= min_len:
        strings.append((len(data) - len(current), current.decode("ascii")))
    return strings


_NET_TABLE_ANCHOR = b'\x30\x00\x00\x00\x05\x00\x00\x00\x03\x00\x00\x00'


def _parse_net_entries(data, pos, count):
    """Parse count net entries starting at pos. Each entry: len(2)+name(len)+null(1)+net_id(4)."""
    nets = {}
    for _ in range(count):
        if pos + 6 >= len(data):
            break
        nl = struct.unpack_from('<H', data, pos)[0]
        if nl < 1 or nl > 50:
            break
        ne = pos + 2 + nl
        if ne >= len(data) or data[ne] != 0:
            break
        nb = data[pos + 2:ne]
        if any(b < 32 or b > 126 for b in nb):
            break
        nid = struct.unpack_from('<I', data, ne + 1)[0]
        nets[nid] = nb.decode('ascii')
        pos = ne + 5
    return nets


def parse_net_table(data):
    """Parse the net name table from a page stream.

    The net table is preceded by the anchor sequence 30000000 05000000 03000000,
    followed by an optional skip list (count_u16 + count*4 bytes), then the net
    count (u16) and the net entries (len_u16 + name + null + net_id_u32 each).
    We locate the last anchor in the page whose trailing structure yields a valid
    net table.
    """
    nets = {}
    positions = []
    pos = 0
    while True:
        idx = data.find(_NET_TABLE_ANCHOR, pos)
        if idx < 0:
            break
        positions.append(idx)
        pos = idx + 1

    for anchor_pos in reversed(positions):
        after = anchor_pos + 12
        if after + 4 > len(data):
            continue
        extra_count = struct.unpack_from('<H', data, after)[0]
        net_count_pos = after + 2 + extra_count * 4
        if net_count_pos + 2 > len(data):
            continue
        net_count = struct.unpack_from('<H', data, net_count_pos)[0]
        if net_count < 1 or net_count > 1000:
            continue
        net_start = net_count_pos + 2
        nets = _parse_net_entries(data, net_start, net_count)
        if nets:
            break

    return nets


def parse_wires(data, net_table):
    """Extract wire segments from a page stream.

    Wire records have the marker followed by:
      zeros(4) + record_id(4) + net_id(4) + 0x30(4) + x1(4) + y1(4) + x2(4) + y2(4)

    Segments whose net name uses bus vector notation (e.g. DDR0_CAA[5..0])
    are tagged with 'bus': True.
    """
    wires = []
    pos = 0
    while True:
        idx = data.find(RECORD_MARKER, pos)
        if idx < 0:
            break
        if idx + 36 <= len(data):
            subtype = struct.unpack_from('<I', data, idx + 16)[0]
            if subtype == 0x30:
                net_id = struct.unpack_from('<I', data, idx + 12)[0]
                x1 = struct.unpack_from('<i', data, idx + 20)[0]
                y1 = struct.unpack_from('<i', data, idx + 24)[0]
                x2 = struct.unpack_from('<i', data, idx + 28)[0]
                y2 = struct.unpack_from('<i', data, idx + 32)[0]
                if abs(x1) < 5000 and abs(y1) < 5000 and abs(x2) < 5000 and abs(y2) < 5000:
                    net_name = net_table.get(net_id, '')
                    wires.append({
                        'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2,
                        'net_id': net_id, 'net': net_name,
                        'bus': is_bus_net(net_name),
                    })
        pos = idx + 4
    return wires


def parse_net_aliases(data, net_table):
    """Extract net-alias labels from a page stream.

    Net-alias records share the RECORD_MARKER and subtype 0x30 with wire
    records, but carry a name string instead of valid wire coordinates:
      RECORD_MARKER(4) + zeros(4) + x(4) + y(4) + 0x30(4)
      + zeros(4) + type(4) + name_len(u16) + name(name_len)

    The x,y at offsets +8/+12 are the alias position in OrCAD 10-mil units.
    """
    net_name_upper = {v.upper(): v for v in net_table.values()}
    aliases = []
    pos = 0
    while True:
        idx = data.find(RECORD_MARKER, pos)
        if idx < 0:
            break
        if idx + 36 <= len(data):
            subtype = struct.unpack_from('<I', data, idx + 16)[0]
            if subtype == 0x30:
                x1 = struct.unpack_from('<i', data, idx + 20)[0]
                if x1 == 0 and idx + 30 <= len(data):
                    name_len = struct.unpack_from('<H', data, idx + 28)[0]
                    if 1 <= name_len <= 100 and idx + 30 + name_len <= len(data):
                        raw = data[idx + 30:idx + 30 + name_len]
                        if all(0x20 <= b <= 0x7e for b in raw):
                            alias_name = raw.decode('ascii')
                            ax = struct.unpack_from('<I', data, idx + 8)[0]
                            ay = struct.unpack_from('<I', data, idx + 12)[0]
                            canon = net_name_upper.get(alias_name.upper(),
                                                      alias_name)
                            aliases.append({
                                'name': canon, 'x': ax, 'y': ay,
                            })
        pos = idx + 4
    return aliases


def _parse_pin_records(data, cell_end, search_end, net_table=None):
    """Parse pin placement records after a component instance.

    The component header at cell_end+20 contains a u16 LE count of
    non-pin marker records (ref/val position records and extra metadata)
    that precede the contiguous pin-record cluster. We skip that many
    markers, then collect pins.

    Pin record format: marker(4) + zeros(4) + pin_num(2) + pin_x(2) + pin_y(2).
    Pin numbers are 1-based indices into the Cache pin list for the cell.

    Once we've accepted at least one pin, stop as soon as the next marker
    is more than `PIN_STRIDE_MAX` bytes past the previous one — beyond
    that, we've left the contiguous pin-record cluster.

    When net_table is provided, also reads a net_id at offset +18 in each
    pin record and resolves it to a net name.
    """
    PIN_STRIDE_MAX = 50
    skip = struct.unpack_from('<H', data, cell_end + 20)[0] if cell_end + 22 <= len(data) else 0
    pins = []
    pin_nets = {}
    last_accepted = None
    skipped = 0
    pos = cell_end
    while pos < search_end - 14:
        idx = data.find(RECORD_MARKER, pos, search_end)
        if idx < 0:
            break
        if skipped < skip:
            skipped += 1
            pos = idx + 4
            continue
        if last_accepted is not None and idx - last_accepted > PIN_STRIDE_MAX:
            break
        if idx + 14 <= len(data):
            zeros = struct.unpack_from('<I', data, idx + 4)[0]
            pin_num = struct.unpack_from('<H', data, idx + 8)[0]
            px = struct.unpack_from('<h', data, idx + 10)[0]
            py = struct.unpack_from('<h', data, idx + 12)[0]
            if zeros == 0 and 1 <= pin_num <= 500 and (px or py):
                pins.append((pin_num, px, py))
                if net_table and idx + 22 <= len(data):
                    net_id = struct.unpack_from('<I', data, idx + 18)[0]
                    net_name = net_table.get(net_id)
                    if net_name:
                        pin_nets[(pin_num, px, py)] = {
                            'net_id': net_id,
                            'net': net_name,
                        }
                last_accepted = idx
        pos = idx + 4
    return pins, pin_nets


def parse_components(data, net_table=None):
    """Extract component placements from a page stream.

    Returns list of dicts with: cell, ref, x, y, orientation, pins.
    Pin positions are the actual page-space coordinates from the binary stream.
    """
    components = []
    cell_matches = list(CELL_RE.finditer(data))

    for ci, m in enumerate(cell_matches):
        cell_name = m.group(1).decode('ascii')
        cell_end = m.end()

        if cell_end + 16 > len(data):
            continue

        raw_x = struct.unpack_from('<h', data, cell_end + 6)[0]
        raw_y = struct.unpack_from('<h', data, cell_end + 8)[0]
        x, y = raw_x, raw_y
        # Instance placement point (OrCAD StructPlacedInstance locX/locY); the
        # display-prop (ref/value) text offsets are anchored relative to this.
        loc_x = struct.unpack_from('<h', data, cell_end + 12)[0]
        loc_y = struct.unpack_from('<h', data, cell_end + 14)[0]

        orient_byte = 0
        orient_search = data[cell_end + 16:cell_end + 22]
        if len(orient_search) >= 2 and orient_search[0] == 0x30:
            orient_byte = orient_search[1]

        ref_name = ''
        value_idx = None
        search_range = data[cell_end + 16:cell_end + 300]
        for j in range(len(search_range) - 10):
            if search_range[j] == 0x18:
                ref_len = struct.unpack_from('<H', search_range, j + 1)[0]
                if 1 <= ref_len <= 10:
                    ref_start = j + 3
                    ref_bytes = search_range[ref_start:ref_start + ref_len]
                    if all(32 <= b < 127 for b in ref_bytes):
                        candidate = ref_bytes.decode('ascii')
                        if REF_RE.match(candidate):
                            ref_name = candidate
                            vi_off = ref_start + ref_len + 1
                            if vi_off + 2 <= len(search_range):
                                value_idx = struct.unpack_from('<H', search_range, vi_off)[0]
                            break

        next_cell = cell_matches[ci + 1].start() if ci + 1 < len(cell_matches) else cell_end + 2000
        search_end = min(next_cell, cell_end + 20000, len(data))
        pins, pin_nets = _parse_pin_records(
            data, cell_end, search_end, net_table)

        # Parse ref/val text position offset records BEFORE origin refinement.
        # Two records with zeros==0 and type<0x100 precede the ref text tag:
        #   first  = reference position offset
        #   second = value position offset
        # Record format: MARKER(4) + zeros(4) + type_le32(4) + x(int16) + y(int16)
        #                + rotFontId(uint16) + ...
        # Per OpenOrCadParser StructSymbolDisplayProp, the uint16 at offset 16 is
        # {textFontIdx: bits 0-13, rotation: bits 14-15}; rotation is a 2-bit enum
        # (0/90/180/270) = the top 2 bits of byte 17. The display-prop x/y offsets
        # are page-space offsets from loc to the rendered text box's top-left
        # corner; do not rotate or mirror them with the component.
        _pos_records = []
        rp = cell_end
        rp_end = min(cell_end + 200, search_end)
        while rp < rp_end:
            ri = data.find(RECORD_MARKER, rp, rp_end)
            if ri < 0 or ri + 18 > len(data):
                break
            rz = struct.unpack_from('<I', data, ri + 4)[0]
            rt = struct.unpack_from('<I', data, ri + 8)[0]
            if rz == 0 and rt < 0x100:
                rx = struct.unpack_from('<h', data, ri + 12)[0]
                ry = struct.unpack_from('<h', data, ri + 14)[0]
                b16 = data[ri + 16]
                b17 = data[ri + 17]
                rot = ((b17 >> 6) & 0x3) * 90
                _pos_records.append((rx, ry, rot, b16, b17))
            rp = ri + 4

        if os.environ.get('DSNDEBUG_POS') and _pos_records:
            sys.stderr.write(
                f"POS\t{ref_name}\torient={orient_byte:#04x}\tcell={cell_name}\t"
                f"raw=({raw_x},{raw_y})\tloc=({loc_x},{loc_y})\t"
                + "\t".join(f"({r[0]},{r[1]},rot{r[2]},b16={r[3]:#04x},"
                            f"b17={r[4]:#04x})" for r in _pos_records)
                + "\n")

        # Refine component position from pin matching.
        # ox, oy = Cache body origin (0,0) in page coordinates.
        # OrCAD mirrors a symbol about the centre of its bounding box, so mirror
        # the cache-local coords about (bbox.x1 + bbox.x2). With the correct mirror
        # axis the reconstructed origin lands on `loc` (no drift), so the text —
        # which is anchored off this origin — falls into place for mirrored parts.
        origin_x, origin_y = None, None
        cache_pl = _cell_pin_lists.get(cell_name)
        # Mirror/rotate about the symbol's bbox centre (the body centre); fall
        # back to the pin-extent centre when no bbox is stored (e.g. the cache C).
        # (The pin-extent centre alone is wrong for single-pin parts, where it is
        # the pin itself rather than the symbol centre.)
        _mbox = _cell_bboxes.get(cell_name)
        if _mbox:
            center = ((_mbox[0] + _mbox[2]) / 2.0, (_mbox[1] + _mbox[3]) / 2.0)
        elif cache_pl:
            _pxs = [p[0] for p in cache_pl]
            _pys = [p[1] for p in cache_pl]
            center = ((min(_pxs) + max(_pxs)) / 2.0,
                      (min(_pys) + max(_pys)) / 2.0)
        else:
            center = (0.0, 0.0)
        if cache_pl and pins:
            matched_origin = _match_cache_pin_origin(
                cache_pl, pins, orient_byte, center)
            if matched_origin:
                origin_x, origin_y = matched_origin
                cc = _cell_centers[cell_name]
                rcc_x, rcc_y = _forward_rotate(cc[0], cc[1], orient_byte, center)
                x = round(origin_x + rcc_x)
                y = round(origin_y + rcc_y)
            else:
                if len(pins) >= 2:
                    origin_x = sum(p[1] for p in pins) / len(pins)
                    origin_y = sum(p[2] for p in pins) / len(pins)
                    x = round(origin_x)
                    y = round(origin_y)
        elif len(pins) >= 2:
            origin_x = sum(p[1] for p in pins) / len(pins)
            origin_y = sum(p[2] for p in pins) / len(pins)
            x = round(origin_x)
            y = round(origin_y)

        if os.environ.get('DSNDEBUG_ORIGIN') and origin_x is not None:
            sys.stderr.write(
                f"ORG\t{ref_name}\torient={orient_byte:#04x}\t"
                f"loc=({loc_x},{loc_y})\t"
                f"pinorigin=({origin_x:.0f},{origin_y:.0f})\t"
                f"diff=({origin_x-loc_x:.0f},{origin_y-loc_y:.0f})\n")

        # Convert offsets to absolute page positions using the component origin.
        # For Cache-defined cells, origin comes from pin matching.
        # For built-in cells (R, C), fall back to raw cell position.
        ref_pos = None
        val_pos = None
        ref_text_angle = None
        val_text_angle = None
        text_origin = None
        ref_off = None
        val_off = None
        if len(_pos_records) >= 2:
            ox = origin_x if origin_x is not None else raw_x
            oy = origin_y if origin_y is not None else raw_y
            # Text anchor: OrCAD stores ref/value offsets relative to loc, but for
            # 90/270 it snaps the body to grid. Horizontal text stays on loc while
            # the body may be pin-matched a half-grid away. For 0/180 loc == origin
            # either way, so this only matters for the rotated family.
            text_origin = (loc_x, loc_y)
            ref_off = (_pos_records[0][0], _pos_records[0][1])
            val_off = (_pos_records[1][0], _pos_records[1][1])
            # For 90/270 parts OrCAD stores horizontal ref/value text against
            # the instance loc, while the pin-matched body origin may be
            # grid-snapped away from it. Using the body origin shifts horizontal
            # labels by the body snap vector (notably inductors and mirrored
            # capacitor banks).
            if ((orient_byte & 0x03) in (0x01, 0x03)
                    and _pos_records[0][2] == 0):
                rtx, rty = loc_x, loc_y
            else:
                rtx, rty = ox, oy
            if ((orient_byte & 0x03) in (0x01, 0x03)
                    and _pos_records[1][2] == 0):
                vtx, vty = loc_x, loc_y
            else:
                vtx, vty = ox, oy
            ref_pos = (rtx + ref_off[0], rty + ref_off[1])
            val_pos = (vtx + val_off[0], vty + val_off[1])
            ref_text_angle = _pos_records[0][2]
            val_text_angle = _pos_records[1][2]

        components.append({
            'cell': cell_name,
            'ref': ref_name,
            'x': x,
            'y': y,
            'orient': orient_byte,
            'pins': pins,
            'ref_pos': ref_pos,
            'ref_text_angle': ref_text_angle,
            'val_text_angle': val_text_angle,
            'val_pos': val_pos,
            'text_origin': text_origin,
            'ref_off': ref_off,
            'val_off': val_off,
            'origin': (origin_x, origin_y) if origin_x is not None else None,
            'center': center,
            'value_idx': value_idx,
            'pin_nets': pin_nets,
        })

    return components


def parse_power_symbols(data, net_table):
    """Extract power symbol placements (GND, VCC, etc.).

    Power symbol records follow:
      marker + zeros(4) + rec_type(4) + header(4) + name_len(2) + name + null
      + cell_id(4) + x(2) + y(2) + ...

    Distinguished from component records by: marker is followed by 4 zero bytes,
    and the name does NOT end with ".Normal".
    """
    symbols = []
    pos = 0
    while True:
        idx = data.find(RECORD_MARKER, pos)
        if idx < 0:
            break
        if idx + 24 <= len(data):
            zeros = struct.unpack_from('<I', data, idx + 4)[0]
            if zeros == 0:
                name_len = struct.unpack_from('<H', data, idx + 16)[0]
                if 1 <= name_len <= 30:
                    name_start = idx + 18
                    name_end = name_start + name_len
                    if name_end + 5 < len(data) and data[name_end] == 0:
                        name_bytes = data[name_start:name_end]
                        if all(32 <= b < 127 for b in name_bytes):
                            name = name_bytes.decode('ascii')
                            if ('.Normal' in name or '.Convert' in name
                                    or 'TitleBlock' in name or 'Border' in name
                                    or 'OFFPAGE' in name):
                                pos = idx + 4
                                continue
                            if not is_power_symbol_record_name(name):
                                pos = idx + 4
                                continue
                            after_null = name_end + 1
                            if after_null + 18 <= len(data):
                                cell_id = struct.unpack_from('<I', data, after_null)[0]
                                coords = struct.unpack_from('<6h', data, after_null + 4)
                                orient = struct.unpack_from('<H', data, after_null + 16)[0]
                                x = coords[0]
                                y = coords[1]
                                symbols.append({
                                    'record_name': name,
                                    'name': name,
                                    'cell_id': cell_id,
                                    'coords': coords,
                                    'orient': orient,
                                    'x': x,
                                    'y': y,
                                })
        pos = idx + 4
    return symbols


def _power_symbol_logical_anchor(record_name):
    """Return the power-port anchor inside OrCAD's logical 20x10 box.

    GlobalSymbol primitive graphics are drawn inside a small local coordinate
    system, but the page instance record places the power port using a
    20-by-10 logical box. The extracted glyph tells which side carries the
    electrical terminal; the logical box gives the page-record scale.
    """
    record_name = record_name.upper()
    glyph = _orcad_power_glyphs.get(record_name)
    if glyph:
        primitives = glyph.get('primitives', [])
        points = _power_glyph_points(primitives)
        if points:
            xs = [p[0] for p in points]
            ys = [p[1] for p in points]
            anchor_x, anchor_y = _power_glyph_anchor(record_name, primitives)
            width = max(20, max(xs) - min(xs))
            height = max(10, max(ys) - min(ys))
            logical_x = width / 2
            if anchor_y == min(ys):
                logical_y = 0
            elif anchor_y == max(ys):
                logical_y = height
            else:
                logical_y = anchor_y - min(ys)
            return (logical_x, logical_y, width, height)

    # Fallback for DSNs where the Cache GlobalSymbol record is missing or not
    # yet decoded. This preserves the same logical anchor model without using
    # page-record hotpoint formulas.
    if _power_symbol_record_style(record_name) == 'gnd':
        return (10, 0, 20, 10)
    return (10, 10, 20, 10)


def _transform_power_symbol_anchor(sym, anchor_x, anchor_y, width, height):
    coords = sym.get('coords')
    if not coords or len(coords) != 6:
        return None
    _loc_y, _loc_x, _y2, _x2, x1, y1 = coords
    rot = (sym.get('orient', 0) >> 8) & 0x03

    if rot == 0:
        x = x1 + anchor_x
        y = y1 + anchor_y
    elif rot == 1:
        x = x1 + anchor_y
        y = y1 + (width - anchor_x)
    elif rot == 2:
        x = x1 + (width - anchor_x)
        y = y1 + (height - anchor_y)
    else:
        x = x1 + (height - anchor_y)
        y = y1 + anchor_x

    return (int(round(x)), int(round(y)))


def _power_symbol_hotpoint_candidates(sym):
    """Return candidate electrical hotpoints for an OrCAD power-port record.

    Coordinates are in raw page units, the same space used by wire endpoints
    and component pin records. The hotpoint is derived from the extracted
    GlobalSymbol anchor and transformed through the page instance orientation.
    """
    record_name = sym.get('record_name', sym.get('name', '')).upper()
    anchor = _power_symbol_logical_anchor(record_name)
    hotpoint = _transform_power_symbol_anchor(sym, *anchor)
    return [hotpoint] if hotpoint is not None else []


def resolve_power_symbol_nets(power_syms, wires, components):
    """Resolve OrCAD power-port records to page-local net names.

    A power port may attach to a wire endpoint or directly to a component pin.
    The DSN power-port record itself has no net_id, so the net is recovered by
    matching the derived hotpoint against those two connectivity indexes.
    """
    wire_points = {}
    for w in wires:
        if not w.get('net'):
            continue
        wire_points[(w['x1'], w['y1'])] = {
            'net_id': w.get('net_id'),
            'net': w.get('net'),
        }
        wire_points[(w['x2'], w['y2'])] = {
            'net_id': w.get('net_id'),
            'net': w.get('net'),
        }

    pin_points = {}
    for comp in components:
        for (_pin_num, px, py), pin_net in comp.get('pin_nets', {}).items():
            if pin_net.get('net'):
                pin_points[(px, py)] = pin_net

    power_net_names = set()
    resolved = []
    for sym in power_syms:
        match = None
        hotpoint = None
        for candidate in _power_symbol_hotpoint_candidates(sym):
            if candidate in wire_points:
                match = wire_points[candidate]
                hotpoint = candidate
                break
            if candidate in pin_points:
                match = pin_points[candidate]
                hotpoint = candidate
                break
        if match and match.get('net'):
            sym = dict(sym)
            sym['net_id'] = match.get('net_id')
            sym['net'] = match.get('net')
            sym['name'] = match.get('net')
            sym['x'], sym['y'] = hotpoint
            sym['matched'] = True
            power_net_names.add(match['net'])
        else:
            sym = dict(sym)
            sym['matched'] = False
        resolved.append(sym)

    return resolved, power_net_names


def power_symbol_styles(power_syms):
    """Return {net_name: (glyph_style, record_name)} from resolved OrCAD power records."""
    styles = {}
    for sym in power_syms:
        if not sym.get('matched') or not sym.get('net'):
            continue
        record_name = sym.get('record_name', '')
        style = _power_symbol_record_style(record_name)
        if not style:
            continue

        net_name = sym['net']
        existing = styles.get(net_name)
        if existing and existing[0] == 'gnd':
            continue
        if style == 'gnd' or net_name not in styles:
            styles[net_name] = (style, record_name)
    return styles


def _power_symbol_angle_from_record(sym):
    """Convert an OrCAD power-port record orientation to a KiCad angle."""
    rot = (sym.get('orient', 0) >> 8) & 0x03
    return {0: 0, 1: 90, 2: 180, 3: 270}.get(rot, 0)


def _power_symbol_angles_by_hotpoint(power_syms):
    angles = {}
    for sym in power_syms or []:
        if not sym.get('matched') or not sym.get('net'):
            continue
        angles[(sym.get('x'), sym.get('y'), sym.get('net'))] = (
            _power_symbol_angle_from_record(sym))
    return angles


TEXT_RECORD_TYPE_WORD = b'\x01\x00\x2e\x2e'
# Graphic primitives drawn on the page (decorative rectangles, lines).
# Both records start with FF E4 5C 39, then ...010030..., then a 6-byte
# type tag at marker+18.
PAGE_RECT_TYPE_WORD = b'\x01\x00\x28\x28\x28\x00'    # "decorative rectangle"
PAGE_LINE_TYPE_WORD = b'\x01\x00\x29\x29\x20\x00'    # "line segment"
PAGE_ELLIPSE_TYPE_WORD = b'\x01\x00\x2b\x2b\x28\x00' # "ellipse / circle"
PAGE_POLYGON_TYPE_WORD = b'\x01\x00\x2c\x2c\x2e\x00' # "filled polygon" (LED triangles)


def _parse_page_polygon(data, m, rgba):
    """Decode a page-level filled-polygon record (0x2c2c).

    Used for the small filled triangles OrCAD draws as LED indicators on
    block-diagram pages. Each triangle is stored as *two* polygon records
    with identical vertices: a solid colored one (FillStyle 0) plus a
    darker outline-only one (FillStyle 1) — the same paired-record idiom
    as the block-diagram background rectangles.

    Layout from the marker `m`:
      m+38  u32 FillStyle (0=solid color fill, 1=outline only)
      m+46  u16 vertex count
      m+48  vertices as u16 (y, x) pairs (OrCAD 10-mil units) — the
            coordinates are stored swapped, the same as the Cache 0x2c2c
            polygon records.

    The raw vertex list repeats the first point to close the path (and may
    carry a trailing duplicate); both are collapsed here. Returns a dict
    {'points': [(x, y), ...], 'rgba': str, 'fill': 'color'|'none'} or None
    if the record is malformed.
    """
    if m + 48 > len(data):
        return None
    n = struct.unpack_from('<H', data, m + 46)[0]
    if not (3 <= n <= 64) or m + 48 + n * 4 > len(data):
        return None
    # Stored as (y, x); reverse each pair to get (x, y).
    raw = [struct.unpack_from('<HH', data, m + 48 + i * 4)[::-1] for i in range(n)]
    # Collapse consecutive duplicates and the closing duplicate vertex.
    pts = []
    for v in raw:
        if not pts or pts[-1] != v:
            pts.append(v)
    if len(pts) > 1 and pts[-1] == pts[0]:
        pts.pop()
    if len(pts) < 3:
        return None
    fill_style = struct.unpack_from('<I', data, m + 38)[0]
    fill = 'color' if fill_style == 0 else 'none'
    return {'points': pts, 'rgba': rgba, 'fill': fill}


def parse_page_graphics(data, paper='A3'):
    """Extract decorative rectangles and line segments from a page stream.

    Found on cover pages (INDEX table outline + dividers, CAUTION block
    red border) but the same record layout is used elsewhere.

    Layout from marker (FF E4 5C 39):
      marker-37  u8 color palette index (from StructGraphicInst wrapper;
                 see _ORCAD_PALETTE_RGBA for the 48-entry color table)
      +18..+23   type tag: PAGE_RECT_TYPE_WORD or PAGE_LINE_TYPE_WORD
      +30..+45   4 × i32 (x1, y1, x2, y2) — line endpoints or rect corners

    Rectangle-only fields (+46..+61, total record = 62 bytes):
      +46..+49  u32 LineStyle (0=solid, 1=dash, 2=dot, 3=dash-dot, 4=dash-dot-dot)
      +50..+53  u32 LineWidth (0=thin, 1=medium, 2=wide, 3=default)
      +54..+57  u32 FillStyle (0=no fill, 1=solid/outline, 2=diagonal hatch)
      +58..+61  s32 HatchStyle (-1=invalid, 0=horiz, 1=vert, 2=diag-left,
                3=diag-right, 4=checkerboard, 5=mesh)

    Line records are 54 bytes; the +46 fields overlap the next record's
    marker, so style/fill can only be read for rectangles.

    Records that fall entirely inside the title-block region at the
    bottom-right corner of the page are filtered out (KiCad redraws the
    title-block frame from the (title_block ...) data).

    Returns (rects, lines, ellipses, polygons). Each rect is a dict with
    keys {x1, y1, x2, y2, rgba, width, fill, stroke_type}. Lines/ellipses
    have {x1, y1, x2, y2, rgba, width}. Polygons have {points, rgba, fill}
    (see _parse_page_polygon).
    """
    page_w, page_h = ORCAD_PAGE_SIZE.get(paper, (1654, 1170))
    tb_x = page_w - TB_REGION_W
    tb_y = page_h - TB_REGION_H

    def in_tb(x, y):
        return x > tb_x and y > tb_y

    rects = []
    lines = []
    ellipses = []
    polygons = []
    pos = 0
    known_tags = (PAGE_RECT_TYPE_WORD, PAGE_LINE_TYPE_WORD,
                  PAGE_ELLIPSE_TYPE_WORD, PAGE_POLYGON_TYPE_WORD)
    while True:
        m = data.find(b'\xff\xe4\x5c\x39', pos)
        if m < 0:
            break
        pos = m + 1
        if m + 54 > len(data):
            continue
        tag = data[m + 18:m + 24]
        if tag not in known_tags:
            continue
        color_idx = data[m - 37] if m >= 37 else 48
        rgba = _ORCAD_PALETTE_RGBA[min(color_idx, 48)]
        if tag == PAGE_POLYGON_TYPE_WORD:
            poly = _parse_page_polygon(data, m, rgba)
            if poly and not all(in_tb(x, y) for x, y in poly['points']):
                polygons.append(poly)
            continue
        x1, y1, x2, y2 = struct.unpack_from('<iiii', data, m + 30)
        if any(abs(v) > 30000 for v in (x1, y1, x2, y2)):
            continue
        if in_tb(x1, y1) and in_tb(x2, y2):
            continue
        width_mm = 0.15
        fill = 'none'
        stroke_type = 'default'
        if tag == PAGE_RECT_TYPE_WORD and m + 62 <= len(data):
            line_style = struct.unpack_from('<I', data, m + 46)[0]
            if line_style == 1:
                stroke_type = 'dash'
            line_width = struct.unpack_from('<I', data, m + 50)[0]
            width_mm = _ORCAD_LINE_WIDTH_MM.get(line_width, 0.15)
            fill_type = struct.unpack_from('<I', data, m + 54)[0]
            if fill_type == 0:
                fill = 'color'
            elif fill_type == 2:
                fill = 'hatch'
        entry = {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'rgba': rgba,
                 'width': width_mm, 'fill': fill, 'stroke_type': stroke_type}
        if tag == PAGE_RECT_TYPE_WORD:
            rects.append(entry)
        elif tag == PAGE_ELLIPSE_TYPE_WORD:
            ellipses.append(entry)
        else:
            lines.append(entry)
    return rects, lines, ellipses, polygons


# OrCAD page sizes in 10-mil units (paper-name → (width, height)).
# Used to compute the title-block keep-out region so the company /
# copyright / sheet-info texts that OrCAD writes inside the frame are
# not duplicated as free-text in the KiCad output (KiCad draws its own
# title-block frame from the (title_block ...) data).
ORCAD_PAGE_SIZE = {
    'A4': (1170,  827),
    'A3': (1654, 1170),
    'A2': (2340, 1654),
    'A1': (3311, 2340),
    'A0': (4681, 3311),
    'A':  (1100,  850),
    'B':  (1700, 1100),
    'C':  (2200, 1700),
    'D':  (3400, 2200),
    'E':  (4400, 3400),
}

# Title-block region (relative to page width/height): the right-edge band
# of width `TB_W` and bottom band of height `TB_H` is where OrCAD places
# the title-block frame and its internal texts. A text whose anchor falls
# inside both bands simultaneously is treated as belonging to the title
# block and dropped.
TB_REGION_W = 300   # 10-mil units (~76 mm)
TB_REGION_H = 150   # 10-mil units (~38 mm)


def parse_text_annotations(data, paper='A3'):
    """Extract free-text annotations from the page stream.

    Layout of a text record (42-byte header + ASCII text payload):
      0x00  type_word (4)   = 01 00 2e 2e   (LE u32 = 0x2e2e0001)
      0x04  rec_len   (u32) = total record length from rec_len onward
      0x08  zeros     (4)
      0x0c  p1, p2, p3, p4, p5, p6  (6 × u32) — text bounding box
              (p1, p2) = top-left corner   (in OrCAD 10-mil units;
                                           Y grows downward)
              (p3, p4) = bottom-right corner
              (p5, p6) = repeat of (p1, p2)
              The baseline-left anchor is (p1, p4): left edge X +
              bottom edge Y.
      0x24  style_id  (u16)   1-based index into the Library style table
                              (see parse_library_styles). Earlier called
                              "font_size" but that was wrong — the
                              rendered size, weight, italic, and face
                              all come from the referenced style record.
      0x26  unknown   (u16)   varies; meaning not decoded
      0x28  text_len  (u16)
      0x2a  text (text_len bytes)

    Text records whose anchor falls inside the title-block region (a
    `TB_REGION_W × TB_REGION_H` rectangle at the page's bottom-right
    corner) are filtered out — OrCAD writes the company/copyright,
    sheet number, document-number value, etc. there, and KiCad redraws
    them from the (title_block ...) header.

    Color is stored in the StructGraphicInst wrapper: a FF E4 5C 39
    marker appears 18 bytes before the text type_word, and the color
    palette index (uint8) is at marker−37 (same layout as rectangles).

    Returns list of dicts:
      {'text': str, 'x': int, 'y': int, 'style_id': int, 'rgba': str}
    where (x, y) is (p3, p4) — the text's anchor in OrCAD 10-mil units.
    Look up the style with `library_styles[style_id - 1]`.
    """
    page_w, page_h = ORCAD_PAGE_SIZE.get(paper, (1654, 1170))
    tb_x = page_w - TB_REGION_W
    tb_y = page_h - TB_REGION_H

    annotations = []
    pos = 0
    while True:
        idx = data.find(TEXT_RECORD_TYPE_WORD, pos)
        if idx < 0:
            break
        pos = idx + 1
        if idx + 42 > len(data):
            continue
        coord_off = idx + 12
        c = struct.unpack_from('<IIIIII', data, coord_off)
        style_id = struct.unpack_from('<H', data, coord_off + 24)[0]
        text_len = struct.unpack_from('<H', data, coord_off + 28)[0]
        if text_len == 0 or text_len > 2000:
            continue
        text_off = idx + 42
        if text_off + text_len > len(data):
            continue
        tb = data[text_off:text_off + text_len]
        # Allow printable ASCII plus newlines/tabs that appear in long paragraphs.
        if not all(0x20 <= b <= 0x7e or b in (0x09, 0x0a, 0x0d) for b in tb):
            continue
        # Sanity-check coords: must be on a reasonable page (< 30000 = ~76m at 10mil)
        if any(v > 30000 for v in c):
            continue
        # (p1, p2) is the bbox top-left and (p3, p4) the bottom-right of
        # the text's bounding rectangle (p5, p6 repeat p1, p2).
        # We anchor each line at the top-left of the bbox row using
        # KiCad's "left top" justification, and advance Y downward by
        # the per-line height for each successive line.
        bbox_x1, bbox_y1, bbox_x2, bbox_y2 = c[0], c[1], c[2], c[3]
        x = bbox_x1
        y = bbox_y1
        # Filter out anchors inside the title-block keep-out region.
        if x > tb_x and y > tb_y:
            continue
        text = tb.decode('ascii')
        # Color palette index from StructGraphicInst wrapper:
        # FF E4 5C 39 marker is 18 bytes before the text type_word,
        # and the color uint8 is 37 bytes before that marker.
        marker_pos = idx - 18
        color_off = marker_pos - 37
        if color_off >= 0 and data[marker_pos:marker_pos + 4] == b'\xff\xe4\x5c\x39':
            color_idx = data[color_off]
            rgba = _ORCAD_PALETTE_RGBA[min(color_idx, 48)]
        else:
            rgba = _ORCAD_PALETTE_RGBA[48]
        annotations.append({
            'text': text,
            'x': x,
            'y': y,
            'bbox': (bbox_x1, bbox_y1, bbox_x2, bbox_y2),
            'style_id': style_id,
            'rgba': rgba,
        })
    return annotations


# ---------------------------------------------------------------------------
# KiCad S-expression generation
# ---------------------------------------------------------------------------

KICAD_PAPER_SIZES = {
    'A4': (297, 210), 'A3': (420, 297), 'A2': (594, 420),
    'A1': (841, 594), 'A0': (1189, 841),
    'A': (279, 216), 'B': (432, 279), 'C': (559, 432),
    'D': (864, 559), 'E': (1118, 864),
}


def sch_header(paper="A3", title="", date="", rev="", company="",
               comment1="", comment2="", comment3="", comment4=""):
    """Render the KiCad schematic header with optional title-block fields.

    KiCad's (title_block ...) block maps directly to the OrCAD title-block
    cell instance's stored fields:
      KiCad (title ...)     ← OrCAD Title field
      KiCad (date ...)      ← OrCAD Date field (not stored in DSN; pass "" or
                              fill from file timestamp at caller's choice)
      KiCad (rev ...)       ← OrCAD Rev field
      KiCad (company ...)   ← OrCAD Organization
      KiCad (comment N ...) ← OrCAD-specific fields (Document Number → comment 1)
    """
    uid = new_uuid()
    tb_parts = []
    esc = _esc_kicad_str
    if title:    tb_parts.append(f"\t\t(title \"{esc(title)}\")\n")
    if date:     tb_parts.append(f"\t\t(date \"{esc(date)}\")\n")
    if rev:      tb_parts.append(f"\t\t(rev \"{esc(rev)}\")\n")
    if company:  tb_parts.append(f"\t\t(company \"{esc(company)}\")\n")
    for i, c in enumerate((comment1, comment2, comment3, comment4), start=1):
        if c:
            tb_parts.append(f"\t\t(comment {i} \"{esc(c)}\")\n")
    title_block = ""
    if tb_parts:
        title_block = "\t(title_block\n" + "".join(tb_parts) + "\t)\n"
    return (
        f"(kicad_sch\n"
        f"\t(version 20260306)\n"
        f"\t(generator \"dsn2kicad\")\n"
        f"\t(generator_version \"1.0\")\n"
        f"\t(uuid \"{uid}\")\n"
        f"\t(paper \"{paper}\")\n"
        f"{title_block}"
    )


def sch_lib_symbols(symbols_needed):
    """Generate lib_symbols section for the symbols used on this page."""
    parts = ["\t(lib_symbols\n"]

    for sym_id, sym_def in symbols_needed.items():
        parts.append(sym_def)

    parts.append("\t)\n")
    return "".join(parts)


def sch_wire(x1, y1, x2, y2):
    uid = new_uuid()
    return (
        f"\t(wire\n"
        f"\t\t(pts\n"
        f"\t\t\t(xy {x1:.2f} {y1:.2f}) (xy {x2:.2f} {y2:.2f})\n"
        f"\t\t)\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width 0)\n"
        f"\t\t\t(type default)\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_bus(x1, y1, x2, y2):
    uid = new_uuid()
    return (
        f"\t(bus\n"
        f"\t\t(pts\n"
        f"\t\t\t(xy {x1:.2f} {y1:.2f}) (xy {x2:.2f} {y2:.2f})\n"
        f"\t\t)\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width 0)\n"
        f"\t\t\t(type default)\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_bus_entry(x, y, sx, sy):
    """Bus entry diagonal. (x, y) is the bus-side point; (sx, sy) is the size offset."""
    uid = new_uuid()
    return (
        f"\t(bus_entry\n"
        f"\t\t(at {x:.2f} {y:.2f})\n"
        f"\t\t(size {sx:.2f} {sy:.2f})\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width 0)\n"
        f"\t\t\t(type default)\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


# Color RGBA values for graphical primitives. KiCad uses (color R G B A)
# inside (stroke ...) — alpha 0 means "use default theme color".
_COLOR_RGBA = {
    'black':     '0 0 0 1',
    'red':       '200 0 0 1',
    'green':     '0 128 0 1',
    'yellow':    '220 180 0 1',
    'lightgrey': '180 180 180 1',
    'magenta':   '200 0 200 1',
    'lightblue': '120 170 255 1',
}

# OrCAD 48-color palette (index 0–48).  Maps palette index to KiCad RGBA.
# Index 48 = Default → alpha 0 (use theme color).
# Source: open_orcad_parser Color.hpp.
_ORCAD_PALETTE_RGBA = [
    '255 128 128 1',   # 0  VeryLightRed        #ff8080
    '255 255 128 1',   # 1  VeryLightYellow      #ffff80
    '128 255 128 1',   # 2  VeryLightLimeGreen   #80ff80
    '0 255 128 1',     # 3  Cyan2                #00ff80
    '128 255 255 1',   # 4  VeryLightCyan        #80ffff
    '0 128 255 1',     # 5  Blue2                #0080ff
    '255 128 192 1',   # 6  VeryLightPink        #ff80c0
    '255 128 255 1',   # 7  VeryLightMagenta     #ff80ff
    '255 0 0 1',       # 8  Red                  #ff0000
    '255 255 0 1',     # 9  Yellow               #ffff00
    '128 255 0 1',     # 10 Green                #80ff00
    '0 255 64 1',      # 11 Cyan1                #00ff40
    '0 255 255 1',     # 12 Cyan3                #00ffff
    '0 128 192 1',     # 13 StrongBlue           #0080c0
    '128 128 192 1',   # 14 SlightlyDesatBlue    #8080c0
    '255 0 255 1',     # 15 Magenta              #ff00ff
    '128 64 64 1',     # 16 DarkModerateRed      #804040
    '255 128 64 1',    # 17 LightOrange          #ff8040
    '0 255 0 1',       # 18 LimeGreen2           #00ff00
    '0 128 128 1',     # 19 DarkCyan             #008080
    '0 64 128 1',      # 20 DarkBlue2            #004080
    '128 128 255 1',   # 21 VeryLightBlue        #8080ff
    '128 0 64 1',      # 22 DarkPink             #800040
    '255 0 128 1',     # 23 Pink                 #ff0080
    '128 0 0 1',       # 24 DarkRed              #800000
    '255 128 0 1',     # 25 Orange               #ff8000
    '0 128 0 1',       # 26 DarkLimeGreen        #008000
    '0 128 64 1',      # 27 LimeGreen1           #008040
    '0 0 255 1',       # 28 Blue1                #0000ff
    '0 0 160 1',       # 29 DarkBlue1            #0000a0
    '128 0 128 1',     # 30 DarkMagenta          #800080
    '128 0 255 1',     # 31 Violet               #8000ff
    '64 0 0 1',        # 32 VeryDarkRed          #400000
    '128 64 0 1',      # 33 DarkOrange           #804000
    '0 64 0 1',        # 34 VeryDarkLimeGreen    #004000
    '0 64 64 1',       # 35 VeryDarkCyan         #004040
    '0 0 128 1',       # 36 VeryDarkBlue2        #000080
    '0 0 64 1',        # 37 VeryDarkBlue1        #000040
    '64 0 64 1',       # 38 VeryDarkMagenta1     #400040
    '64 0 128 1',      # 39 DarkViolet           #400080
    '0 0 0 1',         # 40 Black                #000000
    '128 128 0 1',     # 41 DarkYellow           #808000
    '128 128 64 1',    # 42 DarkModerateYellow   #808040
    '128 128 128 1',   # 43 DarkGray             #808080
    '64 128 128 1',    # 44 DarkModerateCyan     #408080
    '192 192 192 1',   # 45 LightGray            #c0c0c0
    '64 0 64 1',       # 46 VeryDarkMagenta2     #400040
    '255 255 255 1',   # 47 White                #ffffff
    '0 0 0 1',         # 48 Default → explicit black (OrCAD default is black)
]

_ORCAD_LINE_WIDTH_MM = {0: 0.15, 1: 0.30, 2: 0.50, 3: 0.15}


# Optional: use freetype-py to measure exact text widths, so we can size
# each free-text record to fit its OrCAD bounding box. Falls back to a
# fixed-ratio heuristic if freetype-py isn't installed or the font file
# isn't found on the system.
try:
    import freetype as _freetype
    _HAS_FREETYPE = True
except ImportError:
    _freetype = None
    _HAS_FREETYPE = False


_FONT_PATH_CANDIDATES = {
    # (face_lc, bold, italic) → list of TTF candidate paths (macOS + Linux)
    ('arial', False, False): [
        '/System/Library/Fonts/Supplemental/Arial.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ],
    ('arial', True, False): [
        '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    ],
    ('arial', False, True): [
        '/System/Library/Fonts/Supplemental/Arial Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf',
    ],
    ('arial', True, True): [
        '/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Bold_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf',
    ],
    ('arial narrow', False, False): [
        '/System/Library/Fonts/Supplemental/Arial Narrow.ttf',
    ],
    ('arial narrow', True, False): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf',
    ],
    ('arial narrow', False, True): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Italic.ttf',
    ],
    ('arial narrow', True, True): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Bold Italic.ttf',
    ],
    ('courier new', False, False): [
        '/System/Library/Fonts/Supplemental/Courier New.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New.ttf',
    ],
    ('courier new', True, False): [
        '/System/Library/Fonts/Supplemental/Courier New Bold.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Bold.ttf',
    ],
    ('courier new', False, True): [
        '/System/Library/Fonts/Supplemental/Courier New Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Italic.ttf',
    ],
    ('courier new', True, True): [
        '/System/Library/Fonts/Supplemental/Courier New Bold Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Bold_Italic.ttf',
    ],
}


# Cache: {(face_lc, bold, italic): freetype.Face}
_font_cache = {}


def _get_font_face(face_name, bold, italic):
    """Load a freetype Face for (face_name, bold, italic). Returns None
    if freetype is unavailable or no candidate TTF was found."""
    if not _HAS_FREETYPE:
        return None
    key = ((face_name or 'arial').lower(), bool(bold), bool(italic))
    if key in _font_cache:
        return _font_cache[key]
    paths = _FONT_PATH_CANDIDATES.get(key) or _FONT_PATH_CANDIDATES.get(
        ('arial', bool(bold), bool(italic)), [])
    face = None
    for p in paths:
        if os.path.exists(p):
            try:
                face = _freetype.Face(p)
                break
            except Exception:
                continue
    _font_cache[key] = face
    return face


def measure_text_width(s, size_mm, face_name='Arial', bold=False, italic=False):
    """Return the rendered width of `s` in mm at the given KiCad `size_mm`.

    Falls back to `0.6 * size_mm * len(s)` if no font face is available.
    """
    if not s:
        return 0.0
    face = _get_font_face(face_name, bold, italic)
    if face is None:
        return 0.6 * size_mm * len(s)
    # 1 em in freetype is `units_per_EM` font units (typically 2048 for Arial)
    # and KiCad's `(size H H)` corresponds to the em height = H mm.
    # Sum advance widths in font units, then scale by H / units_per_EM.
    upem = face.units_per_EM
    total = 0
    face.set_char_size(int(upem))   # 1-em horizontal size in fontunits
    for ch in s:
        face.load_char(ch, _freetype.FT_LOAD_NO_BITMAP | _freetype.FT_LOAD_NO_SCALE)
        total += face.glyph.metrics.horiAdvance
    return total / upem * size_mm


def measure_text_height(s, size_mm, face_name='Arial', bold=False, italic=False):
    """Return the rendered glyph-bbox height of `s` in mm at KiCad `size_mm`.

    The height is the vertical extent of the inked glyphs (max ascent above the
    baseline minus min descent below), so e.g. an all-caps/digit string reports
    its cap height. Falls back to `size_mm` if no font face is available.
    """
    if not s:
        return 0.0
    face = _get_font_face(face_name, bold, italic)
    if face is None:
        return size_mm
    upem = face.units_per_EM
    face.set_char_size(int(upem))
    top, bot = None, None
    for ch in s:
        if ch == ' ':
            continue
        face.load_char(ch, _freetype.FT_LOAD_NO_BITMAP | _freetype.FT_LOAD_NO_SCALE)
        m = face.glyph.metrics
        gtop = m.horiBearingY               # above baseline (+)
        gbot = m.horiBearingY - m.height    # below baseline (can be -)
        top = gtop if top is None else max(top, gtop)
        bot = gbot if bot is None else min(bot, gbot)
    if top is None:
        return size_mm
    return (top - bot) / upem * size_mm


def sch_polyline(points, color='black', width=0.15, rgba=None):
    """A KiCad polyline (page-level graphical line). points = [(x, y), ...]."""
    uid = new_uuid()
    pts = " ".join(f"(xy {x:.2f} {y:.2f})" for x, y in points)
    if rgba is None:
        rgba = _COLOR_RGBA.get(color, _COLOR_RGBA['black'])
    return (
        f"\t(polyline\n"
        f"\t\t(pts {pts})\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width {width})\n"
        f"\t\t\t(type default)\n"
        f"\t\t\t(color {rgba})\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def _sch_circle(cx, cy, radius, rgba, width=0.1, fill_rgba=None):
    """A KiCad circle on a schematic page; filled if fill_rgba is given."""
    uid = new_uuid()
    fill = f"(fill (type color) (color {fill_rgba}))" if fill_rgba \
        else "(fill (type none))"
    return (
        f"\t(circle\n"
        f"\t\t(center {cx:.2f} {cy:.2f})\n"
        f"\t\t(radius {radius:.2f})\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width {width})\n"
        f"\t\t\t(type default)\n"
        f"\t\t\t(color {rgba})\n"
        f"\t\t)\n"
        f"\t\t{fill}\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def _debug_marker(cx, cy, rgba, radius, dot=0.3):
    """An open circle of `radius` with a filled centre dot, for debug overlays.
    Concentric markers of different radii stay distinguishable when overlapping.
    """
    return (_sch_circle(cx, cy, radius, rgba, width=0.12)
            + _sch_circle(cx, cy, dot, rgba, width=0.05, fill_rgba=rgba))


def sch_filled_polygon(points, rgba='0 0 0 1', width=0.15, fill='none',
                       fill_color=None):
    """A KiCad closed polyline (filled polygon) on a schematic page.

    points = [(x, y), ...] open vertex list; the path is closed by
    repeating the first vertex (so a triangle emits 4 points). With
    fill='color' and fill_color set, the interior is painted — used for
    OrCAD filled polygons such as the LED indicator triangles on block
    diagrams.
    """
    uid = new_uuid()
    closed = list(points) + [points[0]]
    pts = " ".join(f"(xy {x:.2f} {y:.2f})" for x, y in closed)
    fill_part = f'(fill (type {fill})'
    if fill_color:
        fill_part += f' (color {fill_color})'
    fill_part += ')'
    return (
        f"\t(polyline\n"
        f"\t\t(pts {pts})\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width {width})\n"
        f"\t\t\t(type default)\n"
        f"\t\t\t(color {rgba})\n"
        f"\t\t)\n"
        f"\t\t{fill_part}\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_rectangle(x1, y1, x2, y2, color='black', width=0.15, fill='none',
                  stroke_type='default', rgba=None, fill_color=None):
    """KiCad rectangle graphical primitive on a schematic page."""
    uid = new_uuid()
    if rgba is None:
        rgba = _COLOR_RGBA.get(color, _COLOR_RGBA['black'])
    fill_part = f'(fill (type {fill})'
    if fill_color:
        fill_part += f' (color {fill_color})'
    fill_part += ')'
    return (
        f"\t(rectangle\n"
        f"\t\t(start {x1:.2f} {y1:.2f})\n"
        f"\t\t(end {x2:.2f} {y2:.2f})\n"
        f"\t\t(stroke\n"
        f"\t\t\t(width {width})\n"
        f"\t\t\t(type {stroke_type})\n"
        f"\t\t\t(color {rgba})\n"
        f"\t\t)\n"
        f"\t\t{fill_part}\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_ellipse(x1, y1, x2, y2, color='black', width=0.15, n=32, rgba=None):
    """KiCad ellipse as a circle or polyline approximation on a schematic page."""
    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2
    rx = abs(x2 - x1) / 2
    ry = abs(y2 - y1) / 2
    if rgba is None:
        rgba = _COLOR_RGBA.get(color, _COLOR_RGBA['black'])
    if abs(rx - ry) < 0.01:
        uid = new_uuid()
        return (
            f"\t(circle\n"
            f"\t\t(center {cx:.2f} {cy:.2f})\n"
            f"\t\t(radius {rx:.2f})\n"
            f"\t\t(stroke\n"
            f"\t\t\t(width {width})\n"
            f"\t\t\t(type default)\n"
            f"\t\t\t(color {rgba})\n"
            f"\t\t)\n"
            f"\t\t(fill (type none))\n"
            f"\t\t(uuid \"{uid}\")\n"
            f"\t)\n"
        )
    pts = []
    for i in range(n + 1):
        angle = 2 * math.pi * i / n
        pts.append((cx + rx * math.cos(angle), cy + ry * math.sin(angle)))
    return sch_polyline(pts, color=color, width=width, rgba=rgba)


def sch_junction(x, y):
    uid = new_uuid()
    return (
        f"\t(junction\n"
        f"\t\t(at {x:.2f} {y:.2f})\n"
        f"\t\t(diameter 0)\n"
        f"\t\t(color 0 0 0 0)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_label(name, x, y, angle=0):
    uid = new_uuid()
    name_esc = _esc_kicad_str(name)
    if angle in (180, 270):
        justify = "right bottom"
    else:
        justify = "left bottom"
    return (
        f"\t(label \"{name_esc}\"\n"
        f"\t\t(at {x:.2f} {y:.2f} {angle})\n"
        f"\t\t(effects\n"
        f"\t\t\t(font\n"
        f"\t\t\t\t(size 1.27 1.27)\n"
        f"\t\t\t)\n"
        f"\t\t\t(justify {justify})\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


def sch_global_label(name, x, y, angle=0, shape="bidirectional"):
    uid = new_uuid()
    name_esc = _esc_kicad_str(name)
    justify = "right" if angle == 180 else "left"
    return (
        f"\t(global_label \"{name_esc}\"\n"
        f"\t\t(shape {shape})\n"
        f"\t\t(at {x:.2f} {y:.2f} {angle})\n"
        f"\t\t(effects\n"
        f"\t\t\t(font\n"
        f"\t\t\t\t(size 1.27 1.27)\n"
        f"\t\t\t)\n"
        f"\t\t\t(justify {justify})\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t\t(property \"Intersheetrefs\" \"${{INTERSHEET_REFS}}\"\n"
        f"\t\t\t(at 0 0 0)\n"
        f"\t\t\t(effects\n"
        f"\t\t\t\t(font\n"
        f"\t\t\t\t\t(size 1.27 1.27)\n"
        f"\t\t\t\t)\n"
        f"\t\t\t\t(hide yes)\n"
        f"\t\t\t)\n"
        f"\t\t)\n"
        f"\t)\n"
    )


def _is_gnd_power_name(name):
    """Return True for names that should use the GND triangle glyph."""
    upper = name.upper()
    return (upper in ('GND', 'AGND', 'PGND', 'VSS', 'DGND', 'SGND',
                      'ADAVSS', 'GROUND')
            or upper.startswith('GND')
            or upper.startswith('GROUND')
            or upper.endswith('_VSS'))


def _power_symbol_record_style(record_name):
    """Return the glyph style implied by an OrCAD power-port record name."""
    record_name = record_name.upper()
    if _is_gnd_power_name(record_name) or record_name == 'GND_POWER':
        return 'gnd'
    if record_name in ('VCC', 'VCC_CIRCLE'):
        return 'circle'
    if record_name == 'VCC_BAR':
        return 'rail'
    return None


def is_power_symbol_record_name(name):
    """Return True for OrCAD power-port symbol record names.

    These are symbol glyph names in the page stream, not resolved net names.
    VCC_BAR-style records can connect to arbitrary positive supply nets such
    as D5.0V1 or PCIE_3V3.
    """
    upper = name.upper()
    return (_power_symbol_record_style(upper) is not None
            or upper in _orcad_power_glyphs)


_kicad_native_power = {}
_use_kicad_power = False
_orcad_power_glyphs = {}


def _kicad_power_from_template(template_name, new_name):
    """Create a power symbol by renaming a native KiCad template (VCC or GND)."""
    tmpl = _kicad_native_power.get(template_name)
    if not tmpl:
        return None
    return tmpl.replace(template_name, new_name)


def load_kicad_power_library():
    """Load symbol definitions from KiCad's installed power library.

    Populates _kicad_native_power: {name: inline_definition_str}.
    The definitions are re-indented to match the inline lib_symbols format.
    """
    search_paths = [
        Path('/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols/power.kicad_sym'),
        Path('/usr/share/kicad/symbols/power.kicad_sym'),
        Path(os.environ.get('KICAD8_SYMBOL_DIR', ''), 'power.kicad_sym'),
        Path(os.environ.get('KICAD_SYMBOL_DIR', ''), 'power.kicad_sym'),
    ]
    lib_path = None
    for p in search_paths:
        if p.exists():
            lib_path = p
            break
    if not lib_path:
        print("  Warning: KiCad power library not found, "
              "using built-in power symbols", file=sys.stderr)
        return
    content = lib_path.read_text(encoding='utf-8')
    pos = 0
    count = 0
    while True:
        idx = content.find('\t(symbol "', pos)
        if idx < 0:
            break
        name_start = idx + len('\t(symbol "')
        name_end = content.index('"', name_start)
        name = content[name_start:name_end]
        depth = 0
        end = idx
        for i in range(idx, len(content)):
            if content[i] == '(':
                depth += 1
            elif content[i] == ')':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        sym_text = content[idx:end]
        sym_text = sym_text.replace('\t(symbol ', '\t\t(symbol "power:' + name + '"\n\t\t\t', 1)
        sym_text = '\t\t(symbol "power:' + name + '"\n'
        body = content[idx:end]
        lines = body.split('\n')
        rebuilt = ['\t\t(symbol "power:' + name + '"']
        for line in lines[1:]:
            rebuilt.append('\t' + line)
        sym_text = '\n'.join(rebuilt) + '\n'
        _kicad_native_power[name] = sym_text
        pos = end
        count += 1
    print(f"  Loaded {count} symbols from {lib_path.name}")


def _parse_global_symbol_head(data, offset):
    """Parse the stable prefix/name/primitive part of a GlobalSymbol record."""
    from olb_parser import (
        DataStream, auto_read_prefixes, read_preamble, read_prim_prefix,
        read_primitive, PRIM_SYMBOL_VECTOR, PRIMITIVE_TYPES,
    )

    ds = DataStream(data[offset:])
    _prefixes, checkpoints = auto_read_prefixes(ds, 0x21)
    read_preamble(ds)
    name = ds.read_string_len_zero_term()
    source_library = ds.read_string_len_zero_term()
    if (not name or len(name) > 40
            or not all(32 <= ord(c) < 127 for c in name)
            or not all((32 <= ord(c) < 127) for c in source_library)):
        return None
    if checkpoints:
        checkpoint = checkpoints[0] - offset
        if 0 <= checkpoint < len(ds.data):
            ds.pos = checkpoint
    _color = ds.read_uint32()
    primitive_count = ds.read_uint16()
    if primitive_count > 20:
        return None

    primitives = []
    for i in range(primitive_count):
        prim_type = read_prim_prefix(ds)
        if prim_type not in PRIMITIVE_TYPES:
            return None
        if prim_type == PRIM_SYMBOL_VECTOR:
            ds.pos -= 1
        prim = read_primitive(ds, prim_type)
        if prim is not None:
            primitives.append(prim)
        # Some GlobalSymbol records carry an all-zero separator between
        # primitive records. The C++ parser treats it as additional bytes.
        if i + 1 < primitive_count and ds.peek(8) == b'\x00' * 8:
            ds.skip(8)

    if not primitives:
        return None
    return {
        'name': name,
        'source_library': source_library,
        'primitives': primitives,
    }


def extract_orcad_power_glyphs(ole):
    """Extract GlobalSymbol primitive glyphs for OrCAD power symbols."""
    try:
        data = ole.openstream('Cache').read()
    except Exception:
        return {}

    glyphs = {}
    wanted = {'GND', 'VCC', 'VCC_BAR', 'VCC_CIRCLE', 'GND_POWER'}
    for offset, byte in enumerate(data):
        if byte != 0x21:
            continue
        try:
            glyph = _parse_global_symbol_head(data, offset)
        except Exception:
            continue
        if not glyph:
            continue
        style = _power_symbol_record_style(glyph['name'])
        if not style and glyph['name'] not in wanted:
            continue
        # Prefer the first definition encountered; later Cache entries often
        # include unrelated library examples from other projects.
        glyphs.setdefault(glyph['name'], glyph)
    return glyphs


def lib_symbol_power_gnd(name='GND'):
    """KiCad GND-style power definition (triangle-down glyph at pin 1)."""
    name_esc = _esc_kicad_str(name)
    return (
        f'\t\t(symbol "power:{name_esc}"\n'
        '\t\t\t(power)\n'
        '\t\t\t(pin_numbers hide)\n'
        '\t\t\t(pin_names\n'
        '\t\t\t\t(offset 0)\n'
        '\t\t\t\thide)\n'
        '\t\t\t(exclude_from_sim no)\n'
        '\t\t\t(in_bom yes)\n'
        '\t\t\t(on_board yes)\n'
        '\t\t\t(property "Reference" "#PWR"\n'
        '\t\t\t\t(at 0 -6.35 0)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(hide yes)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        f'\t\t\t(property "Value" "{name_esc}"\n'
        '\t\t\t\t(at 0 -3.81 0)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_0_1"\n'
        '\t\t\t\t(polyline\n'
        '\t\t\t\t\t(pts\n'
        '\t\t\t\t\t\t(xy 0 0) (xy 0 -1.27) (xy 1.27 -1.27) '
        '(xy 0 -2.54) (xy -1.27 -1.27) (xy 0 -1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(stroke\n'
        '\t\t\t\t\t\t(width 0)\n'
        '\t\t\t\t\t\t(type default)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(fill\n'
        '\t\t\t\t\t\t(type none)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_1_1"\n'
        '\t\t\t\t(pin power_in line\n'
        '\t\t\t\t\t(at 0 0 270)\n'
        '\t\t\t\t\t(length 0)\n'
        f'\t\t\t\t\t(name "{name_esc}"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(number "1"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t)\n'
    )


def lib_symbol_power_rail(name):
    """OrCAD/Capsym-style `power:<NAME>` symbol — a T-shape: vertical
    stem from the pin up to a short horizontal cross-bar, with the
    Value (rail name) shown above the bar.

    Geometry (mm): stem from (0,0) to (0, 1.27); cross-bar from
    (-1.27, 1.27) to (1.27, 1.27); Value text centered above the bar.
    """
    name_esc = _esc_kicad_str(name)
    return (
        f'\t\t(symbol "power:{name_esc}"\n'
        f'\t\t\t(power)\n'
        f'\t\t\t(pin_numbers hide)\n'
        f'\t\t\t(pin_names\n'
        f'\t\t\t\t(offset 0)\n'
        f'\t\t\t\thide)\n'
        f'\t\t\t(exclude_from_sim no)\n'
        f'\t\t\t(in_bom yes)\n'
        f'\t\t\t(on_board yes)\n'
        f'\t\t\t(property "Reference" "#PWR"\n'
        f'\t\t\t\t(at 0 -2.54 0)\n'
        f'\t\t\t\t(effects\n'
        f'\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(hide yes)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(property "Value" "{name_esc}"\n'
        f'\t\t\t\t(at 0 2.286 0)\n'
        f'\t\t\t\t(effects\n'
        f'\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_0_1"\n'
        f'\t\t\t\t(polyline\n'
        f'\t\t\t\t\t(pts\n'
        f'\t\t\t\t\t\t(xy 0 0) (xy 0 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(stroke\n'
        f'\t\t\t\t\t\t(width 0)\n'
        f'\t\t\t\t\t\t(type default)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(fill\n'
        f'\t\t\t\t\t\t(type none)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t\t(polyline\n'
        f'\t\t\t\t\t(pts\n'
        f'\t\t\t\t\t\t(xy -1.27 1.27) (xy 1.27 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(stroke\n'
        f'\t\t\t\t\t\t(width 0)\n'
        f'\t\t\t\t\t\t(type default)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(fill\n'
        f'\t\t\t\t\t\t(type none)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_1_1"\n'
        f'\t\t\t\t(pin power_in line\n'
        f'\t\t\t\t\t(at 0 0 90)\n'
        f'\t\t\t\t\t(length 0)\n'
        f'\t\t\t\t\t(name "{name_esc}"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(number "1"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t)\n'
    )


def lib_symbol_power_circle(name):
    """OrCAD/Capsym-style circle power symbol with a short stem."""
    name_esc = _esc_kicad_str(name)
    return (
        f'\t\t(symbol "power:{name_esc}"\n'
        f'\t\t\t(power)\n'
        f'\t\t\t(pin_numbers hide)\n'
        f'\t\t\t(pin_names\n'
        f'\t\t\t\t(offset 0)\n'
        f'\t\t\t\thide)\n'
        f'\t\t\t(exclude_from_sim no)\n'
        f'\t\t\t(in_bom yes)\n'
        f'\t\t\t(on_board yes)\n'
        f'\t\t\t(property "Reference" "#PWR"\n'
        f'\t\t\t\t(at 0 -2.54 0)\n'
        f'\t\t\t\t(effects\n'
        f'\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(hide yes)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(property "Value" "{name_esc}"\n'
        f'\t\t\t\t(at 0 3.175 0)\n'
        f'\t\t\t\t(effects\n'
        f'\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_0_1"\n'
        f'\t\t\t\t(polyline\n'
        f'\t\t\t\t\t(pts\n'
        f'\t\t\t\t\t\t(xy 0 0) (xy 0 1.27)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(stroke\n'
        f'\t\t\t\t\t\t(width 0)\n'
        f'\t\t\t\t\t\t(type default)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(fill\n'
        f'\t\t\t\t\t\t(type none)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t\t(circle\n'
        f'\t\t\t\t\t(center 0 1.905)\n'
        f'\t\t\t\t\t(radius 0.635)\n'
        f'\t\t\t\t\t(stroke\n'
        f'\t\t\t\t\t\t(width 0)\n'
        f'\t\t\t\t\t\t(type default)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(fill\n'
        f'\t\t\t\t\t\t(type none)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t\t(symbol "{name_esc}_1_1"\n'
        f'\t\t\t\t(pin power_in line\n'
        f'\t\t\t\t\t(at 0 0 90)\n'
        f'\t\t\t\t\t(length 0)\n'
        f'\t\t\t\t\t(name "{name_esc}"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(number "1"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
        f'\t\t\t)\n'
        f'\t\t)\n'
    )


def _power_glyph_record_name(style):
    if style == 'circle':
        return 'VCC_CIRCLE' if 'VCC_CIRCLE' in _orcad_power_glyphs else 'VCC'
    if style == 'rail':
        return 'VCC_BAR'
    if style == 'gnd':
        return 'GND'
    return None


def _power_glyph_points(primitives):
    from olb_parser import (
        PrimLine, PrimRect, PrimArc, PrimEllipse, PrimPolyline, PrimPolygon,
    )
    points = []
    for prim in primitives:
        if isinstance(prim, (PrimLine, PrimRect, PrimArc, PrimEllipse)):
            points.extend([(prim.x1, prim.y1), (prim.x2, prim.y2)])
            if isinstance(prim, PrimArc):
                points.extend([(prim.start_x, prim.start_y),
                               (prim.end_x, prim.end_y)])
        elif isinstance(prim, (PrimPolyline, PrimPolygon)):
            points.extend((p.x, p.y) for p in prim.points)
    return points


def _power_glyph_anchor(record_name, primitives):
    points = _power_glyph_points(primitives)
    if not points:
        return (0, 0)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    anchor_x = (min(xs) + max(xs)) / 2
    if _power_symbol_record_style(record_name) == 'gnd':
        anchor_y = min(ys)
    else:
        anchor_y = max(ys)
    return (anchor_x, anchor_y)


def _power_glyph_xy(x, y, anchor_x, anchor_y):
    return (
        round((x - anchor_x) * POWER_SYMBOL_UNIT_TO_MM, 3),
        round((anchor_y - y) * POWER_SYMBOL_UNIT_TO_MM, 3),
    )


def lib_symbol_power_extracted(name, record_name, glyph):
    """KiCad power symbol generated from an OrCAD GlobalSymbol primitive list."""
    from olb_parser import (
        PrimLine, PrimRect, PrimArc, PrimEllipse, PrimPolyline, PrimPolygon,
    )
    name_esc = _esc_kicad_str(name)
    primitives = glyph.get('primitives', [])
    anchor_x, anchor_y = _power_glyph_anchor(record_name, primitives)
    is_gnd = _power_symbol_record_style(record_name) == 'gnd'

    if is_gnd:
        ref_y = -6.35
        val_y = -3.81
    else:
        ref_y = -2.54
        val_y = 2.286

    parts = [
        f'\t\t(symbol "power:{name_esc}"\n',
        '\t\t\t(power)\n',
        '\t\t\t(pin_numbers hide)\n',
        '\t\t\t(pin_names\n',
        '\t\t\t\t(offset 0)\n',
        '\t\t\t\thide)\n',
        '\t\t\t(exclude_from_sim no)\n',
        '\t\t\t(in_bom yes)\n',
        '\t\t\t(on_board yes)\n',
        '\t\t\t(property "Reference" "#PWR"\n',
        f'\t\t\t\t(at 0 {ref_y} 0)\n',
        '\t\t\t\t(effects\n',
        '\t\t\t\t\t(font\n',
        '\t\t\t\t\t\t(size 1.27 1.27)\n',
        '\t\t\t\t\t)\n',
        '\t\t\t\t\t(hide yes)\n',
        '\t\t\t\t)\n',
        '\t\t\t)\n',
        f'\t\t\t(property "Value" "{name_esc}"\n',
        f'\t\t\t\t(at 0 {val_y} 0)\n',
        '\t\t\t\t(effects\n',
        '\t\t\t\t\t(font\n',
        '\t\t\t\t\t\t(size 1.27 1.27)\n',
        '\t\t\t\t\t)\n',
        '\t\t\t\t)\n',
        '\t\t\t)\n',
        f'\t\t\t(symbol "{name_esc}_0_1"\n',
    ]

    for prim in primitives:
        if isinstance(prim, PrimLine):
            x1, y1 = _power_glyph_xy(prim.x1, prim.y1, anchor_x, anchor_y)
            x2, y2 = _power_glyph_xy(prim.x2, prim.y2, anchor_x, anchor_y)
            parts.extend([
                '\t\t\t\t(polyline\n',
                '\t\t\t\t\t(pts\n',
                f'\t\t\t\t\t\t(xy {x1:.3f} {y1:.3f}) (xy {x2:.3f} {y2:.3f})\n',
                '\t\t\t\t\t)\n',
                '\t\t\t\t\t(stroke\n',
                '\t\t\t\t\t\t(width 0)\n',
                '\t\t\t\t\t\t(type default)\n',
                '\t\t\t\t\t)\n',
                '\t\t\t\t\t(fill\n',
                '\t\t\t\t\t\t(type none)\n',
                '\t\t\t\t\t)\n',
                '\t\t\t\t)\n',
            ])
        elif isinstance(prim, PrimEllipse):
            x1, y1 = _power_glyph_xy(prim.x1, prim.y1, anchor_x, anchor_y)
            x2, y2 = _power_glyph_xy(prim.x2, prim.y2, anchor_x, anchor_y)
            cx = (x1 + x2) / 2
            cy = (y1 + y2) / 2
            rx = abs(x2 - x1) / 2
            ry = abs(y2 - y1) / 2
            if abs(rx - ry) < 0.001:
                parts.extend([
                    '\t\t\t\t(circle\n',
                    f'\t\t\t\t\t(center {cx:.3f} {cy:.3f})\n',
                    f'\t\t\t\t\t(radius {rx:.3f})\n',
                    '\t\t\t\t\t(stroke\n',
                    '\t\t\t\t\t\t(width 0)\n',
                    '\t\t\t\t\t\t(type default)\n',
                    '\t\t\t\t\t)\n',
                    '\t\t\t\t\t(fill\n',
                    '\t\t\t\t\t\t(type none)\n',
                    '\t\t\t\t\t)\n',
                    '\t\t\t\t)\n',
                ])
        elif isinstance(prim, (PrimPolyline, PrimPolygon)):
            pts = [
                _power_glyph_xy(p.x, p.y, anchor_x, anchor_y)
                for p in prim.points
            ]
            if len(pts) >= 2:
                if isinstance(prim, PrimPolygon) and pts[0] != pts[-1]:
                    pts.append(pts[0])
                pts_s = ' '.join(f'(xy {x:.3f} {y:.3f})' for x, y in pts)
                parts.extend([
                    '\t\t\t\t(polyline\n',
                    '\t\t\t\t\t(pts\n',
                    f'\t\t\t\t\t\t{pts_s}\n',
                    '\t\t\t\t\t)\n',
                    '\t\t\t\t\t(stroke\n',
                    '\t\t\t\t\t\t(width 0)\n',
                    '\t\t\t\t\t\t(type default)\n',
                    '\t\t\t\t\t)\n',
                    '\t\t\t\t\t(fill\n',
                    '\t\t\t\t\t\t(type none)\n',
                    '\t\t\t\t\t)\n',
                    '\t\t\t\t)\n',
                ])
        elif isinstance(prim, PrimRect):
            x1, y1 = _power_glyph_xy(prim.x1, prim.y1, anchor_x, anchor_y)
            x2, y2 = _power_glyph_xy(prim.x2, prim.y2, anchor_x, anchor_y)
            parts.extend([
                '\t\t\t\t(rectangle\n',
                f'\t\t\t\t\t(start {x1:.3f} {y1:.3f})\n',
                f'\t\t\t\t\t(end {x2:.3f} {y2:.3f})\n',
                '\t\t\t\t\t(stroke\n',
                '\t\t\t\t\t\t(width 0)\n',
                '\t\t\t\t\t\t(type default)\n',
                '\t\t\t\t\t)\n',
                '\t\t\t\t\t(fill\n',
                '\t\t\t\t\t\t(type none)\n',
                '\t\t\t\t\t)\n',
                '\t\t\t\t)\n',
            ])

    pin_angle = 270 if is_gnd else 90
    parts.extend([
        '\t\t\t)\n',
        f'\t\t\t(symbol "{name_esc}_1_1"\n',
        '\t\t\t\t(pin power_in line\n',
        f'\t\t\t\t\t(at 0 0 {pin_angle})\n',
        '\t\t\t\t\t(length 0)\n',
        f'\t\t\t\t\t(name "{name_esc}"\n',
        '\t\t\t\t\t\t(effects\n',
        '\t\t\t\t\t\t\t(font\n',
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n',
        '\t\t\t\t\t\t\t)\n',
        '\t\t\t\t\t\t)\n',
        '\t\t\t\t\t)\n',
        '\t\t\t\t\t(number "1"\n',
        '\t\t\t\t\t\t(effects\n',
        '\t\t\t\t\t\t\t(font\n',
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n',
        '\t\t\t\t\t\t\t)\n',
        '\t\t\t\t\t\t)\n',
        '\t\t\t\t\t)\n',
        '\t\t\t\t)\n',
        '\t\t\t)\n',
        '\t\t)\n',
    ])
    return ''.join(parts)


def lib_symbol_for_power_name(name, power_symbol_styles=None):
    """Return the project-local KiCad symbol definition for a power net."""
    entry = (power_symbol_styles or {}).get(name)
    if isinstance(entry, tuple):
        style, record_name = entry
    else:
        style, record_name = entry, None
    if _is_gnd_power_name(name) or style == 'gnd':
        if _use_kicad_power and name == 'GND':
            return _kicad_native_power.get('GND') or lib_symbol_power_gnd()
        if record_name and record_name in _orcad_power_glyphs:
            return lib_symbol_power_extracted(
                name, record_name, _orcad_power_glyphs[record_name])
        return lib_symbol_power_gnd(name)
    if _use_kicad_power:
        return (_kicad_native_power.get(name)
                or _kicad_power_from_template('VCC', name)
                or lib_symbol_power_rail(name))
    if not record_name:
        record_name = _power_glyph_record_name(style)
    if record_name and record_name in _orcad_power_glyphs:
        return lib_symbol_power_extracted(
            name, record_name, _orcad_power_glyphs[record_name])
    if style == 'circle':
        return lib_symbol_power_circle(name)
    return lib_symbol_power_rail(name)


def sch_power_symbol(name, x, y, is_ground=False, angle=0,
                     text_size_mm=1.27, text_face=None,
                     text_bold=False, text_italic=False):
    """Generate a KiCad power symbol instance."""
    uid = new_uuid()
    pin_uid = new_uuid()
    sym_uid = new_uuid()
    name_esc = _esc_kicad_str(name)
    angle = int(round(angle)) % 360

    if is_ground:
        lib_id = f"power:{name_esc}"
        pin_name = name
    else:
        lib_id = f"power:{name_esc}"
        pin_name = name

    if angle in (90, 270):
        text_offset = 5.72
        val_x = x + (text_offset if angle == 270 else -text_offset)
        val_y = y
        val_angle = angle
    elif is_ground:
        val_x = x
        val_y = y + 3.81
        val_angle = 0
    elif _use_kicad_power:
        val_x = x
        val_y = y - 3.81
        val_angle = 0
    else:
        val_x = x
        val_y = y - 2.54
        val_angle = 0
    val_hide = '\t\t\t\t(hide yes)\n' if is_ground else ''

    def _font_block(indent):
        out = [f"{indent}(font\n"]
        if text_face:
            out.append(f'{indent}\t(face "{_esc_kicad_str(text_face)}")\n')
        out.append(f"{indent}\t(size {text_size_mm:.4f} {text_size_mm:.4f})\n")
        if text_bold:
            out.append(f"{indent}\t(bold yes)\n")
        if text_italic:
            out.append(f"{indent}\t(italic yes)\n")
        out.append(f"{indent})\n")
        return "".join(out)

    return (
        f"\t(symbol\n"
        f"\t\t(lib_id \"{lib_id}\")\n"
        f"\t\t(at {x:.2f} {y:.2f} {angle})\n"
        f"\t\t(unit 1)\n"
        f"\t\t(exclude_from_sim no)\n"
        f"\t\t(in_bom yes)\n"
        f"\t\t(on_board yes)\n"
        f"\t\t(dnp no)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t\t(property \"Reference\" \"#PWR\"\n"
        f"\t\t\t(at {x:.2f} {y:.2f} 0)\n"
        f"\t\t\t(effects\n"
        + _font_block("\t\t\t\t")
        + f"\t\t\t\t(hide yes)\n"
        + f"\t\t\t)\n"
        + f"\t\t)\n"
        f"\t\t(property \"Value\" \"{name_esc}\"\n"
        f"\t\t\t(at {val_x:.2f} {val_y:.2f} {val_angle})\n"
        f"\t\t\t(effects\n"
        + _font_block("\t\t\t\t")
        + f"{val_hide}"
        + f"\t\t\t)\n"
        + f"\t\t)\n"
        f"\t\t(pin \"1\"\n"
        f"\t\t\t(uuid \"{pin_uid}\")\n"
        f"\t\t)\n"
        f"\t\t(instances\n"
        f"\t\t\t(project \"\"\n"
        f"\t\t\t\t(path \"/\"\n"
        f"\t\t\t\t\t(reference \"#PWR\")\n"
        f"\t\t\t\t\t(unit 1)\n"
        f"\t\t\t\t)\n"
        f"\t\t\t)\n"
        f"\t\t)\n"
        f"\t)\n"
    )


def _esc_kicad_str(s):
    """Escape a string for inclusion in a KiCad S-expression "..." literal.

    KiCad's parser rejects literal newlines and unescaped quotes inside
    string literals. We must:
      - escape backslashes first (so we don't double-escape)
      - escape double quotes
      - translate CR/LF/TAB to their escape sequences so multi-line
        values from OrCAD (e.g. wrapped paragraphs, labels split across
        rows) survive without breaking the parser.
    """
    return (s.replace('\\', '\\\\')
             .replace('"', '\\"')
             .replace('\r\n', '\\n')
             .replace('\n', '\\n')
             .replace('\r', '\\n')
             .replace('\t', ' '))


def _orcad_overline_to_kicad(s):
    """Translate OrCAD overline markers to KiCad's `~{...}` syntax.

    In OrCAD Capture, a backslash overlines the *next* character — so
    `\\O\\E` is overlined `O` followed by overlined `E`, and `1\\O\\E\\`
    is `1` followed by overlined `O` and `E` (with a stray trailing
    backslash). Adjacent overlined characters fold into a single
    `~{...}` group for readability. A trailing backslash with no
    following character is dropped.
    """
    if '\\' not in s:
        return s
    out = []
    run = []
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == '\\' and i + 1 < n:
            run.append(s[i + 1])
            i += 2
            continue
        if run:
            out.append('~{' + ''.join(run) + '}')
            run = []
        if ch == '\\':
            i += 1
            continue
        out.append(ch)
        i += 1
    if run:
        out.append('~{' + ''.join(run) + '}')
    return ''.join(out)


def _pin_label_for_kicad(s):
    """Convert an OrCAD pin name/number into a KiCad-safe string literal body."""
    return _esc_kicad_str(_orcad_overline_to_kicad(str(s)))


def sch_text(txt, x, y, size=1.27, angle=0, justify="left bottom",
             bold=False, italic=False, face=None, rgba=None):
    """KiCad page-level text. Default justify "left bottom" anchors the
    text at its baseline-left point, matching OrCAD's convention so the
    `(p3, p4)` anchor from the DSN's text record lands correctly.

    `bold`, `italic`, and `face` come from the Library style record
    referenced by the text's `style_id - 1`.
    """
    uid = new_uuid()
    txt_esc = _esc_kicad_str(txt)
    font_inner_lines = [f"\t\t\t\t(size {size:.2f} {size:.2f})"]
    if face:
        face_esc = _esc_kicad_str(face)
        font_inner_lines.insert(0, f"\t\t\t\t(face \"{face_esc}\")")
    if bold:
        font_inner_lines.append("\t\t\t\t(bold yes)")
    if italic:
        font_inner_lines.append("\t\t\t\t(italic yes)")
    if rgba:
        font_inner_lines.append(f"\t\t\t\t(color {rgba})")
    font_block = "\t\t\t(font\n" + "\n".join(font_inner_lines) + "\n\t\t\t)\n"
    return (
        f"\t(text \"{txt_esc}\"\n"
        f"\t\t(exclude_from_sim no)\n"
        f"\t\t(at {x:.2f} {y:.2f} {angle})\n"
        f"\t\t(effects\n"
        f"{font_block}"
        f"\t\t\t(justify {justify})\n"
        f"\t\t)\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t)\n"
    )


# ---------------------------------------------------------------------------
# KiCad symbol definitions for inline lib_symbols
# ---------------------------------------------------------------------------

def lib_symbol_R():
    return (
        '\t\t(symbol "R"\n'
        '\t\t\t(pin_numbers hide)\n'
        '\t\t\t(pin_names\n'
        '\t\t\t\t(offset 0)\n'
        '\t\t\t\thide)\n'
        '\t\t\t(exclude_from_sim no)\n'
        '\t\t\t(in_bom yes)\n'
        '\t\t\t(on_board yes)\n'
        '\t\t\t(property "Reference" "R"\n'
        '\t\t\t\t(at 2.032 0 90)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(property "Value" "R"\n'
        '\t\t\t\t(at -2.032 0 90)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(symbol "R_0_1"\n'
        '\t\t\t\t(rectangle\n'
        '\t\t\t\t\t(start -1.016 -3.81)\n'
        '\t\t\t\t\t(end 1.016 3.81)\n'
        '\t\t\t\t\t(stroke\n'
        '\t\t\t\t\t\t(width 0.254)\n'
        '\t\t\t\t\t\t(type default)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(fill\n'
        '\t\t\t\t\t\t(type none)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(symbol "R_1_1"\n'
        '\t\t\t\t(pin passive line\n'
        '\t\t\t\t\t(at 0 5.08 270)\n'
        '\t\t\t\t\t(length 1.27)\n'
        '\t\t\t\t\t(name "~"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(number "1"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t\t(pin passive line\n'
        '\t\t\t\t\t(at 0 -5.08 90)\n'
        '\t\t\t\t\t(length 1.27)\n'
        '\t\t\t\t\t(name "~"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(number "2"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t)\n'
    )


def lib_symbol_C():
    return (
        '\t\t(symbol "C"\n'
        '\t\t\t(pin_numbers hide)\n'
        '\t\t\t(pin_names\n'
        '\t\t\t\t(offset 0.254)\n'
        '\t\t\t\thide)\n'
        '\t\t\t(exclude_from_sim no)\n'
        '\t\t\t(in_bom yes)\n'
        '\t\t\t(on_board yes)\n'
        '\t\t\t(property "Reference" "C"\n'
        '\t\t\t\t(at 2.54 0 90)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(property "Value" "C"\n'
        '\t\t\t\t(at -2.54 0 90)\n'
        '\t\t\t\t(effects\n'
        '\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(symbol "C_0_1"\n'
        '\t\t\t\t(polyline\n'
        '\t\t\t\t\t(pts\n'
        '\t\t\t\t\t\t(xy -2.032 -0.762) (xy 2.032 -0.762)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(stroke\n'
        '\t\t\t\t\t\t(width 0.508)\n'
        '\t\t\t\t\t\t(type default)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(fill\n'
        '\t\t\t\t\t\t(type none)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t\t(polyline\n'
        '\t\t\t\t\t(pts\n'
        '\t\t\t\t\t\t(xy -2.032 0.762) (xy 2.032 0.762)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(stroke\n'
        '\t\t\t\t\t\t(width 0.508)\n'
        '\t\t\t\t\t\t(type default)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(fill\n'
        '\t\t\t\t\t\t(type none)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t\t(symbol "C_1_1"\n'
        '\t\t\t\t(pin passive line\n'
        '\t\t\t\t\t(at 0 3.81 270)\n'
        '\t\t\t\t\t(length 2.794)\n'
        '\t\t\t\t\t(name "~"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(number "1"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t\t(pin passive line\n'
        '\t\t\t\t\t(at 0 -3.81 90)\n'
        '\t\t\t\t\t(length 2.794)\n'
        '\t\t\t\t\t(name "~"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t\t(number "2"\n'
        '\t\t\t\t\t\t(effects\n'
        '\t\t\t\t\t\t\t(font\n'
        '\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        '\t\t\t\t\t\t\t)\n'
        '\t\t\t\t\t\t)\n'
        '\t\t\t\t\t)\n'
        '\t\t\t\t)\n'
        '\t\t\t)\n'
        '\t\t)\n'
    )


PIN_LENGTH = 2.54


def _inverse_rotate(dx, dy, orient_byte):
    """Undo OrCAD orient (mirror then CW rotation) to get symbol-local offsets.

    Inverse of _forward_rotate: un-rotate first, then un-mirror.
    """
    orcad_angle = {0x01: 90, 0x05: 90, 0x02: 180, 0x06: 180,
                   0x03: 270, 0x07: 270}.get(orient_byte, 0)
    if orcad_angle == 90:
        dx, dy = (-dy, dx)
    elif orcad_angle == 180:
        dx, dy = (-dx, -dy)
    elif orcad_angle == 270:
        dx, dy = (dy, -dx)
    if orient_byte & 0x04:
        dx = -dx
    return (dx, dy)


def _forward_rotate(dx, dy, orient_byte, center=(0, 0)):
    """Apply OrCAD orient (mirror then CW rotation) to a symbol-local offset.

    Takes a (dx, dy) in cache-local coords and returns the equivalent
    (dx, dy) in page-stream coords after the component's orient is applied.
    OrCAD applies mirror first (flip X), then rotates.

    center: the point the symbol is mirrored/rotated about. OrCAD pivots about
    the centre of the symbol bounding box (so the pins stay put when editing),
    NOT the origin — pass the bbox centre. The default (0, 0) keeps the old
    "about the origin" behaviour. Pivoting about the true centre makes the
    reconstructed origin land on `loc`, which is what the text is anchored to.
    """
    cx, cy = center
    dx -= cx
    dy -= cy
    if orient_byte & 0x04:
        dx = -dx
    orcad_angle = {0x01: 90, 0x05: 90, 0x02: 180, 0x06: 180,
                   0x03: 270, 0x07: 270}.get(orient_byte, 0)
    if orcad_angle == 90:
        dx, dy = (dy, -dx)
    elif orcad_angle == 180:
        dx, dy = (-dx, -dy)
    elif orcad_angle == 270:
        dx, dy = (-dy, dx)
    return (dx + cx, dy + cy)


def _origin_spread(origins):
    if len(origins) <= 1:
        return 0
    xs = [o[0] for o in origins]
    ys = [o[1] for o in origins]
    return max(max(xs) - min(xs), max(ys) - min(ys))


def _mean_origin(origins):
    return (
        sum(o[0] for o in origins) / len(origins),
        sum(o[1] for o in origins) / len(origins),
    )


def _match_cache_pin_origin(cache_pin_list, pins, orient_byte, center):
    """Return component origin by matching page pins to Cache hotpoints.

    Page pin records normally carry a 1-based index into the Cache pin list.
    Some OrCAD files are less direct: skipped/placeholder symbol pins or
    alternate pin-map structures can make the page index and Cache vector index
    disagree.  The placed page hotpoints and transformed Cache hotpoints still
    differ by one translation, so use that translation as a geometry fallback.
    """
    if not cache_pin_list or not pins:
        return None

    indexed_origins = []
    for pnum, px, py in pins:
        if 1 <= pnum <= len(cache_pin_list):
            chx, chy = cache_pin_list[pnum - 1]
            rhx, rhy = _forward_rotate(chx, chy, orient_byte, center)
            indexed_origins.append((px - rhx, py - rhy))

    if indexed_origins and _origin_spread(indexed_origins) <= 1:
        return _mean_origin(indexed_origins)

    rotated_cache = [
        _forward_rotate(hx, hy, orient_byte, center)
        for hx, hy in cache_pin_list
    ]
    candidates = defaultdict(list)
    for _pnum, px, py in pins:
        for rhx, rhy in rotated_cache:
            candidates[(round(px - rhx), round(py - rhy))].append((px, py))

    best = None
    for ox, oy in sorted(candidates):
        matched = 0
        residual = 0.0
        used = set()
        for _pnum, px, py in pins:
            best_dist = None
            best_idx = None
            for ci, (rhx, rhy) in enumerate(rotated_cache):
                if ci in used:
                    continue
                dx = px - (ox + rhx)
                dy = py - (oy + rhy)
                dist = dx * dx + dy * dy
                if best_dist is None or dist < best_dist:
                    best_dist = dist
                    best_idx = ci
            if best_dist is not None and best_dist <= 1:
                matched += 1
                residual += best_dist
                used.add(best_idx)
        score = (matched, -residual)
        if best is None or score > best[0]:
            best = (score, ox, oy)

    if best and best[0][0] > 0:
        return (best[1], best[2])
    if indexed_origins:
        return _mean_origin(indexed_origins)
    return None


def collect_pin_positions(components):
    """Return the set of absolute page-stream (x, y) of every placed
    component pin across `components`.

    Uses each component's `(x, y)` placement + `orient` and the
    Cache-derived pin list from `_cell_pin_lists` and `_cell_centers`.
    Falls back to `comp['pins']` for cells without Cache data.
    """
    positions = set()
    for comp in components:
        cell = comp['cell']
        cx_cy = _cell_centers.get(cell)
        pin_list = _cell_pin_lists.get(cell)
        if cx_cy and pin_list:
            cx, cy = cx_cy
            for hx, hy in pin_list:
                dx, dy = hx - cx, hy - cy
                rdx, rdy = _forward_rotate(dx, dy, comp['orient'])
                positions.add((round(comp['x'] + rdx),
                               round(comp['y'] + rdy)))
        else:
            for pn, px, py in comp['pins']:
                positions.add((px, py))
    return positions


def _sch_pin(num, x, y, direction, name="~", electrical_type="passive",
             length=None):
    """Generate a single pin in a symbol definition."""
    pin_len = length if length is not None else PIN_LENGTH
    name_esc = _pin_label_for_kicad(name)
    num_esc = _pin_label_for_kicad(num)
    return (
        f'\t\t\t\t(pin {electrical_type} line\n'
        f'\t\t\t\t\t(at {x:.2f} {y:.2f} {direction})\n'
        f'\t\t\t\t\t(length {pin_len:.2f})\n'
        f'\t\t\t\t\t(name "{name_esc}"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t\t(number "{num_esc}"\n'
        f'\t\t\t\t\t\t(effects\n'
        f'\t\t\t\t\t\t\t(font\n'
        f'\t\t\t\t\t\t\t\t(size 1.27 1.27)\n'
        f'\t\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t\t)\n'
        f'\t\t\t\t\t)\n'
        f'\t\t\t\t)\n'
    )


def _direction_from_vector(hx, hy, bx, by):
    """Compute KiCad pin direction from hotpoint→body vector."""
    dx = bx - hx
    dy = by - hy
    if abs(dx) >= abs(dy):
        return 0 if dx > 0 else 180
    return 270 if dy < 0 else 90


def _all_pin_names_match_numbers(classified):
    if not classified:
        return False
    for pn, _hx, _hy, _d, _et, orig, _plen, _pin_flags in classified:
        pn_s = str(pn)
        orig_s = str(orig)
        if pn_s != orig_s:
            return False
    return True


def _pin_record_hides_number(pin_flags):
    """OrCAD Cache pin byte 0x20 hides pin numbers; 0x21 shows them."""
    if pin_flags is None:
        return False
    return (pin_flags & 0x01) == 0


def _is_capacitor_cell_name(cell_name):
    """Return True for simple capacitor cache cells."""
    if not cell_name:
        return False
    name = cell_name.upper()
    return (name == 'C' or name.startswith('CAP') or name.startswith('CP'))


def _min_pin_length_for_numbers(classified):
    """Return minimum pin length so pin numbers are readable.

    Formula: max(PIN_LENGTH, (max_chars + 1) * 1.27), giving one
    character-width of padding between the number and the body edge.
    """
    max_chars = max(len(str(p[0])) for p in classified)
    return max(PIN_LENGTH, (max_chars + 1) * 1.27)


def _symbol_pin_visibility(classified, cell_name=None):
    """Return (hide_pin_names, hide_pin_numbers) for generated symbols."""
    if cell_name and cell_name in _cache_pin_visibility:
        pnv, pnumv = _cache_pin_visibility[cell_name]
        if len(classified) == 2 and _is_capacitor_cell_name(cell_name):
            return (not pnv, True)
        return (not pnv, not pnumv)
    if len(classified) == 1:
        return True, True
    if len(classified) == 2 and _is_capacitor_cell_name(cell_name):
        return True, True
    pin_flags = [p[7] for p in classified if p[7] is not None]
    if (len(classified) == 2 and pin_flags
            and any(_pin_record_hides_number(flags) for flags in pin_flags)):
        return True, True
    if _all_pin_names_match_numbers(classified):
        return True, False
    return False, False


def _arc_midpoint(cx, cy, rx, ry, sx, sy, ex, ey):
    """Compute the midpoint of a counterclockwise arc (in KiCad Y-up coords).

    cx,cy: center of the ellipse
    rx,ry: radii (half-axes)
    sx,sy: start point on the arc
    ex,ey: end point on the arc

    OrCAD arcs go counterclockwise in screen space (Y-down). After Y-flip
    to KiCad coords (Y-up), the sweep direction remains counterclockwise.

    Returns (mx, my) — the midpoint on the arc.
    """
    a_start = math.atan2((sy - cy) / ry if ry else 0,
                         (sx - cx) / rx if rx else 0)
    a_end = math.atan2((ey - cy) / ry if ry else 0,
                       (ex - cx) / rx if rx else 0)
    if a_end <= a_start:
        a_end += 2 * math.pi
    a_mid = (a_start + a_end) / 2
    mx = cx + rx * math.cos(a_mid)
    my = cy + ry * math.sin(a_mid)
    return round(mx, 2), round(my, 2)


def _emit_arc(parts, cx, cy, rx, ry, sx, sy, ex, ey):
    """Emit a KiCad arc primitive.

    For circular arcs (rx == ry), uses KiCad's native (arc ...) primitive.
    For elliptical arcs, approximates with a polyline.
    """
    mx, my = _arc_midpoint(cx, cy, rx, ry, sx, sy, ex, ey)
    if abs(rx - ry) < 0.01:
        parts.append(f'\t\t\t\t(arc\n')
        parts.append(f'\t\t\t\t\t(start {sx:.2f} {sy:.2f})\n')
        parts.append(f'\t\t\t\t\t(mid {mx:.2f} {my:.2f})\n')
        parts.append(f'\t\t\t\t\t(end {ex:.2f} {ey:.2f})\n')
        parts.append('\t\t\t\t\t(stroke\n')
        parts.append('\t\t\t\t\t\t(width 0.254)\n')
        parts.append('\t\t\t\t\t\t(type default)\n')
        parts.append('\t\t\t\t\t)\n')
        parts.append('\t\t\t\t\t(fill\n')
        parts.append('\t\t\t\t\t\t(type none)\n')
        parts.append('\t\t\t\t\t)\n')
        parts.append('\t\t\t\t)\n')
    else:
        a_start = math.atan2((sy - cy) / ry if ry else 0,
                             (sx - cx) / rx if rx else 0)
        a_end = math.atan2((ey - cy) / ry if ry else 0,
                           (ex - cx) / rx if rx else 0)
        if a_end <= a_start:
            a_end += 2 * math.pi
        n = 32
        parts.append(f'\t\t\t\t(polyline\n')
        parts.append(f'\t\t\t\t\t(pts\n')
        for i in range(n + 1):
            a = a_start + (a_end - a_start) * i / n
            x = cx + rx * math.cos(a)
            y = cy + ry * math.sin(a)
            parts.append(f'\t\t\t\t\t\t(xy {x:.2f} {y:.2f})\n')
        parts.append(f'\t\t\t\t\t)\n')
        parts.append('\t\t\t\t\t(stroke\n')
        parts.append('\t\t\t\t\t\t(width 0.254)\n')
        parts.append('\t\t\t\t\t\t(type default)\n')
        parts.append('\t\t\t\t\t)\n')
        parts.append('\t\t\t\t\t(fill\n')
        parts.append('\t\t\t\t\t\t(type none)\n')
        parts.append('\t\t\t\t\t)\n')
        parts.append('\t\t\t\t)\n')


def _emit_ellipse_polyline(parts, cx, cy, rx, ry, n=32):
    """Approximate an ellipse as a closed polyline."""
    parts.append(f'\t\t\t\t(polyline\n')
    parts.append(f'\t\t\t\t\t(pts\n')
    for i in range(n + 1):
        angle = 2 * math.pi * i / n
        x = cx + rx * math.cos(angle)
        y = cy + ry * math.sin(angle)
        parts.append(f'\t\t\t\t\t\t(xy {x:.2f} {y:.2f})\n')
    parts.append(f'\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(stroke\n')
    parts.append('\t\t\t\t\t\t(width 0.254)\n')
    parts.append('\t\t\t\t\t\t(type default)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(fill\n')
    parts.append('\t\t\t\t\t\t(type none)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t)\n')


def lib_symbol_from_pins(name, pin_positions, body_rects=None,
                         body_lines=None, body_ellipses=None,
                         body_arcs=None, body_polygons=None,
                         body_polylines=None,
                         text_annotations=None):
    """Generate a symbol definition from pin positions.

    pin_positions: list of tuples, either:
      (pin_num, hot_x, hot_y)                              — 3 elements
      (pin_num, hot_x, hot_y, orig_name)                   — 4 elements
      (pin_num, hot_x, hot_y, orig_name, body_x, body_y)   — 6 elements
      (pin_num, hot_x, hot_y, orig_name, body_x, body_y,
       pin_flags)                                          — 7 elements

    body_rects: optional list of (x1, y1, x2, y2) in mm. One rect for
    most cells; two for cells with composite bodies (e.g. SD-card
    socket CARD_SOCKET has an inner slot rect and an outer housing
    rect, sharing one edge). All rects are emitted as KiCad
    `(rectangle ...)` primitives. Already centered and Y-flipped to
    symbol coordinates.
    body_lines: optional list of (x1, y1, x2, y2) in mm. Line segments
    from Cache (0x2929 records). Emitted as KiCad `(polyline ...)`
    primitives.
    text_annotations: optional list of (cx, cy, text) in mm — internal
    body labels such as 'A', 'B', 'G' on SD-card socket symbols.

    When body coordinates are provided, pin direction and body rectangle
    are derived from the actual hotpoint→body vector. Otherwise falls back
    to center-based direction guessing.
    """
    if not pin_positions:
        if not (body_rects or body_lines or body_ellipses or body_arcs
                or body_polygons):
            return lib_symbol_generic_fallback(name)

    has_body = (pin_positions
                and len(pin_positions[0]) >= 6
                and pin_positions[0][4] is not None)

    classified = []
    body_xs = []
    body_ys = []

    if has_body:
        for p in pin_positions:
            pn = p[0]
            hx, hy = p[1], p[2]
            orig = p[3] if len(p) > 3 else str(pn)
            bx, by = p[4], p[5]
            pin_flags = p[6] if len(p) > 6 else None
            direction = _direction_from_vector(hx, hy, bx, by)
            pin_len = round(math.hypot(bx - hx, by - hy), 2)
            if pin_len < 0.01:
                pin_len = PIN_LENGTH
            etype = "no_connect" if orig.upper() == "NC" else "passive"
            classified.append((pn, hx, hy, direction, etype, orig, pin_len,
                               pin_flags))
            body_xs.append(bx)
            body_ys.append(by)
    elif pin_positions:
        xs = [p[1] for p in pin_positions]
        ys = [p[2] for p in pin_positions]
        x_mid = (min(xs) + max(xs)) / 2
        y_mid = (min(ys) + max(ys)) / 2
        for p in pin_positions:
            pn = p[0]
            hx, hy = p[1], p[2]
            orig = p[3] if len(p) > 3 else str(pn)
            pin_flags = p[6] if len(p) > 6 else None
            dx, dy = hx - x_mid, hy - y_mid
            if abs(dx) >= abs(dy):
                direction = 0 if dx < 0 else 180
            else:
                direction = 270 if dy > 0 else 90
            etype = "no_connect" if orig.upper() == "NC" else "passive"
            classified.append((pn, hx, hy, direction, etype, orig,
                               PIN_LENGTH, pin_flags))
            if direction == 0:
                body_xs.append(hx + PIN_LENGTH)
            elif direction == 180:
                body_xs.append(hx - PIN_LENGTH)
            else:
                body_xs.append(hx)
            if direction == 270:
                body_ys.append(hy - PIN_LENGTH)
            elif direction == 90:
                body_ys.append(hy + PIN_LENGTH)
            else:
                body_ys.append(hy)

    all_xs, all_ys = list(body_xs), list(body_ys)
    if body_rects:
        for r in body_rects:
            all_xs.extend((r[0], r[2]))
            all_ys.extend((r[1], r[3]))
    if body_lines:
        for ln in body_lines:
            all_xs.extend((ln[0], ln[2]))
            all_ys.extend((ln[1], ln[3]))
    if body_arcs:
        for a in body_arcs:
            all_xs.extend((a[0], a[2]))
            all_ys.extend((a[1], a[3]))
    if body_ellipses:
        for e in body_ellipses:
            all_xs.extend((e[0], e[2]))
            all_ys.extend((e[1], e[3]))
    if all_xs:
        bx1, bx2 = min(all_xs), max(all_xs)
        by1, by2 = min(all_ys), max(all_ys)
    else:
        bx1, by1, bx2, by2 = -5.08, -5.08, 5.08, 5.08

    ref_y = by2 + 2.54
    val_y = by1 - 2.54

    hide_pin_names, hide_pin_numbers = _symbol_pin_visibility(classified,
                                                              name)

    if classified and not hide_pin_numbers:
        min_len = _min_pin_length_for_numbers(classified)
        extended = []
        deltas = {}
        for pn, hx, hy, direction, etype, orig, pin_len, pflags in classified:
            if pin_len < min_len:
                delta = round(min_len - pin_len, 2)
                dx, dy = 0.0, 0.0
                if direction == 0:
                    dx = -delta
                elif direction == 180:
                    dx = delta
                elif direction == 90:
                    dy = -delta
                elif direction == 270:
                    dy = delta
                hx = round(hx + dx, 2)
                hy = round(hy + dy, 2)
                deltas[str(pn)] = (dx, dy)
                pin_len = min_len
            extended.append((pn, hx, hy, direction, etype, orig, pin_len,
                             pflags))
        classified = extended
        if deltas:
            _pin_extension_deltas[name] = deltas

    parts = []
    parts.append(f'\t\t(symbol "{name}"\n')
    parts.append('\t\t\t(exclude_from_sim no)\n')
    parts.append('\t\t\t(in_bom yes)\n')
    parts.append('\t\t\t(on_board yes)\n')
    if hide_pin_numbers:
        parts.append('\t\t\t(pin_numbers hide)\n')
    if hide_pin_names:
        parts.append('\t\t\t(pin_names\n')
        parts.append('\t\t\t\t(offset 1.016)\n')
        parts.append('\t\t\t\thide)\n')
    parts.append(f'\t\t\t(property "Reference" "U"\n')
    parts.append(f'\t\t\t\t(at 0 {ref_y:.2f} 0)\n')
    parts.append('\t\t\t\t(effects\n')
    parts.append('\t\t\t\t\t(font\n')
    parts.append('\t\t\t\t\t\t(size 1.27 1.27)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t)\n')
    parts.append('\t\t\t)\n')
    parts.append(f'\t\t\t(property "Value" "{name}"\n')
    parts.append(f'\t\t\t\t(at 0 {val_y:.2f} 0)\n')
    parts.append('\t\t\t\t(effects\n')
    parts.append('\t\t\t\t\t(font\n')
    parts.append('\t\t\t\t\t\t(size 1.27 1.27)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t)\n')
    parts.append('\t\t\t)\n')

    parts.append(f'\t\t\t(symbol "{name}_0_1"\n')
    if body_rects:
        rects_to_emit = body_rects
    elif classified and not (body_lines or body_ellipses or body_arcs):
        rects_to_emit = [(bx1, by1, bx2, by2)]
    else:
        rects_to_emit = []
    if rects_to_emit:
        for rx1, ry1, rx2, ry2 in rects_to_emit:
            _emit_symbol_rectangle(parts, rx1, ry1, rx2, ry2)
    if body_polygons:
        for poly in body_polygons:
            _emit_filled_polygon(parts, poly)
    if body_polylines:
        for pline in body_polylines:
            parts.append('\t\t\t\t(polyline\n')
            parts.append('\t\t\t\t\t(pts\n')
            for px, py in pline:
                parts.append(f'\t\t\t\t\t\t(xy {px:.2f} {py:.2f})\n')
            parts.append('\t\t\t\t\t)\n')
            parts.append('\t\t\t\t\t(stroke\n')
            parts.append('\t\t\t\t\t\t(width 0.254)\n')
            parts.append('\t\t\t\t\t\t(type default)\n')
            parts.append('\t\t\t\t\t)\n')
            parts.append('\t\t\t\t\t(fill\n')
            parts.append('\t\t\t\t\t\t(type none)\n')
            parts.append('\t\t\t\t\t)\n')
            parts.append('\t\t\t\t)\n')
    if body_lines:
        for lx1, ly1, lx2, ly2 in body_lines:
            _emit_symbol_line(parts, lx1, ly1, lx2, ly2)
    if text_annotations:
        for ann_entry in text_annotations:
            tx, ty, text = ann_entry[0], ann_entry[1], ann_entry[2]
            text_angle = ann_entry[3] if len(ann_entry) > 3 else 0
            if not text:
                continue
            text_esc = _esc_kicad_str(text)
            parts.append(f'\t\t\t\t(text "{text_esc}"\n')
            parts.append(f'\t\t\t\t\t(at {tx:.2f} {ty:.2f} {text_angle})\n')
            parts.append('\t\t\t\t\t(effects\n')
            parts.append('\t\t\t\t\t\t(font\n')
            parts.append('\t\t\t\t\t\t\t(size 1.27 1.27)\n')
            parts.append('\t\t\t\t\t\t)\n')
            parts.append('\t\t\t\t\t)\n')
            parts.append('\t\t\t\t)\n')
    if body_ellipses:
        for ex1, ey1, ex2, ey2 in body_ellipses:
            ecx = (ex1 + ex2) / 2
            ecy = (ey1 + ey2) / 2
            rx = abs(ex2 - ex1) / 2
            ry = abs(ey2 - ey1) / 2
            if abs(rx - ry) < 0.01:
                parts.append(f'\t\t\t\t(circle\n')
                parts.append(f'\t\t\t\t\t(center {ecx:.2f} {ecy:.2f})\n')
                parts.append(f'\t\t\t\t\t(radius {rx:.2f})\n')
                parts.append('\t\t\t\t\t(stroke\n')
                parts.append('\t\t\t\t\t\t(width 0.254)\n')
                parts.append('\t\t\t\t\t\t(type default)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t\t(fill\n')
                parts.append('\t\t\t\t\t\t(type none)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t)\n')
            else:
                _emit_ellipse_polyline(parts, ecx, ecy, rx, ry)
    if body_arcs:
        for bx1, by1, bx2, by2, sx, sy, ex, ey in body_arcs:
            acx = (bx1 + bx2) / 2
            acy = (by1 + by2) / 2
            arx = abs(bx2 - bx1) / 2
            ary = abs(by2 - by1) / 2
            _emit_arc(parts, acx, acy, arx, ary, sx, sy, ex, ey)
    parts.append('\t\t\t)\n')

    parts.append(f'\t\t\t(symbol "{name}_1_1"\n')
    for pn, hx, hy, d, et, orig, plen, _pin_flags in classified:
        parts.append(_sch_pin(pn, hx, hy, d, name=orig,
                              electrical_type=et, length=plen))
    parts.append('\t\t\t)\n')
    parts.append('\t\t)\n')
    return "".join(parts)


def lib_symbol_generic_fallback(name, num_pins=2):
    """Fallback box symbol when no pin data is available."""
    half_h = max(num_pins * 1.27, 3.81)
    pin_positions = []
    for i in range(num_pins):
        pin_y = half_h - 2.54 * i - 1.27
        pin_positions.append((i + 1, -3.81 - PIN_LENGTH, pin_y))
    return lib_symbol_from_pins(name, pin_positions)


def _build_unit_pin_data(cell_name):
    """Build classified pin data for one unit from _cell_pin_defs and Cache.

    Returns (classified_pins, body_rects, text_annotations) ready for
    embedding into a multi-unit symbol, or None if no pin data.
    """
    pin_positions = _cell_pin_defs.get(cell_name)
    if not pin_positions:
        return None
    has_body = (len(pin_positions[0]) >= 6
                and pin_positions[0][4] is not None)

    classified = []
    body_xs, body_ys = [], []
    for p in pin_positions:
        pn, hx, hy = p[0], p[1], p[2]
        orig = p[3] if len(p) > 3 else str(pn)
        pin_flags = p[6] if len(p) > 6 else None
        etype = "no_connect" if orig.upper() == "NC" else "passive"
        if has_body:
            bx, by = p[4], p[5]
            direction = _direction_from_vector(hx, hy, bx, by)
            pin_len = round(math.hypot(bx - hx, by - hy), 2)
            if pin_len < 0.01:
                pin_len = PIN_LENGTH
            body_xs.append(bx)
            body_ys.append(by)
        else:
            xs = [pp[1] for pp in pin_positions]
            ys = [pp[2] for pp in pin_positions]
            x_mid = (min(xs) + max(xs)) / 2
            y_mid = (min(ys) + max(ys)) / 2
            dx, dy = hx - x_mid, hy - y_mid
            if abs(dx) >= abs(dy):
                direction = 0 if dx < 0 else 180
            else:
                direction = 270 if dy > 0 else 90
            pin_len = PIN_LENGTH
            if direction == 0:
                body_xs.append(hx + PIN_LENGTH)
            elif direction == 180:
                body_xs.append(hx - PIN_LENGTH)
            else:
                body_xs.append(hx)
            if direction == 270:
                body_ys.append(hy - PIN_LENGTH)
            elif direction == 90:
                body_ys.append(hy + PIN_LENGTH)
            else:
                body_ys.append(hy)
        classified.append((pn, hx, hy, direction, etype, orig, pin_len,
                           pin_flags))

    _, hide_pin_numbers = _symbol_pin_visibility(classified, cell_name)
    if classified and not hide_pin_numbers:
        min_len = _min_pin_length_for_numbers(classified)
        extended = []
        deltas = {}
        for pn, hx, hy, direction, etype, orig, pin_len, pflags in classified:
            if pin_len < min_len:
                d = round(min_len - pin_len, 2)
                dx, dy = 0.0, 0.0
                if direction == 0:
                    dx = -d
                elif direction == 180:
                    dx = d
                elif direction == 90:
                    dy = -d
                elif direction == 270:
                    dy = d
                hx = round(hx + dx, 2)
                hy = round(hy + dy, 2)
                deltas[str(pn)] = (dx, dy)
                pin_len = min_len
            extended.append((pn, hx, hy, direction, etype, orig, pin_len,
                             pflags))
        classified = extended
        if deltas:
            _pin_extension_deltas[cell_name] = deltas

    rects = _cell_body_rects.get(cell_name)
    lines = _cell_body_lines.get(cell_name)
    ann = _cell_text_annotations.get(cell_name)
    ellipses = _cell_body_ellipses.get(cell_name)
    arcs = _cell_body_arcs.get(cell_name)
    polys = _cell_body_polygons.get(cell_name)
    plines = _cell_body_polylines.get(cell_name)

    if not rects and not (ellipses or arcs) and body_xs:
        x1, y1 = min(body_xs), min(body_ys)
        x2, y2 = max(body_xs), max(body_ys)
        MIN_BODY = 5.08
        if abs(x2 - x1) < 0.1:
            x1 -= MIN_BODY
            x2 += MIN_BODY
        if abs(y2 - y1) < 0.1:
            y1 -= MIN_BODY
            y2 += MIN_BODY
        rects = [(x1, y1, x2, y2)]

    return classified, rects, lines, ann, ellipses, arcs, polys, plines


def lib_symbol_multi_unit(base_name, unit_map):
    """Generate a multi-unit KiCad symbol.

    base_name: parent symbol name (e.g., "CPU")
    unit_map: {cell_name: unit_number} — all cells in this group
    """
    parts = []
    parts.append(f'\t\t(symbol "{base_name}"\n')
    parts.append('\t\t\t(pin_names (offset 1.016))\n')
    parts.append('\t\t\t(exclude_from_sim no)\n')
    parts.append('\t\t\t(in_bom yes)\n')
    parts.append('\t\t\t(on_board yes)\n')
    parts.append(f'\t\t\t(property "Reference" "U"\n')
    parts.append(f'\t\t\t\t(at 0 2.54 0)\n')
    parts.append('\t\t\t\t(effects\n')
    parts.append('\t\t\t\t\t(font\n')
    parts.append('\t\t\t\t\t\t(size 1.27 1.27)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(justify left)\n')
    parts.append('\t\t\t\t)\n')
    parts.append('\t\t\t)\n')
    parts.append(f'\t\t\t(property "Value" "{_esc_kicad_str(base_name)}"\n')
    parts.append(f'\t\t\t\t(at 0 -2.54 0)\n')
    parts.append('\t\t\t\t(effects\n')
    parts.append('\t\t\t\t\t(font\n')
    parts.append('\t\t\t\t\t\t(size 1.27 1.27)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(justify left)\n')
    parts.append('\t\t\t\t)\n')
    parts.append('\t\t\t)\n')

    for cell_name, unit_num in sorted(unit_map.items(), key=lambda kv: kv[1]):
        data = _build_unit_pin_data(cell_name)
        if data is None:
            continue
        classified, rects, lines, ann, ellipses, arcs, polys, plines = data

        # Unit body (graphics): {base}_{unit}_0
        parts.append(f'\t\t\t(symbol "{base_name}_{unit_num}_0"\n')
        if rects:
            for rx1, ry1, rx2, ry2 in rects:
                parts.append(f'\t\t\t\t(rectangle\n')
                parts.append(f'\t\t\t\t\t(start {rx1:.2f} {ry1:.2f})\n')
                parts.append(f'\t\t\t\t\t(end {rx2:.2f} {ry2:.2f})\n')
                parts.append('\t\t\t\t\t(stroke\n')
                parts.append('\t\t\t\t\t\t(width 0.254)\n')
                parts.append('\t\t\t\t\t\t(type default)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t\t(fill\n')
                parts.append('\t\t\t\t\t\t(type background)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t)\n')
        if lines:
            for lx1, ly1, lx2, ly2 in lines:
                _emit_symbol_line(parts, lx1, ly1, lx2, ly2)
        if ann:
            for ann_entry in ann:
                tx, ty, text = ann_entry[0], ann_entry[1], ann_entry[2]
                text_angle = ann_entry[3] if len(ann_entry) > 3 else 0
                if not text:
                    continue
                text_esc = _esc_kicad_str(text)
                parts.append(f'\t\t\t\t(text "{text_esc}"\n')
                parts.append(f'\t\t\t\t\t(at {tx:.2f} {ty:.2f} {text_angle})\n')
                parts.append('\t\t\t\t\t(effects\n')
                parts.append('\t\t\t\t\t\t(font\n')
                parts.append('\t\t\t\t\t\t\t(size 1.27 1.27)\n')
                parts.append('\t\t\t\t\t\t)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t)\n')
        if ellipses:
            for ex1, ey1, ex2, ey2 in ellipses:
                ecx = (ex1 + ex2) / 2
                ecy = (ey1 + ey2) / 2
                rx = abs(ex2 - ex1) / 2
                ry = abs(ey2 - ey1) / 2
                if abs(rx - ry) < 0.01:
                    parts.append(f'\t\t\t\t(circle\n')
                    parts.append(f'\t\t\t\t\t(center {ecx:.2f} {ecy:.2f})\n')
                    parts.append(f'\t\t\t\t\t(radius {rx:.2f})\n')
                    parts.append('\t\t\t\t\t(stroke\n')
                    parts.append('\t\t\t\t\t\t(width 0.254)\n')
                    parts.append('\t\t\t\t\t\t(type default)\n')
                    parts.append('\t\t\t\t\t)\n')
                    parts.append('\t\t\t\t\t(fill\n')
                    parts.append('\t\t\t\t\t\t(type none)\n')
                    parts.append('\t\t\t\t\t)\n')
                    parts.append('\t\t\t\t)\n')
                else:
                    _emit_ellipse_polyline(parts, ecx, ecy, rx, ry)
        if arcs:
            for bx1, by1, bx2, by2, sx, sy, ex, ey in arcs:
                acx = (bx1 + bx2) / 2
                acy = (by1 + by2) / 2
                arx = abs(bx2 - bx1) / 2
                ary = abs(by2 - by1) / 2
                _emit_arc(parts, acx, acy, arx, ary, sx, sy, ex, ey)
        if polys:
            for poly in polys:
                pts_str = " ".join(f"(xy {x:.2f} {y:.2f})"
                                   for x, y in poly)
                parts.append(
                    f'\t\t\t\t(polyline\n'
                    f'\t\t\t\t\t(pts\n'
                    f'\t\t\t\t\t\t{pts_str}\n'
                    f'\t\t\t\t\t)\n'
                    f'\t\t\t\t\t(stroke\n'
                    f'\t\t\t\t\t\t(width 0)\n'
                    f'\t\t\t\t\t\t(type default)\n'
                    f'\t\t\t\t\t)\n'
                    f'\t\t\t\t\t(fill\n'
                    f'\t\t\t\t\t\t(type outline)\n'
                    f'\t\t\t\t\t)\n'
                    f'\t\t\t\t)\n'
                )
        if plines:
            for pline in plines:
                parts.append('\t\t\t\t(polyline\n')
                parts.append('\t\t\t\t\t(pts\n')
                for px, py in pline:
                    parts.append(f'\t\t\t\t\t\t(xy {px:.2f} {py:.2f})\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t\t(stroke\n')
                parts.append('\t\t\t\t\t\t(width 0.254)\n')
                parts.append('\t\t\t\t\t\t(type default)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t\t(fill\n')
                parts.append('\t\t\t\t\t\t(type none)\n')
                parts.append('\t\t\t\t\t)\n')
                parts.append('\t\t\t\t)\n')
        parts.append('\t\t\t)\n')

        # Unit pins: {base}_{unit}_1
        parts.append(f'\t\t\t(symbol "{base_name}_{unit_num}_1"\n')
        for pn, hx, hy, d, et, orig, plen, _pin_flags in classified:
            parts.append(_sch_pin(pn, hx, hy, d, name=orig,
                                  electrical_type=et, length=plen))
        parts.append('\t\t\t)\n')

    parts.append('\t\t)\n')
    return "".join(parts)


# Map OrCAD cell names to KiCad library symbol info
# R and C are NOT mapped to KiCad built-ins: their drawings live in the DSN Cache
# (a horizontal zig-zag / parallel plates), so they go through the generic cache
# path to preserve the OrCAD look-and-feel (and pick up the bbox-centre mirror).
CELL_TO_KICAD = {}


# Cell definitions built from pin data: {cell_name: [(pin_num, sym_x_mm, sym_y_mm), ...]}
_cell_pin_defs = {}

# Body rectangles from Cache: {cell_name: [(x1_mm, y1_mm, x2_mm, y2_mm), ...]}
# in symbol coords. One rect for most cells; two for cells with composite
# bodies (e.g. SD-card socket CARD_SOCKET).
_cell_body_rects = {}

# Body line segments from Cache: {cell_name: [(x1_mm, y1_mm, x2_mm, y2_mm), ...]}
# in symbol coords. Used by DIP-switch symbols and others whose body is drawn
# with individual lines rather than a rectangle record.
_cell_body_lines = {}
_cell_body_ellipses = {}
_cell_body_arcs = {}
_cell_body_polygons = {}
_cell_body_polylines = {}

# Text annotations from Cache: {cell_name: [(cx_mm, cy_mm, text), ...]} in symbol coords
_cell_text_annotations = {}

# All-pin hotpoint center in OrCAD units: {cell_name: (cx, cy)}
_cell_centers = {}

# Cache pins in original order: {cell_name: [(hot_x, hot_y), ...]}
# Pin at index i corresponds to page-stream pin_num = i+1
_cell_pin_lists = {}

# OrCAD symbol bounding box (body extent) in cache units, same frame as the pin
# hot-points: {cell_name: (x1, y1, x2, y2)}.  Debug overlay (--debug-symbol).
_cell_bboxes = {}

# Pin extension deltas in symbol-local mm: {cell_name: {pin_num: (dx, dy)}}
# Populated by lib_symbol_from_pins when pins are extended for readability.
_pin_extension_deltas = {}

# Pin visibility from Cache LibraryPart GeneralProperties:
# {cell_name: (pin_name_visible, pin_number_visible)}
_cache_pin_visibility = {}

# Multi-unit symbol groups detected from page instances.
# {base_name: {cell_name: unit_number (1-based), ...}}
# e.g. {"CPU": {"CPU_3A": 1, "CPU_3T": 2, ...}}
_multi_unit_groups = {}

# Reverse lookup: {cell_name: (base_name, unit_number)}
_multi_unit_cell_map = {}


def detect_multi_unit_components(ole):
    """Scan all page instances to detect multi-unit components.

    A component is multi-unit when multiple distinct cell names share the
    same reference designator across pages (e.g., U1 with cells CPU_3A,
    CPU_3T, CPU_2J, etc.).

    Populates _multi_unit_groups and _multi_unit_cell_map.
    """
    global _multi_unit_groups, _multi_unit_cell_map

    page_streams = get_page_streams(ole)
    ref_cells = defaultdict(list)
    for sp in page_streams:
        data = ole.openstream(sp).read()
        comps = parse_components(data)
        for c in comps:
            if c['ref'] and c['cell']:
                ref_cells[c['ref']].append(c['cell'])

    _multi_unit_groups = {}
    _multi_unit_cell_map = {}
    for ref, cells in ref_cells.items():
        distinct = list(dict.fromkeys(cells))
        if len(distinct) <= 1:
            continue
        base = os.path.commonprefix(distinct).rstrip('_')
        if not base:
            base = ref
        unit_map = {}
        for cell_name in distinct:
            suffix = cell_name[len(base):].lstrip('_')
            last_ch = suffix[-1] if suffix else ''
            if last_ch.isalpha():
                unit_num = ord(last_ch.upper()) - ord('A') + 1
            else:
                unit_num = len(unit_map) + 1
            while unit_num in unit_map.values():
                unit_num += 1
            unit_map[cell_name] = unit_num
        _multi_unit_groups[base] = unit_map
        for cell_name, unit_num in unit_map.items():
            _multi_unit_cell_map[cell_name] = (base, unit_num)

    return _multi_unit_groups


def register_cell_pins(cell_name, pins, orient_byte, center_x, center_y):
    """Register cell pin layout from a component instance (prefer 0° orient).

    Page-stream coordinates have Y increasing downward, same as KiCad
    schematic coordinates, so no Y-flip is needed (unlike Cache coords
    which use Y-up library space).
    """
    if cell_name in CELL_TO_KICAD:
        return
    if cell_name in _cell_pin_defs:
        if orient_byte != 0:
            return
    pin_positions = []
    for pn, px, py in pins:
        dx, dy = px - center_x, py - center_y
        dx0, dy0 = _inverse_rotate(dx, dy, orient_byte)
        sym_x = dx0 * UNIT_TO_MM
        sym_y = dy0 * UNIT_TO_MM
        pin_positions.append((pn, round(sym_x, 2), round(sym_y, 2),
                              str(pn), None, None))
    if pin_positions:
        _cell_pin_defs[cell_name] = pin_positions


def get_lib_symbol(cell_name):
    """Get (lib_id, ref_prefix, lib_def_func) for a cell name.

    For multi-unit cells, returns the base name as lib_id so all units
    share one symbol definition.
    """
    if cell_name in CELL_TO_KICAD:
        return CELL_TO_KICAD[cell_name]
    if cell_name in _multi_unit_cell_map:
        base_name, _ = _multi_unit_cell_map[cell_name]
        ref_prefix = base_name[0] if base_name else 'U'
        unit_map = _multi_unit_groups[base_name]
        return (base_name, ref_prefix,
                lambda bn=base_name, um=unit_map:
                    lib_symbol_multi_unit(bn, um))
    ref_prefix = cell_name[0] if cell_name else 'U'
    pin_positions = _cell_pin_defs.get(cell_name)
    if pin_positions:
        rects = _cell_body_rects.get(cell_name)
        ann = _cell_text_annotations.get(cell_name)
        lines = _cell_body_lines.get(cell_name)
        ellipses = _cell_body_ellipses.get(cell_name)
        arcs = _cell_body_arcs.get(cell_name)
        polys = _cell_body_polygons.get(cell_name)
        plines = _cell_body_polylines.get(cell_name)
        return (cell_name, ref_prefix,
                lambda name=cell_name, pp=pin_positions, body_rects=rects,
                       body_lines=lines, body_ellipses=ellipses,
                       body_arcs=arcs, body_polygons=polys,
                       body_polylines=plines,
                       text_annotations=ann:
                    lib_symbol_from_pins(name, pp, body_rects=body_rects,
                                         body_lines=body_lines,
                                         body_ellipses=body_ellipses,
                                         body_arcs=body_arcs,
                                         body_polygons=body_polygons,
                                         body_polylines=body_polylines,
                                         text_annotations=text_annotations))
    rects = _cell_body_rects.get(cell_name)
    lines = _cell_body_lines.get(cell_name)
    ellipses = _cell_body_ellipses.get(cell_name)
    arcs = _cell_body_arcs.get(cell_name)
    polys = _cell_body_polygons.get(cell_name)
    plines = _cell_body_polylines.get(cell_name)
    if rects or lines or ellipses or arcs or polys or plines:
        return (cell_name, ref_prefix,
                lambda name=cell_name, body_rects=rects, body_lines=lines,
                       body_ellipses=ellipses, body_arcs=arcs,
                       body_polygons=polys, body_polylines=plines:
                    lib_symbol_from_pins(name, [], body_rects=body_rects,
                                         body_lines=body_lines,
                                         body_ellipses=body_ellipses,
                                         body_arcs=body_arcs,
                                         body_polygons=body_polygons,
                                         body_polylines=body_polylines))
    return (cell_name, ref_prefix,
            lambda name=cell_name: lib_symbol_generic_fallback(name))


# Empty: R/C now use their OrCAD (horizontal) Cache drawing, so no vertical-body
# remap is needed. (KiCad's built-in R/C were vertical, which is why this existed.)
VERTICAL_BODY_CELLS = set()

def orient_to_angle(orient_byte, cell_name):
    """Convert OrCAD orientation byte to KiCad angle in degrees.

    OrCAD default orientation is horizontal (pins left/right).
    KiCad R/C symbols have vertical body (pins top/bottom) at angle=0,
    so OrCAD's 90° (vertical) maps to KiCad 0°, and vice versa.
    Generic symbols with horizontal body use the direct mapping.

    When mirrored (bit 2 set), KiCad applies rotation first then mirror,
    but OrCAD applies mirror first then rotation. To compensate, the
    rotation angle is negated (90<->270) for mirrored components.
    """
    orcad_angle = {0x01: 90, 0x05: 90, 0x02: 180, 0x06: 180,
                   0x03: 270, 0x07: 270}.get(orient_byte, 0)

    if orient_byte & 0x04:
        orcad_angle = (360 - orcad_angle) % 360

    if cell_name in VERTICAL_BODY_CELLS:
        return (90 - orcad_angle) % 360

    return orcad_angle


def _default_text_style(library_styles):
    """Reference/Value text style for a DSN, derived from the font-style table.

    OrCAD ref/value records carry no per-instance font, so use the modal
    regular-weight Arial style (its LOGFONT lfHeight lives in `tag`). The emitted
    KiCad `(size)` is |lfHeight| in DSN units → mm (UNIT_TO_MM) divided by KiCad's
    1.4 outline-font compensation. Returns (size_mm, face, bold, italic).
    """
    counts = {}
    for s in (library_styles or []):
        if s.get('weight', 400) != 400 or s.get('italic'):
            continue
        face = s.get('face') or ''
        if face not in ('', 'Arial'):
            continue
        key = (abs(s.get('tag', 0)), face)
        counts[key] = counts.get(key, 0) + 1
    if counts:
        (lfh, face), _ = max(counts.items(), key=lambda kv: kv[1])
        if lfh:
            return (lfh * UNIT_TO_MM / KICAD_FONT_SIZE_COMPENSATION,
                    face or 'Arial', False, False)
    return (1.27, 'Arial', False, False)


def _text_center_mm(origin, off, text, text_angle,
                    size_mm, face, bold, italic):
    """Page-space centre anchor for a Reference/Value text field.

    OrCAD's display-prop (x, y) offset lands at the axis-aligned top-left corner
    of the rendered text box in page coordinates, independent of component
    rotation/mirror. Convert that corner to the centre anchor KiCad wants for a
    centre-justified field, with the same perpendicular nudge used by
    tests/kicad_pdf_join.py for PDF overlays.
    """
    if origin is None or off is None:
        return None
    x = dsn_to_mm(origin[0] + off[0])
    y = dsn_to_mm(origin[1] + off[1])
    width = (measure_text_width(text, size_mm, face or 'Arial', bold, italic)
             * KICAD_FONT_SIZE_COMPENSATION)
    height = (measure_text_height(text, size_mm, face or 'Arial', bold, italic)
              * KICAD_FONT_SIZE_COMPENSATION)
    angle = int(text_angle or 0) % 360
    if angle in (90, 270):
        box_w, box_h = height, width
    else:
        box_w, box_h = width, height
    pdx, pdy = {0: (0, 1), 90: (1, 0), 180: (0, -1),
                270: (-1, 0)}.get(angle, (0, 1))
    nudge = 0.416 * size_mm
    return (x + box_w / 2.0 + nudge * pdx,
            y + box_h / 2.0 + nudge * pdy)


def sch_component(ref, lib_id, x, y, angle=0, value="", pin_numbers=None,
                  ref_center=None, val_center=None,
                  ref_text_angle=None, val_text_angle=None,
                  unit=1, mirror_x=False, dnp=False,
                  text_size_mm=1.27, text_face=None,
                  text_bold=False, text_italic=False):
    """Generate a KiCad component instance (symbol placement).

    ref_center/val_center: absolute KiCad mm position of the text bbox centre.
    When given, the field is emitted centre-justified at that point, which is
    invariant to the symbol's rotation/mirror (preferred).
    unit: 1-based unit number for multi-unit symbols.
    mirror_x: if True, emit (mirror x) to flip the symbol horizontally.
    """
    uid = new_uuid()
    ref_esc = _esc_kicad_str(ref)
    val = value if value else lib_id
    val_esc = _esc_kicad_str(val)

    if ref_center is not None:
        ref_x, ref_y = ref_center
    else:
        ref_x, ref_y = x + 2.54, y
        if angle == 90 or angle == 270:
            ref_x, ref_y = x, y + 2.54

    if val_center is not None:
        val_x, val_y = val_center
    else:
        val_x, val_y = x - 2.54, y
        if angle == 90 or angle == 270:
            val_x, val_y = x, y - 2.54

    if ref_text_angle is not None:
        ref_angle = (ref_text_angle - angle) % 360
    else:
        ref_angle = 0
    if val_text_angle is not None:
        val_angle = (val_text_angle - angle) % 360
    else:
        val_angle = 0
    if ref_angle >= 180:
        ref_angle -= 180
    if val_angle >= 180:
        val_angle -= 180

    def _font_block(indent):
        out = [f"{indent}(font\n"]
        if text_face:
            out.append(f'{indent}\t(face "{_esc_kicad_str(text_face)}")\n')
        out.append(f"{indent}\t(size {text_size_mm:.4f} {text_size_mm:.4f})\n")
        if text_bold:
            out.append(f"{indent}\t(bold yes)\n")
        if text_italic:
            out.append(f"{indent}\t(italic yes)\n")
        out.append(f"{indent})\n")
        return "".join(out)

    mirror_line = "\t\t(mirror y)\n" if mirror_x else ""
    parts = [
        f"\t(symbol\n"
        f"\t\t(lib_id \"{lib_id}\")\n"
        f"\t\t(at {x:.2f} {y:.2f} {angle})\n"
        f"{mirror_line}"
        f"\t\t(unit {unit})\n"
        f"\t\t(exclude_from_sim no)\n"
        f"\t\t(in_bom {'no' if dnp else 'yes'})\n"
        f"\t\t(on_board yes)\n"
        f"\t\t(dnp {'yes' if dnp else 'no'})\n"
        f"\t\t(uuid \"{uid}\")\n"
        f"\t\t(property \"Reference\" \"{ref_esc}\"\n"
        f"\t\t\t(at {ref_x:.2f} {ref_y:.2f} {ref_angle})\n"
        f"\t\t\t(effects\n"
        + _font_block("\t\t\t\t")
        + f"\t\t\t)\n"
        f"\t\t)\n"
        f"\t\t(property \"Value\" \"{val_esc}\"\n"
        f"\t\t\t(at {val_x:.2f} {val_y:.2f} {val_angle})\n"
        f"\t\t\t(effects\n"
        + _font_block("\t\t\t\t")
        + f"\t\t\t)\n"
        f"\t\t)\n"
    ]

    if pin_numbers is None:
        pin_numbers = [1, 2]
    for pn in pin_numbers:
        pn_esc = _pin_label_for_kicad(pn)
        parts.append(
            f"\t\t(pin \"{pn_esc}\"\n"
            f"\t\t\t(uuid \"{new_uuid()}\")\n"
            f"\t\t)\n"
        )

    parts.append(
        f"\t\t(instances\n"
        f"\t\t\t(project \"\"\n"
        f"\t\t\t\t(path \"/\"\n"
        f"\t\t\t\t\t(reference \"{ref_esc}\")\n"
        f"\t\t\t\t\t(unit {unit})\n"
        f"\t\t\t\t)\n"
        f"\t\t\t)\n"
        f"\t\t)\n"
        f"\t)\n"
    )
    return "".join(parts)


def sch_footer():
    return "\t(embedded_fonts no)\n)\n"


# ---------------------------------------------------------------------------
# Net label placement
# ---------------------------------------------------------------------------

def is_bus_net(name):
    """Return True if the net name uses bus vector notation, e.g. DDR0_CAA[5..0]."""
    return bool(re.search(r'\[\d+\.\.\d+\]', name))


def is_power_net(name):
    if len(name) < 3:
        return False
    upper = name.upper()
    for prefix in ('VDD', 'GND', 'AGND', 'PGND', 'AVDD', 'DVDD',
                    'ADAVDD', 'ADAVSS', 'VIO', 'VCC', 'VBUS', 'VSS',
                    '+', '-'):
        if upper.startswith(prefix):
            return True
    if upper.endswith(('_VDD', '_VCC', '_VSS', '_GND', '_VBUS')):
        return True
    if re.search(r'_VBUS_(IN|OUT)\w*$', upper):
        return True
    if re.search(r'\d[\d.]*V\d*$', name):
        return True
    return False


def _is_power_net_for_page(name, power_net_names=None):
    """Return True when `name` is known to be a power net on this page.

    Prefer object-derived power nets. If no object-derived set was provided,
    fall back to the historical name heuristic for compatibility with callers
    that have not resolved OrCAD power-port records.
    """
    if not name:
        return False
    if power_net_names is None:
        return is_power_net(name)
    return name in power_net_names


def point_touches_wire(point, wires):
    """Return True if a page-space point lies on any parsed wire segment."""
    px, py = point
    for w in wires:
        x1, y1 = w['x1'], w['y1']
        x2, y2 = w['x2'], w['y2']
        if x1 == x2 == px and min(y1, y2) <= py <= max(y1, y2):
            return True
        if y1 == y2 == py and min(x1, x2) <= px <= max(x1, x2):
            return True
    return False


def compute_wire_endpoints(wires):
    """Find endpoints of wire segments — points that appear an odd number of times."""
    point_count = defaultdict(int)
    for w in wires:
        p1 = (w['x1'], w['y1'])
        p2 = (w['x2'], w['y2'])
        point_count[p1] += 1
        point_count[p2] += 1
    return {p for p, c in point_count.items() if c == 1}


def compute_junctions(wires):
    """Find junction points — where 3+ wire segments meet."""
    point_count = defaultdict(int)
    for w in wires:
        p1 = (w['x1'], w['y1'])
        p2 = (w['x2'], w['y2'])
        point_count[p1] += 1
        point_count[p2] += 1
    return {p for p, c in point_count.items() if c >= 3}


def _label_angle_from_wire(endpoint, wires):
    """Determine label angle so the label extends away from the wire.

    KiCad label angle = direction the wire connects FROM:
      0 = wire connects on the right  → label body extends left
      180 = wire connects on the left  → label body extends right
      90 = wire connects below         → label body extends up
      270 = wire connects above        → label body extends down

    We compute the vector from the label endpoint toward the wire's
    other end, then pick the angle matching that direction so the
    connection faces the wire and the label body goes the other way.
    """
    ex, ey = endpoint
    for w in wires:
        p1 = (w['x1'], w['y1'])
        p2 = (w['x2'], w['y2'])
        if p1 == (ex, ey):
            dx, dy = ex - w['x2'], ey - w['y2']
        elif p2 == (ex, ey):
            dx, dy = ex - w['x1'], ey - w['y1']
        else:
            continue
        if abs(dx) >= abs(dy):
            return 0 if dx > 0 else 180
        else:
            return 270 if dy > 0 else 90
    return 0


def _alias_label_angle(ax, ay, wires):
    """Determine label angle for a net alias placed ON a wire.

    Finds the wire passing through (ax, ay) and returns the KiCad label
    angle that makes the text extend toward the far end of the wire
    (away from the nearest component pin).
    """
    for w in wires:
        x1, y1, x2, y2 = w['x1'], w['y1'], w['x2'], w['y2']
        on_h = (y1 == y2 == ay and min(x1, x2) <= ax <= max(x1, x2))
        on_v = (x1 == x2 == ax and min(y1, y2) <= ay <= max(y1, y2))
        if not (on_h or on_v):
            continue
        dx = x2 - x1
        dy = y2 - y1
        # Point toward the farther endpoint of the wire.
        d1 = abs(ax - x1) + abs(ay - y1)
        d2 = abs(ax - x2) + abs(ay - y2)
        if d1 > d2:
            dx, dy = x1 - ax, y1 - ay
        else:
            dx, dy = x2 - ax, y2 - ay
        if abs(dx) >= abs(dy):
            return 0 if dx > 0 else 180
        else:
            return 270 if dy > 0 else 90
    return 0


def place_net_labels(wires, net_table, endpoints):
    """Determine where to place net labels.

    Places labels at wire endpoints that are "free" (not connected to other wires).
    For each net, picks the endpoint closest to the edge of the page.
    """
    net_endpoints = defaultdict(list)
    for w in wires:
        if not w['net']:
            continue
        p1 = (w['x1'], w['y1'])
        p2 = (w['x2'], w['y2'])
        if p1 in endpoints:
            net_endpoints[w['net']].append(p1)
        if p2 in endpoints:
            net_endpoints[w['net']].append(p2)

    labels = []
    for net_name, points in net_endpoints.items():
        seen = set()
        for p in points:
            if p in seen:
                continue
            seen.add(p)
            labels.append({
                'name': net_name,
                'x': p[0],
                'y': p[1],
                'angle': _label_angle_from_wire(p, wires),
            })

    return labels


# ---------------------------------------------------------------------------
# Page generation
# ---------------------------------------------------------------------------

def generate_page_sch(page_name, paper, wires, components, power_syms,
                      net_table, global_nets, texts=None, title_block=None,
                      sheet_number=None, total_sheets=None,
                      page_rects=None, page_lines=None, page_ellipses=None,
                      page_polygons=None,
                      library_styles=None, debug_bbox=False,
                      debug_ref_val=False, debug_symbol=False,
                      net_aliases=None, power_net_names=None,
                      power_symbol_styles=None):
    """Generate a complete KiCad schematic page from parsed DSN data."""
    parts = []
    rv_size, rv_face, rv_bold, rv_italic = _default_text_style(library_styles)
    tb = title_block or {}
    # Map OrCAD title-block fields into KiCad's slots:
    #   OrCAD Title       → KiCad (title ...)
    #   OrCAD DocNumber   → KiCad (comment 1 ...)   (KiCad has no Doc# field)
    #   OrCAD Rev         → KiCad (rev ...)
    #   "Sheet N of M"    → KiCad (comment 2 ...)
    sheet_note = ""
    if sheet_number is not None and total_sheets is not None:
        sheet_note = f"Sheet {sheet_number} of {total_sheets}"
    parts.append(sch_header(
        paper,
        title=tb.get('title', '') or page_name,
        rev=tb.get('rev', ''),
        comment1=tb.get('doc_number', ''),
        comment2=sheet_note,
    ))

    symbols_needed = {}
    for comp in components:
        lib_id, _, lib_func = get_lib_symbol(comp['cell'])
        if lib_id not in symbols_needed:
            symbols_needed[lib_id] = lib_func()

    # Collect power-symbol names that will actually be emitted on this
    # page so their lib_symbol definitions can be embedded inline.
    # Glyphs are emitted at every wire endpoint that sits on a power
    # net, so the set of distinct power-net names appearing in wires
    # is what determines which `power:<NAME>` definitions are needed.
    power_names_used = set()
    for w in wires:
        if _is_power_net_for_page(w.get('net'), power_net_names):
            power_names_used.add(w['net'])

    for comp in components:
        for pin_net in comp.get('pin_nets', {}).values():
            net_name = pin_net.get('net')
            if _is_power_net_for_page(net_name, power_net_names):
                power_names_used.add(net_name)

    for pname in sorted(power_names_used):
        lid = f'power:{pname}'
        if lid not in symbols_needed:
            symbols_needed[lid] = lib_symbol_for_power_name(
                pname, power_symbol_styles)

    parts.append(sch_lib_symbols(symbols_needed))

    # Build map of pin-extension adjustments in DSN page units.
    # For each extended pin that has a wire, maps the old endpoint
    # position to the new (extended) position.
    pin_adjust = {}
    for comp in components:
        cell = comp['cell']
        deltas = _pin_extension_deltas.get(cell)
        if not deltas:
            continue
        cx_cy = _cell_centers.get(cell)
        pin_list = _cell_pin_lists.get(cell)
        if not cx_cy or not pin_list:
            continue
        cx, cy = cx_cy
        pin_defs = _cell_pin_defs.get(cell, [])
        for i, (raw_hx, raw_hy) in enumerate(pin_list):
            pn = str(pin_defs[i][0]) if i < len(pin_defs) else str(i + 1)
            if pn not in deltas:
                continue
            dx_mm, dy_mm = deltas[pn]
            dx_cache = dx_mm / UNIT_TO_MM
            dy_cache = -dy_mm / UNIT_TO_MM
            rdx, rdy = _forward_rotate(dx_cache, dy_cache, comp['orient'])
            old_dx, old_dy = raw_hx - cx, raw_hy - cy
            old_rdx, old_rdy = _forward_rotate(old_dx, old_dy, comp['orient'])
            ox = round(comp['x'] + old_rdx)
            oy = round(comp['y'] + old_rdy)
            nx = round(comp['x'] + old_rdx + rdx)
            ny = round(comp['y'] + old_rdy + rdy)
            if (ox, oy) != (nx, ny):
                pin_adjust[(ox, oy)] = (nx, ny)

    # Wires and bus segments.
    # At output time, extend collinear wire endpoints to reach extended
    # pins.  The DSN-unit wire data stays untouched so labels, junctions,
    # and power-symbol logic see the original positions.
    regular_wires = []
    bus_points = defaultdict(set)
    for w in wires:
        x1 = dsn_to_mm(w['x1'])
        y1 = dsn_to_mm(w['y1'])
        x2 = dsn_to_mm(w['x2'])
        y2 = dsn_to_mm(w['y2'])
        if w.get('bus'):
            parts.append(sch_bus(x1, y1, x2, y2))
            bus_points[w['net']].add((w['x1'], w['y1']))
            bus_points[w['net']].add((w['x2'], w['y2']))
        else:
            new_pos = pin_adjust.get((w['x1'], w['y1']))
            if new_pos:
                sdx = new_pos[0] - w['x1']
                sdy = new_pos[1] - w['y1']
                wdx = w['x2'] - w['x1']
                wdy = w['y2'] - w['y1']
                if sdx * wdy - sdy * wdx == 0:
                    x1 = dsn_to_mm(new_pos[0])
                    y1 = dsn_to_mm(new_pos[1])
            new_pos = pin_adjust.get((w['x2'], w['y2']))
            if new_pos:
                sdx = new_pos[0] - w['x2']
                sdy = new_pos[1] - w['y2']
                wdx = w['x1'] - w['x2']
                wdy = w['y1'] - w['y2']
                if sdx * wdy - sdy * wdx == 0:
                    x2 = dsn_to_mm(new_pos[0])
                    y2 = dsn_to_mm(new_pos[1])
            parts.append(sch_wire(x1, y1, x2, y2))
            regular_wires.append(w)

    # Synthesize bus entries: for each individual wire whose net is a
    # member of a bus, create a diagonal bus_entry connecting the wire
    # endpoint to the nearest bus point.
    bus_member_prefixes = {}
    for bus_name in bus_points:
        m = re.match(r'^(.+)\[\d+\.\.\d+\]$', bus_name)
        if m:
            bus_member_prefixes[m.group(1)] = bus_name
    bus_entry_landings = set()
    bus_member_nets = set()
    for w in regular_wires:
        if not w['net']:
            continue
        matched_bus = None
        for prefix, bus_name in bus_member_prefixes.items():
            if w['net'].startswith(prefix) and w['net'][len(prefix):].isdigit():
                matched_bus = bus_name
                break
        if not matched_bus:
            continue
        bus_member_nets.add(w['net'])
        bp = bus_points[matched_bus]
        for wx, wy in [(w['x1'], w['y1']), (w['x2'], w['y2'])]:
            candidates = []
            for bx, by in bp:
                dx = bx - wx
                dy = by - wy
                if abs(dx) == 10 and abs(dy) == 10:
                    candidates.append((dx, dy))
            if not candidates:
                continue
            candidates.sort(key=lambda d: d[1])
            dx, dy = candidates[0]
            parts.append(sch_bus_entry(
                dsn_to_mm(wx), dsn_to_mm(wy),
                dsn_to_mm(dx), dsn_to_mm(dy)))
            bus_entry_landings.add((wx + dx, wy + dy))
            break

    # Junctions (only for regular wires, not bus segments)
    junctions = compute_junctions(regular_wires)
    for p in junctions:
        parts.append(sch_junction(dsn_to_mm(p[0]), dsn_to_mm(p[1])))

    # Components
    for comp in components:
        lib_id, _, _ = get_lib_symbol(comp['cell'])
        x = dsn_to_mm(comp['x'])
        y = dsn_to_mm(comp['y'])
        angle = orient_to_angle(comp['orient'], comp['cell'])
        ref = comp['ref'] if comp['ref'] else f"?{comp['cell']}"
        cell_pins = _cell_pin_defs.get(comp['cell'])
        if cell_pins:
            pin_nums = sorted(set(p[0] for p in cell_pins),
                              key=_pin_sort_key)
        elif comp['pins']:
            pin_nums = sorted(set(p[0] for p in comp['pins']))
        else:
            pin_nums = [1, 2]
        comp_value = comp['cell']
        if comp.get('value_idx') is not None:
            resolved = lookup_component_value(comp['value_idx'])
            if resolved:
                comp_value = resolved
        comp_dnp = comp_value.endswith(' *DNP')
        if comp_dnp:
            comp_value = comp_value[:-5]
        comp_unit = 1
        if comp['cell'] in _multi_unit_cell_map:
            _, comp_unit = _multi_unit_cell_map[comp['cell']]
        mirror_x = bool(comp['orient'] & 0x04)
        ref_center = _text_center_mm(
            comp.get('text_origin'), comp.get('ref_off'), ref,
            comp.get('ref_text_angle'), rv_size, rv_face, rv_bold, rv_italic)
        val_center = _text_center_mm(
            comp.get('text_origin'), comp.get('val_off'), comp_value,
            comp.get('val_text_angle'), rv_size, rv_face, rv_bold, rv_italic)
        parts.append(sch_component(ref, lib_id, x, y, angle, comp_value,
                                   pin_numbers=pin_nums,
                                   ref_center=ref_center,
                                   val_center=val_center,
                                   ref_text_angle=comp.get('ref_text_angle'),
                                   val_text_angle=comp.get('val_text_angle'),
                                   unit=comp_unit,
                                   mirror_x=mirror_x,
                                   dnp=comp_dnp,
                                   text_size_mm=rv_size, text_face=rv_face,
                                   text_bold=rv_bold, text_italic=rv_italic))

    # Power-symbol glyphs are emitted at wire endpoints that lie on a
    # power net AND are not stuck on a component pin (otherwise every
    # CN1 GND pin would carry a GND triangle stacked over the pin
    # number — OrCAD only renders the glyph at the dangling end of the
    # wire bus, not at each pin along the way).
    pin_positions = collect_pin_positions(components)
    power_positions = set()
    power_angles = _power_symbol_angles_by_hotpoint(power_syms)

    # Some OrCAD power ports connect directly to component pins without an
    # intervening wire segment. Those net ids live on the pin records.
    for comp in components:
        for (_pin_num, px, py), pin_net in comp.get('pin_nets', {}).items():
            if (px, py) in power_positions:
                continue
            if point_touches_wire((px, py), regular_wires):
                continue
            net_name = pin_net.get('net')
            if not _is_power_net_for_page(net_name, power_net_names):
                continue
            angle = power_angles.get((px, py, net_name), 0)
            parts.append(sch_power_symbol(
                net_name, dsn_to_mm(px), dsn_to_mm(py),
                _is_gnd_power_name(net_name), angle=angle,
                text_size_mm=rv_size, text_face=rv_face,
                text_bold=rv_bold, text_italic=rv_italic))
            power_positions.add((px, py))

    # Labels for regular (non-bus) wires
    endpoints = compute_wire_endpoints(regular_wires)
    labels = place_net_labels(regular_wires, net_table, endpoints)
    labeled_nets = set()
    for lbl in labels:
        if (lbl['x'], lbl['y']) in power_positions:
            continue
        if (lbl['x'], lbl['y']) in pin_positions:
            continue
        labeled_nets.add(lbl['name'])
        x = dsn_to_mm(lbl['x'])
        y = dsn_to_mm(lbl['y'])
        if _is_power_net_for_page(lbl['name'], power_net_names):
            is_gnd = _is_gnd_power_name(lbl['name'])
            angle = power_angles.get((lbl['x'], lbl['y'], lbl['name']), 0)
            parts.append(sch_power_symbol(lbl['name'], x, y, is_gnd,
                                          angle=angle,
                                          text_size_mm=rv_size,
                                          text_face=rv_face,
                                          text_bold=rv_bold,
                                          text_italic=rv_italic))
            power_positions.add((lbl['x'], lbl['y']))
        elif lbl['name'] in global_nets and lbl['name'] not in bus_member_nets:
            parts.append(sch_global_label(lbl['name'], x, y, angle=lbl['angle']))
        else:
            local_angle = (lbl['angle'] + 180) % 360
            parts.append(sch_label(lbl['name'], x, y, angle=local_angle))

    # Net-alias labels — explicit labels from OrCAD net-alias records.
    # These provide labels for nets where wire-endpoint labels were
    # filtered (e.g. pin-to-pin wires with no free endpoint).
    # Unlike wire-endpoint labels, alias labels are placed ON the wire
    # and their text should extend along the wire toward the far end.
    for alias in net_aliases or []:
        if alias['name'] in labeled_nets:
            continue
        if (alias['x'], alias['y']) in power_positions:
            continue
        labeled_nets.add(alias['name'])
        x = dsn_to_mm(alias['x'])
        y = dsn_to_mm(alias['y'])
        angle = _alias_label_angle(alias['x'], alias['y'], regular_wires)
        if _is_power_net_for_page(alias['name'], power_net_names):
            is_gnd = _is_gnd_power_name(alias['name'])
            angle = power_angles.get((alias['x'], alias['y'], alias['name']), 0)
            parts.append(sch_power_symbol(alias['name'], x, y, is_gnd,
                                          angle=angle,
                                          text_size_mm=rv_size,
                                          text_face=rv_face,
                                          text_bold=rv_bold,
                                          text_italic=rv_italic))
            power_positions.add((alias['x'], alias['y']))
        elif is_bus_net(alias['name']):
            parts.append(sch_label(alias['name'], x, y, angle=angle))
        elif alias['name'] in global_nets and alias['name'] not in bus_member_nets:
            parts.append(sch_global_label(alias['name'], x, y, angle=angle))
        else:
            parts.append(sch_label(alias['name'], x, y, angle=angle))

    # Bus labels — placed at free endpoints of bus wires.
    bus_wires = [w for w in wires if w.get('bus')]
    bus_endpoints = compute_wire_endpoints(bus_wires)
    bus_labels = place_net_labels(bus_wires, net_table, bus_endpoints)
    for lbl in bus_labels:
        if (lbl['x'], lbl['y']) in bus_entry_landings:
            continue
        x = dsn_to_mm(lbl['x'])
        y = dsn_to_mm(lbl['y'])
        parts.append(sch_global_label(lbl['name'], x, y, angle=lbl['angle']))

    # Decorative rectangles (INDEX table outline, CAUTION block, DNP
    # hatch areas). Stroke width mirrors the OrCAD PDF convention
    # (0.36 pt black vs 1.08 pt red). Dashed stroke and hatch fill
    # are preserved from the binary record fields.
    for r in page_rects or []:
        r_rgba = r.get('rgba', '0 0 0 1')
        r_fill = r.get('fill', 'none')
        fill_rgba = r_rgba if r_fill in ('hatch', 'color') else None
        stroke_rgba = '0 0 0 1' if r_fill == 'color' else r_rgba
        parts.append(sch_rectangle(
            dsn_to_mm(r['x1']), dsn_to_mm(r['y1']),
            dsn_to_mm(r['x2']), dsn_to_mm(r['y2']),
            rgba=stroke_rgba, width=r.get('width', 0.15), fill=r_fill,
            stroke_type=r.get('stroke_type', 'default'),
            fill_color=fill_rgba,
        ))

    # Decorative lines (INDEX table dividers, etc.).
    for ln in page_lines or []:
        parts.append(sch_polyline(
            [(dsn_to_mm(ln['x1']), dsn_to_mm(ln['y1'])),
             (dsn_to_mm(ln['x2']), dsn_to_mm(ln['y2']))],
            rgba=ln.get('rgba', '0 0 0 1'), width=ln.get('width', 0.15),
        ))

    for el in page_ellipses or []:
        parts.append(sch_ellipse(
            dsn_to_mm(el['x1']), dsn_to_mm(el['y1']),
            dsn_to_mm(el['x2']), dsn_to_mm(el['y2']),
            rgba=el.get('rgba', '0 0 0 1'), width=el.get('width', 0.15),
        ))

    # Decorative filled polygons (LED indicator triangles on block
    # diagrams). Like the colored rects, a solid-filled polygon gets a
    # black stroke; the paired outline-only record keeps its own color.
    for poly in page_polygons or []:
        p_rgba = poly.get('rgba', '0 0 0 1')
        p_fill = poly.get('fill', 'none')
        fill_rgba = p_rgba if p_fill == 'color' else None
        stroke_rgba = '0 0 0 1' if p_fill == 'color' else p_rgba
        parts.append(sch_filled_polygon(
            [(dsn_to_mm(x), dsn_to_mm(y)) for x, y in poly['points']],
            rgba=stroke_rgba, fill=p_fill, fill_color=fill_rgba,
        ))

    styles = library_styles or []
    for t in texts or []:
        x = dsn_to_mm(t['x'])
        y0 = dsn_to_mm(t['y'])
        style_id = t.get('style_id', 0)
        bold = italic = False
        face = None
        escapement = 0
        if styles and 1 <= style_id <= len(styles):
            s = styles[style_id - 1]
            bold = (s.get('weight') == 700)
            italic = bool(s.get('italic'))
            face = s.get('face') or None
            escapement = s.get('escapement', 0)
        rotated = (escapement / 10) in (90, 270)
        # Size the text so that the longest line's rendered width matches
        # the bbox width, and the per-line height matches bbox_h / n_lines.
        # Take the smaller of the two so the text never overflows the bbox.
        # For rotated text (90°/270°), the bbox's physical width/height are
        # swapped relative to the text's reading direction.
        #
        # KiCad's outline-font renderer (common/font/outline_font.cpp) applies
        # `m_outlineFontSizeCompensation = 1.4` when scaling glyphs — so a
        # `(size 10 10)` value in the .kicad_sch is rendered at 14 mm em-height.
        # Divide our target size by this factor so the rendered text comes out
        # at the size we actually want.
        KICAD_FONT_SIZE_COMPENSATION = 1.4
        size = 1.27
        body = t['text'].replace('\r\n', '\n').replace('\r', '\n')
        lines = [ln for ln in body.split('\n') if ln.strip()]
        n_lines = max(1, len(lines))
        bbox = t.get('bbox')
        if bbox:
            phys_w = abs(bbox[2] - bbox[0]) * UNIT_TO_MM
            phys_h = abs(bbox[3] - bbox[1]) * UNIT_TO_MM
            bbox_w_mm = phys_h if rotated else phys_w
            bbox_h_mm = phys_w if rotated else phys_h
            per_line_mm = bbox_h_mm / n_lines
            widest = max(lines, key=len) if lines else ''
            width_at_1mm = measure_text_width(
                widest, 1.0, face_name=face or 'Arial',
                bold=bold, italic=italic)
            if width_at_1mm > 0:
                width_limited_size = bbox_w_mm / width_at_1mm
            else:
                width_limited_size = per_line_mm
            target = min(per_line_mm, width_limited_size)
            size = max(0.5, min(target / KICAD_FONT_SIZE_COMPENSATION, 32.0))
        line_h = (abs(bbox[3] - bbox[1]) * UNIT_TO_MM / n_lines) if bbox and not rotated else (
                  (abs(bbox[2] - bbox[0]) * UNIT_TO_MM / n_lines) if bbox and rotated else (size * 1.2))
        descender_mm = 0.30 * size
        for j, line in enumerate(lines):
            if rotated:
                lx = x + (j + 1) * line_h + descender_mm
                bbox_span = abs(bbox[3] - bbox[1]) * UNIT_TO_MM if bbox else 0
                ly = y0 + bbox_span
            else:
                lx = x
                ly = y0 + (j + 1) * line_h + descender_mm
            parts.append(sch_text(
                line, lx, ly,
                size=size, angle=90.0 if rotated else 0.0,
                bold=bold, italic=italic, face=face,
                justify="left bottom", rgba=t.get('rgba'),
            ))

    # Debug overlay: draw bounding boxes around each parsed page-stream
    # record so we can see what the parser thinks each element occupies.
    # Text records get a thin magenta rectangle around their (p1..p4)
    # bounding box; page rects/lines get a thin green rectangle around
    # their own extent.
    if debug_bbox:
        for t in texts or []:
            bbox = t.get('bbox')
            if not bbox:
                continue
            bx1 = dsn_to_mm(bbox[0])
            by1 = dsn_to_mm(bbox[1])
            bx2 = dsn_to_mm(bbox[2])
            by2 = dsn_to_mm(bbox[3])
            parts.append(sch_rectangle(bx1, by1, bx2, by2,
                                       color='magenta', width=0.05))
        for r in page_rects or []:
            parts.append(sch_rectangle(
                dsn_to_mm(r['x1']), dsn_to_mm(r['y1']),
                dsn_to_mm(r['x2']), dsn_to_mm(r['y2']),
                color='green', width=0.05,
            ))
        for comp in components:
            rp = comp.get('ref_pos')
            vp = comp.get('val_pos')
            sz = 1.0
            if rp:
                rx, ry = dsn_to_mm(rp[0]), dsn_to_mm(rp[1])
                parts.append(sch_rectangle(rx, ry, rx + sz, ry + sz,
                                           color='cyan', width=0.10))
            if vp:
                vx, vy = dsn_to_mm(vp[0]), dsn_to_mm(vp[1])
                parts.append(sch_rectangle(vx, vy, vx + sz, vy + sz,
                                           color='yellow', width=0.10))

    # Debug overlay for the ref/value text anchoring investigation:
    #   red circle+dot  = instance placement point (loc)
    #   lightgrey circle+dot = raw display-prop anchor before applying the
    #       component rotation/mirror transform
    # The differing radii stay readable when the two overlap.
    if debug_ref_val:
        red = _COLOR_RGBA['red']
        lightgrey = _COLOR_RGBA['lightgrey']
        for comp in components:
            torg = comp.get('text_origin')   # = loc (DSN units)
            if torg is None:
                continue
            orient = comp['orient']
            lx, ly = dsn_to_mm(torg[0]), dsn_to_mm(torg[1])
            parts.append(_debug_marker(lx, ly, red, radius=2.2, dot=0.4))
            # Mirror flag next to the loc circle. OrCAD has only a horizontal
            # mirror bit (0x04 -> KiCad (mirror y)); there is no separate vertical
            # flip flag (a vertical flip is this bit + 180 rotation). loc itself is
            # mirror-invariant, so the flag explains why a mirrored part (e.g. CN1)
            # is misplaced even though its anchor circle sits in the right spot.
            if orient & 0x04:
                parts.append(sch_text('H', lx - 2.6, ly + 0.7, size=1.6,
                                      justify='right bottom', rgba=red))
            for off in (comp.get('ref_off'), comp.get('val_off')):
                if off is None:
                    continue
                ux, uy = dsn_to_mm(torg[0] + off[0]), dsn_to_mm(torg[1] + off[1])
                parts.append(_debug_marker(ux, uy, lightgrey,
                                           radius=1.75, dot=0.34))

    # Debug overlay: the OrCAD symbol bounding box (body extent) as a lightblue
    # rectangle. The bbox is in cache units (pin frame); transform its corners by
    # the component orient and add the pin-matched origin to map it to the page.
    if debug_symbol:
        for comp in components:
            box = _cell_bboxes.get(comp['cell'])
            origin = comp.get('origin')
            if not box or origin is None:
                continue
            x1, y1, x2, y2 = box
            ctr = comp.get('center', (0, 0))
            xs, ys = [], []
            for cx, cy in ((x1, y1), (x2, y1), (x2, y2), (x1, y2)):
                rx, ry = _forward_rotate(cx, cy, comp['orient'], ctr)
                xs.append(origin[0] + rx)
                ys.append(origin[1] + ry)
            parts.append(sch_rectangle(
                dsn_to_mm(min(xs)), dsn_to_mm(min(ys)),
                dsn_to_mm(max(xs)), dsn_to_mm(max(ys)),
                color='lightblue', width=0.1))

    parts.append(sch_footer())
    return "".join(parts)


# ---------------------------------------------------------------------------
# Root schematic and project
# ---------------------------------------------------------------------------

def generate_root_sch(page_filenames, page_names, project_name=""):
    parts = [sch_header("A3", f"{project_name} (DSN import)")]
    parts.append("\t(lib_symbols)\n")

    rows = 4
    sheet_w, sheet_h = 60, 12
    margin_x, margin_y = 15, 25
    gap_x, gap_y = 8, 5
    root_uuid = new_uuid()

    for i, (fname, name) in enumerate(zip(page_filenames, page_names)):
        # KiCad's hierarchy navigator sorts sheet symbols by position. Place
        # imported pages top-to-bottom, then left-to-right, so that sort order
        # follows the DSN page order.
        row = i % rows
        col = i // rows
        x = margin_x + col * (sheet_w + gap_x)
        y = margin_y + row * (sheet_h + gap_y)

        parts.append(
            f"\t(sheet\n"
            f"\t\t(at {x} {y})\n"
            f"\t\t(size {sheet_w} {sheet_h})\n"
            f"\t\t(exclude_from_sim no)\n"
            f"\t\t(in_bom yes)\n"
            f"\t\t(on_board yes)\n"
            f"\t\t(dnp no)\n"
            f"\t\t(fields_autoplaced yes)\n"
            f"\t\t(stroke\n"
            f"\t\t\t(width 0.1524)\n"
            f"\t\t\t(type solid)\n"
            f"\t\t)\n"
            f"\t\t(fill\n"
            f"\t\t\t(color 0 0 0 0)\n"
            f"\t\t)\n"
            f"\t\t(uuid \"{new_uuid()}\")\n"
            f"\t\t(property \"Sheetname\" \"{name}\"\n"
            f"\t\t\t(at {x} {y - 0.7} 0)\n"
            f"\t\t\t(show_name no)\n"
            f"\t\t\t(do_not_autoplace no)\n"
            f"\t\t\t(effects\n"
            f"\t\t\t\t(font\n"
            f"\t\t\t\t\t(size 1.27 1.27)\n"
            f"\t\t\t\t)\n"
            f"\t\t\t\t(justify left top)\n"
            f"\t\t\t)\n"
            f"\t\t)\n"
            f"\t\t(property \"Sheetfile\" \"{fname}\"\n"
            f"\t\t\t(at {x} {y + sheet_h + 0.7} 0)\n"
            f"\t\t\t(show_name no)\n"
            f"\t\t\t(do_not_autoplace no)\n"
            f"\t\t\t(effects\n"
            f"\t\t\t\t(font\n"
            f"\t\t\t\t\t(size 1.27 1.27)\n"
            f"\t\t\t\t)\n"
            f"\t\t\t\t(justify left top)\n"
            f"\t\t\t)\n"
            f"\t\t)\n"
            f"\t)\n"
        )

    parts.append(
        f"\t(sheet_instances\n"
        f"\t\t(path \"/\"\n"
        f"\t\t\t(page \"1\")\n"
        f"\t\t)\n"
        f"\t)\n"
    )
    parts.append(sch_footer())
    return "".join(parts)


def generate_project(name):
    proj = {
        "meta": {"filename": f"{name}.kicad_pro", "version": 2},
        "schematic": {"drawing": {}, "meta": {"version": 1}},
    }
    return json.dumps(proj, indent=2) + "\n"


def generate_symbol_library(project_name, power_names=None, used_cells=None,
                            power_symbol_styles=None):
    """Generate a project-local .kicad_sym file with all cell definitions.

    `power_names` is an iterable of power-symbol names used anywhere in
    the project; their `power:*` lib_symbol definitions are added so the
    project library is self-contained and resolves the same references
    that pages embed inline.
    `used_cells` limits output to cells actually placed on pages.
    """
    parts = [
        f"(kicad_symbol_lib\n"
        f"\t(version 20251024)\n"
        f"\t(generator \"dsn2kicad\")\n"
        f"\t(generator_version \"1.0\")\n"
    ]
    for cell_name in ('R', 'C'):
        if cell_name in CELL_TO_KICAD:
            _, _, lib_func = CELL_TO_KICAD[cell_name]
            parts.append(lib_func())
    emitted_multi = set()
    for cell_name in sorted(_cell_pin_defs):
        if used_cells is not None and cell_name not in used_cells:
            continue
        if cell_name in _multi_unit_cell_map:
            base_name, _ = _multi_unit_cell_map[cell_name]
            if base_name in emitted_multi:
                continue
            emitted_multi.add(base_name)
        _, _, lib_func = get_lib_symbol(cell_name)
        parts.append(lib_func())
    if power_names:
        emitted_power = set()
        for pname in sorted(power_names):
            lid = f'power:{pname}'
            if lid not in emitted_power:
                parts.append(lib_symbol_for_power_name(
                    pname, power_symbol_styles))
                emitted_power.add(lid)
    parts.append(")\n")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Cache stream parsing (complete cell pin definitions)
# ---------------------------------------------------------------------------

def _pin_sort_key(pin_name):
    """Sort key for pin names: numeric pins by value, others alphabetically."""
    try:
        return (0, int(pin_name), '')
    except ValueError:
        return (1, 0, pin_name)


def _normalize_cache_polygon(vertices):
    """Return (filled polygon, extra lines) for an OrCAD 0x2c2c path.

    OrCAD commonly duplicates the first point and may append it again as
    a close marker. Some records then continue with a stroked subpath
    (e.g. DIODE's cathode bar). Do not globally de-duplicate: repeated
    points can be path structure.
    """
    poly = []
    for vertex in vertices:
        if not poly or vertex != poly[-1]:
            poly.append(vertex)

    was_closed = len(poly) >= 2 and poly[-1] == poly[0]
    if was_closed:
        poly.pop()

    if len(poly) >= 4 and poly[0] in poly[1:]:
        close_idx = poly.index(poly[0], 1)
        filled = poly[:close_idx]
        trailing = poly[close_idx + 1:]
        extra_lines = []
        last = poly[0]
        for point in trailing:
            extra_lines.append((last[0], last[1], point[0], point[1]))
            last = point
        return filled, extra_lines

    return poly, []


def _emit_filled_polygon(parts, poly, indent='\t\t\t\t'):
    pts_str = " ".join(f"(xy {x:.2f} {y:.2f})" for x, y in poly)
    parts.append(
        f'{indent}(polyline\n'
        f'{indent}\t(pts\n'
        f'{indent}\t\t{pts_str}\n'
        f'{indent}\t)\n'
        f'{indent}\t(stroke\n'
        f'{indent}\t\t(width 0)\n'
        f'{indent}\t\t(type default)\n'
        f'{indent}\t)\n'
        f'{indent}\t(fill\n'
        f'{indent}\t\t(type outline)\n'
        f'{indent}\t)\n'
        f'{indent})\n'
    )


def _emit_symbol_line(parts, x1, y1, x2, y2):
    parts.append(f'\t\t\t\t(polyline\n')
    parts.append(f'\t\t\t\t\t(pts\n')
    parts.append(f'\t\t\t\t\t\t(xy {x1:.2f} {y1:.2f})\n')
    parts.append(f'\t\t\t\t\t\t(xy {x2:.2f} {y2:.2f})\n')
    parts.append(f'\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(stroke\n')
    parts.append('\t\t\t\t\t\t(width 0.254)\n')
    parts.append('\t\t\t\t\t\t(type default)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(fill\n')
    parts.append('\t\t\t\t\t\t(type none)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t)\n')


def _emit_symbol_rectangle(parts, x1, y1, x2, y2):
    parts.append(f'\t\t\t\t(rectangle\n')
    parts.append(f'\t\t\t\t\t(start {x1:.2f} {y1:.2f})\n')
    parts.append(f'\t\t\t\t\t(end {x2:.2f} {y2:.2f})\n')
    parts.append('\t\t\t\t\t(stroke\n')
    parts.append('\t\t\t\t\t\t(width 0.254)\n')
    parts.append('\t\t\t\t\t\t(type default)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t\t(fill\n')
    parts.append('\t\t\t\t\t\t(type background)\n')
    parts.append('\t\t\t\t\t)\n')
    parts.append('\t\t\t\t)\n')


def _parse_cache_graphics(data, aps, scan_end):
    """Parse graphic primitives (body rectangles, line segments, ellipses,
    arcs, polygons, text annotations) from a Cache cell.

    Scans from aps (after OLB path) until the first pin record or scan_end.
    Returns (body_rects, body_lines, body_ellipses, body_arcs,
             body_polygons, text_annotations) where:
      body_rects = [(x1, y1, x2, y2), ...]  in declaration order
      body_lines = [(x1, y1, x2, y2), ...]  line segments
      body_ellipses = [(x1, y1, x2, y2), ...]  bounding boxes
      body_arcs = [(bbox_x1, bbox_y1, bbox_x2, bbox_y2,
                    start_x, start_y, end_x, end_y), ...]
      body_polygons = [[(x1, y1), (x2, y2), ...], ...]  filled polygons
      body_polylines = [[(x1, y1), (x2, y2), ...], ...]  open paths
      text_annotations = [(bbox_x1, bbox_y1, bbox_x2, bbox_y2,
                            anchor_x, anchor_y, text), ...]

    Two distinct rectangle records are emitted for cells with composite
    bodies (e.g. SD-card socket CARD_SOCKET has an inner rectangle for
    the card slot and an outer rectangle for the housing):
      - `0x0030` record carries an inner rect at offset +16 (i32×4)
      - `0x282828` record (type_word `0x2828` + 0x28) carries an outer
        rect at offset +10 (i32×4)

    The `0x2929` record is a line segment with two endpoints at offset +10
    (i32×4).  Used by DIP-switch symbols and others whose body is drawn
    with individual lines rather than a rectangle record.

    The `0x2e2e` record is a text annotation, formerly misread as a
    line segment. See doc/ORCAD_DSN_FILES.md for the format.
    """
    body_rects = []
    body_lines = []
    body_ellipses = []
    body_arcs = []
    body_polygons = []
    body_polylines = []
    text_annotations = []
    pos = aps

    while pos < scan_end - 10:
        type_word = struct.unpack_from('<H', data, pos)[0]

        if type_word == 0x0030:
            tw = struct.unpack_from('<H', data, pos + 6)[0]
            if tw == 0x2828 and pos + 32 <= len(data):
                x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 16)
                if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                    body_rects.append((x1, y1, x2, y2))
            elif tw == 0x2b2b and pos + 32 <= len(data):
                x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 16)
                if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                    if not (x1 == x2 == 0 and y1 == y2 == 0):
                        body_ellipses.append((x1, y1, x2, y2))
            elif tw == 0x2929 and pos + 32 <= len(data):
                x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 16)
                if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                    body_lines.append((x1, y1, x2, y2))
            elif tw == 0x2a2a and pos + 48 <= len(data):
                vals = struct.unpack_from('<iiiiiiii', data, pos + 16)
                bx1, by1, bx2, by2, sx, sy, ex, ey = vals
                if all(abs(v) < 5000 for v in vals):
                    body_arcs.append((bx1, by1, bx2, by2, sx, sy, ex, ey))
            nm = data.find(RECORD_MARKER, pos + 32, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2828:
            # Outer/secondary body rectangle. Type bytes `28 28 28` then 7
            # bytes, then 4×i32 bbox at offset +10.
            if data[pos + 2] == 0x28 and pos + 26 <= len(data):
                x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 10)
                if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                    body_rects.append((x1, y1, x2, y2))
            nm = data.find(RECORD_MARKER, pos + 26, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2929 and pos + 26 <= len(data):
            x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 10)
            if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                if not (x1 == x2 == 0 and y1 == y2 == 0):
                    body_lines.append((x1, y1, x2, y2))
            nm = data.find(RECORD_MARKER, pos + 26, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2b2b and pos + 26 <= len(data):
            x1, y1, x2, y2 = struct.unpack_from('<iiii', data, pos + 10)
            if all(abs(v) < 5000 for v in (x1, y1, x2, y2)):
                if not (x1 == x2 == 0 and y1 == y2 == 0):
                    body_ellipses.append((x1, y1, x2, y2))
            nm = data.find(RECORD_MARKER, pos + 26, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2a2a and pos + 42 <= len(data):
            vals = struct.unpack_from('<iiiiiiii', data, pos + 10)
            bx1, by1, bx2, by2, sx, sy, ex, ey = vals
            if all(abs(v) < 5000 for v in vals):
                body_arcs.append((bx1, by1, bx2, by2, sx, sy, ex, ey))
            nm = data.find(RECORD_MARKER, pos + 42, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2c2c and pos + 28 <= len(data):
            nv = struct.unpack_from('<H', data, pos + 26)[0]
            rec_len = 28 + nv * 4
            if 3 <= nv <= 50 and pos + rec_len <= len(data):
                verts = []
                for vi in range(nv):
                    vx, vy = struct.unpack_from('<hh', data, pos + 28 + vi * 4)
                    # 0x2c2c polygon vertices are stored as (y, x), unlike
                    # line/rectangle records whose coordinates are (x, y).
                    verts.append((vy, vx))
                poly, extra_lines = _normalize_cache_polygon(verts)
                if len(poly) >= 3:
                    body_polygons.append(poly)
                body_lines.extend(extra_lines)
            nm = data.find(RECORD_MARKER, pos + 28, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2d2d and pos + 12 <= len(data):
            byte_length = struct.unpack_from('<I', data, pos + 2)[0]
            remaining = byte_length - 8
            if remaining >= 10 and (remaining - 10) % 4 == 0:
                nv = struct.unpack_from('<H', data, pos + 18)[0]
                pt_off = pos + 20
            elif remaining >= 2 and (remaining - 2) % 4 == 0:
                nv = struct.unpack_from('<H', data, pos + 10)[0]
                pt_off = pos + 12
            else:
                nv = 0
                pt_off = pos + 12
            if 2 <= nv <= 50 and pt_off + nv * 4 <= len(data):
                pts = []
                for vi in range(nv):
                    vy, vx = struct.unpack_from('<hh', data, pt_off + vi * 4)
                    pts.append((vx, vy))
                deduped = [pts[0]]
                for p in pts[1:]:
                    if p != deduped[-1]:
                        deduped.append(p)
                if len(deduped) >= 2:
                    body_polylines.append(deduped)
            nm = data.find(RECORD_MARKER, pos + 2 + byte_length, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        if type_word == 0x2e2e and pos + 42 <= len(data):
            bx1, by1, bx2, by2 = struct.unpack_from('<iiii', data, pos + 10)
            ax, ay = struct.unpack_from('<ii', data, pos + 26)
            text_len = struct.unpack_from('<H', data, pos + 38)[0]
            text = ''
            if 1 <= text_len <= 100 and pos + 40 + text_len <= len(data):
                tb = data[pos + 40:pos + 40 + text_len]
                if all(32 <= b < 127 for b in tb):
                    text = tb.decode('ascii')
            if all(abs(v) < 5000 for v in (bx1, by1, bx2, by2, ax, ay)):
                text_annotations.append((bx1, by1, bx2, by2, ax, ay, text))
            nm = data.find(RECORD_MARKER, pos + 26, scan_end)
            if nm < 0:
                break
            pos = nm + 8
            continue

        nm = data.find(RECORD_MARKER, pos + 4, scan_end)
        if nm < 0:
            break
        pos = nm + 8

    return (body_rects, body_lines, body_ellipses, body_arcs, body_polygons,
            body_polylines, text_annotations)


def _parse_cache_pin_numbers(data):
    """Parse 0x7f-separated pin number lists from Cache.

    These appear as: CellName\\x00 count(u16LE) then count entries of
    u16LE(len) + ASCII(len) + \\x7f.  Each entry is the physical pin
    number for the corresponding pin in the IC-style (RECORD_MARKER)
    pin list at the same index.

    Returns {cell_name: [pin_number_str, ...]}.
    """
    PIN_NUM_RE = re.compile(
        rb'([A-Za-z0-9_.+/()-]{2,30})\x00(..)',
        re.DOTALL,
    )
    result = {}
    for m in PIN_NUM_RE.finditer(data):
        name = m.group(1).decode('ascii')
        if '.Normal' in name or '.Convert' in name:
            continue
        count = struct.unpack_from('<H', m.group(2), 0)[0]
        if count < 2 or count > 500:
            continue
        p = m.end()
        nlen = struct.unpack_from('<H', data, p)[0] if p + 2 <= len(data) else 0
        if nlen < 1 or nlen > 10 or p + 2 + nlen >= len(data):
            continue
        nb = data[p + 2:p + 2 + nlen]
        if not all(32 <= b < 127 for b in nb):
            continue
        if data[p + 2 + nlen] not in (0x7f, 0x00):
            continue
        entries = []
        p2 = p
        ok = True
        for _ in range(count):
            if p2 + 2 > len(data):
                ok = False
                break
            nl = struct.unpack_from('<H', data, p2)[0]
            if nl < 1 or nl > 10 or p2 + 2 + nl >= len(data):
                ok = False
                break
            eb = data[p2 + 2:p2 + 2 + nl]
            if not all(32 <= b < 127 for b in eb):
                ok = False
                break
            entries.append(eb.decode('ascii'))
            p2 += 2 + nl
            while p2 < len(data) and data[p2] in (0x00, 0x7f):
                p2 += 1
        if ok and len(entries) == count:
            if name not in result or len(entries) > len(result[name]):
                result[name] = entries
    return result


def parse_cache_cells(ole):
    """Parse Cache stream to extract cell pin definitions, body rects, lines,
    ellipses, and text annotations.

    Returns (cells, body_rects, body_lines, pin_numbers,
             cell_text_annotations, body_ellipses) where:
      cells = {cell_name: [(pin_name, hot_x, hot_y, body_x, body_y,
                            pin_flags), ...]}
      body_rects = {cell_name: [(x1, y1, x2, y2), ...]}   rectangles in OrCAD units
      body_lines = {cell_name: [(x1, y1, x2, y2), ...]}   line segments in OrCAD units
      body_ellipses = {cell_name: [(x1, y1, x2, y2), ...]} bounding boxes in OrCAD units
      cell_text_annotations = {cell_name:
          [(bbox_x1, bbox_y1, bbox_x2, bbox_y2, anchor_x, anchor_y, text), ...]}
    """
    try:
        data = ole.openstream('Cache').read()
    except Exception:
        return {}, {}, {}, {}, {}, {}, {}

    cell_regions = []
    for m in CELL_RE.finditer(data):
        cell_name = m.group(1).decode('ascii')
        cell_regions.append((m.start(), m.end(), cell_name))

    cells = {}
    body_rects = {}
    body_lines = {}
    body_ellipses = {}
    body_arcs = {}
    body_polygons = {}
    body_polylines = {}
    cell_text_annotations = {}
    seen_names = set()

    for i, (start, end, cell_name) in enumerate(cell_regions):
        if cell_name in ('TitleBlock', 'Border'):
            seen_names.add(cell_name)
            continue

        scan_end = cell_regions[i + 1][0] if i + 1 < len(cell_regions) else len(data)

        if cell_name in seen_names:
            path_len = struct.unpack_from('<H', data, end)[0]
            aps = end + 2 + path_len + 1
            if aps + 32 <= len(data):
                rects, lines, ellipses, arcs, polys, plines, anns = _parse_cache_graphics(data, aps, scan_end)
                if rects and cell_name not in body_rects:
                    body_rects[cell_name] = rects
                if lines:
                    body_lines.setdefault(cell_name, []).extend(lines)
                if ellipses:
                    body_ellipses.setdefault(cell_name, []).extend(ellipses)
                if arcs:
                    body_arcs.setdefault(cell_name, []).extend(arcs)
                if polys:
                    body_polygons.setdefault(cell_name, []).extend(polys)
                if plines:
                    body_polylines.setdefault(cell_name, []).extend(plines)
                if anns:
                    cell_text_annotations.setdefault(cell_name, []).extend(anns)

        seen_names.add(cell_name)

        pins = []
        pos = end
        while pos < scan_end:
            idx = data.find(RECORD_MARKER, pos, scan_end)
            if idx < 0:
                break
            if idx + 12 <= len(data):
                zeros = struct.unpack_from('<I', data, idx + 4)[0]
                if zeros == 0:
                    name_len = struct.unpack_from('<H', data, idx + 8)[0]
                    name_end = idx + 10 + name_len
                    if (1 <= name_len <= 200 and name_end + 17 <= len(data)
                            and data[name_end] == 0):
                        name_bytes = data[idx + 10:name_end]
                        if all(32 <= b < 127 for b in name_bytes):
                            pin_name = name_bytes.decode('ascii')
                            coord_off = name_end + 1
                            bx, by, hx, hy = struct.unpack_from(
                                '<iiii', data, coord_off)
                            if (abs(bx) < 5000 and abs(by) < 5000
                                    and abs(hx) < 5000 and abs(hy) < 5000):
                                pin_flags = data[coord_off + 16]
                                pins.append((pin_name, hx, hy, bx, by,
                                             pin_flags))
            pos = idx + 4

        if pins and (cell_name not in cells
                     or len(pins) > len(cells[cell_name])):
            cells[cell_name] = pins

    pin_numbers = _parse_cache_pin_numbers(data)

    return (cells, body_rects, body_lines, pin_numbers, cell_text_annotations,
            body_ellipses, body_arcs, body_polygons, body_polylines)


_LP_STRUCT_RE = re.compile(rb'(.{4})\1\x18\x00\x18', re.DOTALL)


def parse_cache_pin_visibility(ole):
    """Extract per-cell pin visibility from Cache LibraryPart structures.

    Returns {cell_name: (pin_name_visible, pin_number_visible)}.
    """
    try:
        data = ole.openstream('Cache').read()
    except Exception:
        return {}

    from olb_parser import DataStream, read_library_part

    result = {}
    for m in _LP_STRUCT_RE.finditer(data):
        struct_start = m.start() + 10
        try:
            ds = DataStream(data[struct_start:struct_start + 8000])
            lp = read_library_part(ds)
            if lp.general_properties:
                gp = lp.general_properties
                name = lp.name
                if name.endswith('.Normal'):
                    name = name[:-7]
                vis = (gp.pin_name_visible, gp.pin_number_visible)
                if name not in result:
                    result[name] = vis
                cell_name = name.rsplit(' ', 1)[-1]
                if cell_name != name and cell_name not in result:
                    result[cell_name] = vis
        except Exception:
            pass
    return result


def parse_cache_bboxes(ole):
    """{cell_name: (x1, y1, x2, y2)} symbol body bbox from Cache LibraryParts,
    in cache units (same frame as the pin hot-points)."""
    try:
        data = ole.openstream('Cache').read()
    except Exception:
        return {}
    from olb_parser import DataStream, read_library_part
    result = {}
    for m in _LP_STRUCT_RE.finditer(data):
        struct_start = m.start() + 10
        try:
            lp = read_library_part(DataStream(data[struct_start:struct_start + 8000]))
            if not lp.bbox:
                continue
            name = lp.name[:-7] if lp.name.endswith('.Normal') else lp.name
            box = (lp.bbox.x1, lp.bbox.y1, lp.bbox.x2, lp.bbox.y2)
            for key in (name, name.rsplit(' ', 1)[-1]):
                result.setdefault(key, box)
        except Exception:
            pass
    return result


def register_cache_cells(cache_cells, cache_body_rects=None,
                         cache_body_lines=None,
                         cache_pin_numbers=None,
                         cache_text_annotations=None,
                         cache_body_ellipses=None,
                         cache_body_arcs=None,
                         cache_body_polygons=None,
                         cache_body_polylines=None):
    """Populate _cell_pin_defs, _cell_body_rects, _cell_body_lines,
    _cell_body_ellipses, _cell_body_arcs, _cell_body_polygons,
    _cell_body_polylines, _cell_text_annotations from Cache data.

    Each pin entry is (unique_name, hot_x_mm, hot_y_mm, orig_name,
                       body_x_mm, body_y_mm, pin_flags).
    Each text annotation is (cx_mm, cy_mm, text) — center of the
    bounding box in symbol-local mm and the annotation text.
    """
    if cache_body_rects is None:
        cache_body_rects = {}
    if cache_body_lines is None:
        cache_body_lines = {}
    if cache_pin_numbers is None:
        cache_pin_numbers = {}
    if cache_text_annotations is None:
        cache_text_annotations = {}
    if cache_body_ellipses is None:
        cache_body_ellipses = {}
    if cache_body_arcs is None:
        cache_body_arcs = {}
    if cache_body_polygons is None:
        cache_body_polygons = {}
    if cache_body_polylines is None:
        cache_body_polylines = {}
    for cell_name, pins in cache_cells.items():
        if cell_name in CELL_TO_KICAD:
            continue
        hxs = [p[1] for p in pins]
        hys = [p[2] for p in pins]
        cx = (min(hxs) + max(hxs)) / 2
        cy = (min(hys) + max(hys)) / 2

        num_list = cache_pin_numbers.get(cell_name)
        pin_positions = []
        for pin_idx, pin in enumerate(pins, 1):
            pin_name, hx, hy, bx, by = pin[:5]
            pin_flags = pin[5] if len(pin) > 5 else None
            if num_list and pin_idx <= len(num_list):
                pin_num = num_list[pin_idx - 1]
            else:
                pin_num = str(pin_idx)
            sym_hx = round((hx - cx) * UNIT_TO_MM, 2)
            sym_hy = round(-(hy - cy) * UNIT_TO_MM, 2)
            sym_bx = round((bx - cx) * UNIT_TO_MM, 2)
            sym_by = round(-(by - cy) * UNIT_TO_MM, 2)
            pin_positions.append((pin_num, sym_hx, sym_hy, pin_name,
                                  sym_bx, sym_by, pin_flags))
        _cell_pin_defs[cell_name] = pin_positions
        _cell_centers[cell_name] = (cx, cy)
        _cell_pin_lists[cell_name] = [(p[1], p[2]) for p in pins]

        if cell_name in cache_body_rects:
            sym_rects = []
            for rx1, ry1, rx2, ry2 in cache_body_rects[cell_name]:
                sym_rects.append((
                    round((rx1 - cx) * UNIT_TO_MM, 2),
                    round(-(ry1 - cy) * UNIT_TO_MM, 2),
                    round((rx2 - cx) * UNIT_TO_MM, 2),
                    round(-(ry2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_rects[cell_name] = sym_rects

        if cell_name in cache_body_lines:
            sym_lines = []
            for lx1, ly1, lx2, ly2 in cache_body_lines[cell_name]:
                sym_lines.append((
                    round((lx1 - cx) * UNIT_TO_MM, 2),
                    round(-(ly1 - cy) * UNIT_TO_MM, 2),
                    round((lx2 - cx) * UNIT_TO_MM, 2),
                    round(-(ly2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_lines[cell_name] = sym_lines

        if cell_name in cache_body_ellipses:
            sym_ellipses = []
            for ex1, ey1, ex2, ey2 in cache_body_ellipses[cell_name]:
                sym_ellipses.append((
                    round((ex1 - cx) * UNIT_TO_MM, 2),
                    round(-(ey1 - cy) * UNIT_TO_MM, 2),
                    round((ex2 - cx) * UNIT_TO_MM, 2),
                    round(-(ey2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_ellipses[cell_name] = sym_ellipses

        if cell_name in cache_body_arcs:
            sym_arcs = []
            for abx1, aby1, abx2, aby2, asx, asy, aex, aey in cache_body_arcs[cell_name]:
                sym_arcs.append((
                    round((abx1 - cx) * UNIT_TO_MM, 2),
                    round(-(aby1 - cy) * UNIT_TO_MM, 2),
                    round((abx2 - cx) * UNIT_TO_MM, 2),
                    round(-(aby2 - cy) * UNIT_TO_MM, 2),
                    round((asx - cx) * UNIT_TO_MM, 2),
                    round(-(asy - cy) * UNIT_TO_MM, 2),
                    round((aex - cx) * UNIT_TO_MM, 2),
                    round(-(aey - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_arcs[cell_name] = sym_arcs

        if cell_name in cache_body_polygons:
            sym_polys = []
            for poly in cache_body_polygons[cell_name]:
                sym_poly = [
                    (round((x - cx) * UNIT_TO_MM, 2),
                     round(-(y - cy) * UNIT_TO_MM, 2))
                    for x, y in poly
                ]
                sym_polys.append(sym_poly)
            _cell_body_polygons[cell_name] = sym_polys

        if cell_name in cache_body_polylines:
            sym_plines = []
            for pline in cache_body_polylines[cell_name]:
                sym_pline = [
                    (round((x - cx) * UNIT_TO_MM, 2),
                     round(-(y - cy) * UNIT_TO_MM, 2))
                    for x, y in pline
                ]
                sym_plines.append(sym_pline)
            _cell_body_polylines[cell_name] = sym_plines

        if cell_name in cache_text_annotations:
            sym_anns = []
            for bx1, by1, bx2, by2, ax, ay, text in cache_text_annotations[cell_name]:
                mx = (bx1 + bx2) / 2
                my = (by1 + by2) / 2
                angle = 900 if abs(by2 - by1) > abs(bx2 - bx1) else 0
                sym_anns.append((
                    round((mx - cx) * UNIT_TO_MM, 2),
                    round(-(my - cy) * UNIT_TO_MM, 2),
                    text,
                    angle,
                ))
            _cell_text_annotations[cell_name] = sym_anns

    all_graphic_names = (set(cache_body_rects) | set(cache_body_lines)
                         | set(cache_body_ellipses) | set(cache_body_arcs)
                         | set(cache_body_polygons))
    for cell_name in all_graphic_names - set(cache_cells):
        if cell_name in CELL_TO_KICAD:
            continue
        all_coords = []
        for rx1, ry1, rx2, ry2 in cache_body_rects.get(cell_name, []):
            all_coords.extend([(rx1, ry1), (rx2, ry2)])
        for lx1, ly1, lx2, ly2 in cache_body_lines.get(cell_name, []):
            all_coords.extend([(lx1, ly1), (lx2, ly2)])
        for ex1, ey1, ex2, ey2 in cache_body_ellipses.get(cell_name, []):
            all_coords.extend([(ex1, ey1), (ex2, ey2)])
        for abx1, aby1, abx2, aby2, _, _, _, _ in cache_body_arcs.get(cell_name, []):
            all_coords.extend([(abx1, aby1), (abx2, aby2)])
        for poly in cache_body_polygons.get(cell_name, []):
            all_coords.extend(poly)
        if not all_coords:
            continue
        xs = [c[0] for c in all_coords]
        ys = [c[1] for c in all_coords]
        cx = (min(xs) + max(xs)) / 2
        cy = (min(ys) + max(ys)) / 2

        if cell_name in cache_body_rects:
            sym_rects = []
            for rx1, ry1, rx2, ry2 in cache_body_rects[cell_name]:
                sym_rects.append((
                    round((rx1 - cx) * UNIT_TO_MM, 2),
                    round(-(ry1 - cy) * UNIT_TO_MM, 2),
                    round((rx2 - cx) * UNIT_TO_MM, 2),
                    round(-(ry2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_rects[cell_name] = sym_rects

        if cell_name in cache_body_lines:
            sym_lines = []
            for lx1, ly1, lx2, ly2 in cache_body_lines[cell_name]:
                sym_lines.append((
                    round((lx1 - cx) * UNIT_TO_MM, 2),
                    round(-(ly1 - cy) * UNIT_TO_MM, 2),
                    round((lx2 - cx) * UNIT_TO_MM, 2),
                    round(-(ly2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_lines[cell_name] = sym_lines

        if cell_name in cache_body_ellipses:
            sym_ellipses = []
            for ex1, ey1, ex2, ey2 in cache_body_ellipses[cell_name]:
                sym_ellipses.append((
                    round((ex1 - cx) * UNIT_TO_MM, 2),
                    round(-(ey1 - cy) * UNIT_TO_MM, 2),
                    round((ex2 - cx) * UNIT_TO_MM, 2),
                    round(-(ey2 - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_ellipses[cell_name] = sym_ellipses

        if cell_name in cache_body_arcs:
            sym_arcs = []
            for abx1, aby1, abx2, aby2, asx, asy, aex, aey in cache_body_arcs[cell_name]:
                sym_arcs.append((
                    round((abx1 - cx) * UNIT_TO_MM, 2),
                    round(-(aby1 - cy) * UNIT_TO_MM, 2),
                    round((abx2 - cx) * UNIT_TO_MM, 2),
                    round(-(aby2 - cy) * UNIT_TO_MM, 2),
                    round((asx - cx) * UNIT_TO_MM, 2),
                    round(-(asy - cy) * UNIT_TO_MM, 2),
                    round((aex - cx) * UNIT_TO_MM, 2),
                    round(-(aey - cy) * UNIT_TO_MM, 2),
                ))
            _cell_body_arcs[cell_name] = sym_arcs

        if cell_name in cache_body_polygons:
            sym_polys = []
            for poly in cache_body_polygons[cell_name]:
                sym_poly = [
                    (round((x - cx) * UNIT_TO_MM, 2),
                     round(-(y - cy) * UNIT_TO_MM, 2))
                    for x, y in poly
                ]
                sym_polys.append(sym_poly)
            _cell_body_polygons[cell_name] = sym_polys

        if cell_name in cache_body_polylines:
            sym_plines = []
            for pline in cache_body_polylines[cell_name]:
                sym_pline = [
                    (round((x - cx) * UNIT_TO_MM, 2),
                     round(-(y - cy) * UNIT_TO_MM, 2))
                    for x, y in pline
                ]
                sym_plines.append(sym_pline)
            _cell_body_polylines[cell_name] = sym_plines


# ---------------------------------------------------------------------------
# Title-block field extraction (from Library stream)
# ---------------------------------------------------------------------------

DOC_NUMBER_RE = re.compile(r'^EP\d[A-Z]{2}-AB(-\d{2,4})+$')


def _enumerate_u16_strings(data):
    """Yield every back-to-back (u16 length + ASCII bytes + null) string in data."""
    off = 0
    while off + 3 < len(data):
        L = struct.unpack_from('<H', data, off)[0]
        if 1 <= L <= 150 and off + 2 + L + 1 <= len(data):
            sb = data[off + 2:off + 2 + L]
            if all(0x20 <= b <= 0x7e for b in sb) and data[off + 2 + L] == 0:
                yield off, L, sb.decode('ascii')
                off += 2 + L + 1
                continue
        off += 1


def parse_title_block(ole):
    """Extract OrCAD title-block fields from the Library stream.

    Returns a dict with keys {title, doc_number, rev, company}, any of
    which may be absent. Date is not stored in DSN and is left empty.

    Heuristic: the Library stream contains all the title-block fields as
    a packed run of `u16-length + ASCII + null` strings. The fields appear
    as [..., Title, DocNumber, Rev?, UUID?, ...]. The DSN may carry
    leftover doc-numbers from previous clones/renames; the *last*
    matching record before `SCHEMATIC1` (or end-of-file if not found) is
    the live one. We:
      1. Find the SCHEMATIC1 marker; if absent, fall back to the last
         match in the whole stream.
      2. Walk backward to the nearest string matching the doc-number
         pattern.
      3. Take the immediately-preceding string as the Title (skipping
         UUID-looking values starting with `{`).
      4. Take the nearest short version-like string (`1.0`, `1.1`, …)
         in a small window after the DocNumber as the Rev.

    Returns {} if Library is missing or no doc-number pattern is found.
    """
    try:
        data = ole.openstream('Library').read()
    except Exception:
        return {}

    strings = list(_enumerate_u16_strings(data))
    if not strings:
        return {}

    # Locate the live title-block: take the LAST EP-doc-number match
    # before the SCHEMATIC1 sentinel (if present), else last in stream.
    sentinel_idx = next((i for i, (_, _, s) in enumerate(strings)
                        if s == 'SCHEMATIC1'), len(strings))
    live_doc_idx = None
    for i in range(sentinel_idx - 1, -1, -1):
        if DOC_NUMBER_RE.match(strings[i][2]):
            live_doc_idx = i
            break
    if live_doc_idx is None:
        return {}

    i = live_doc_idx
    doc_num = strings[i][2]
    title = ''
    if i > 0:
        prev = strings[i - 1][2]
        if not prev.startswith('{'):
            title = prev
    rev = ''
    for j in range(i + 1, min(i + 5, len(strings))):
        t = strings[j][2]
        if re.fullmatch(r'\d+\.\d+', t):
            rev = t
            break
    result = {'doc_number': doc_num}
    if title:
        result['title'] = title
    if rev:
        result['rev'] = rev
    return result


# ---------------------------------------------------------------------------
# Library style table (font/weight/italic per text style ID)
# ---------------------------------------------------------------------------

def parse_library_styles(ole):
    """Parse the Library stream's font/style table.

    The Library stream stores a packed sequence of 60-byte style records,
    each tagged with a negative i32 (`f? ff ff ff`). Records carry the
    Windows GDI LOGFONT fields (weight, italic, charset, pitch/family,
    face name).

    Page-stream text records reference these styles by a **1-based**
    index in the text record's `style_id` field (formerly `font_size`):
    `library_styles[text.style_id - 1]` is the style that should apply.

    Returns a list of dicts (0-indexed) with keys:
      tag         (negative i32, lfHeight from LOGFONT)
      weight      (Windows GDI lfWeight: 400 = Normal, 700 = Bold)
      italic      (True/False)
      escapement  (lfEscapement: rotation in tenths of degrees, e.g. 2700 = 270°)
      face        (font face name string, possibly empty)
      ext_word    (u32 at offset +34 — encoded color/size, not yet decoded)
      flag_byte   (u8 at offset +56 — set when ext_word is meaningful)
    """
    try:
        data = ole.openstream('Library').read()
    except Exception:
        return []

    styles = []
    seen = set()
    i = 0
    while i + 60 <= len(data):
        # Negative-i32 tag at i: low byte 0x80..0xff, then three 0xff.
        if (data[i+1] == 0xff and data[i+2] == 0xff and data[i+3] == 0xff
                and 0x80 <= data[i] <= 0xff and i not in seen):
            tag = struct.unpack_from('<i', data, i)[0]
            escapement = struct.unpack_from('<i', data, i + 8)[0]
            weight = struct.unpack_from('<I', data, i + 16)[0]
            italic_byte = data[i + 20]
            face_bytes = bytearray()
            for b in data[i + 28:i + 58]:
                if b == 0:
                    break
                if 0x20 <= b < 0x7e:
                    face_bytes.append(b)
                else:
                    break
            face = face_bytes.decode('ascii', errors='replace')
            ext_word = struct.unpack_from('<I', data, i + 34)[0]
            flag_byte = data[i + 56]
            styles.append({
                'tag':      tag,
                'weight':   weight,
                'italic':   italic_byte == 0xff,
                'escapement': escapement,
                'face':     face,
                'ext_word': ext_word,
                'flag_byte': flag_byte,
            })
            seen.add(i)
            i += 60  # advance past this record
            continue
        i += 1
    return styles


# ---------------------------------------------------------------------------
# Library value string table (component Value field lookup)
# ---------------------------------------------------------------------------

_library_value_strings = []


def parse_library_value_strings(ole):
    """Parse the Library stream's string table using olb_parser.

    The string table is indexed directly by the value_idx field in
    page-stream component records — no offset needed.

    Populates the module-level _library_value_strings list and returns it.
    """
    global _library_value_strings
    try:
        from olb_parser import parse_library_stream
        data = ole.openstream('Library').read()
        lib = parse_library_stream(data)
        _library_value_strings = list(lib.str_lst)
    except Exception:
        _library_value_strings = []
    return _library_value_strings


def lookup_component_value(value_idx):
    """Resolve a component's value index to its value string."""
    if 0 <= value_idx < len(_library_value_strings):
        return _library_value_strings[value_idx]
    return ''


def extract_library_power_names(value_strings):
    """Return power-symbol names referenced from POWER.OLB string blocks."""
    power_names = set()
    i = 0
    while i < len(value_strings):
        s = value_strings[i]
        if isinstance(s, str) and s.upper().endswith('POWER.OLB'):
            j = i + 1
            while j < len(value_strings):
                name = value_strings[j]
                if not isinstance(name, str):
                    break
                upper = name.upper()
                if upper.endswith('.OLB') or upper.startswith('{'):
                    break
                if re.fullmatch(r'\d+(?:\.\d+)*', name):
                    break
                if re.fullmatch(r'[A-Za-z0-9_./+\-]+', name):
                    power_names.add(name)
                    j += 1
                    continue
                break
            i = j
        else:
            i += 1
    return power_names


# ---------------------------------------------------------------------------
# Hierarchy stream parsing (for cross-page net analysis)
# ---------------------------------------------------------------------------

def parse_hierarchy_nets(ole):
    """Parse the Hierarchy stream to extract all nets across all pages."""
    try:
        data = ole.openstream("Views/SCHEMATIC1/Hierarchy/Hierarchy").read()
    except Exception:
        return {}

    nets = {}
    pos = 0
    while True:
        idx = data.find(RECORD_MARKER, pos)
        if idx < 0:
            break
        rec_start = idx + 8
        if rec_start + 6 >= len(data):
            break
        net_id = struct.unpack_from("<I", data, rec_start)[0]
        name_len = struct.unpack_from("<H", data, rec_start + 4)[0]
        name_start = rec_start + 6
        if name_len < 1 or name_len > 80 or name_start + name_len > len(data):
            pos = idx + 4
            continue
        raw = data[name_start:name_start + name_len]
        if any(b < 32 or b > 126 for b in raw):
            pos = idx + 4
            continue
        name = raw.decode("ascii").rstrip("\0")
        if name:
            nets[net_id] = name
        pos = name_start + name_len + 1

    return nets


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    # Minimal argv parsing: --debug-bbox is a flag, other args are
    # the input DSN and optional output directory.
    argv = list(sys.argv[1:])
    debug_bbox = False
    if "--debug-bbox" in argv:
        debug_bbox = True
        argv.remove("--debug-bbox")
    debug_ref_val = False
    if "--debug-ref-val" in argv:
        debug_ref_val = True
        argv.remove("--debug-ref-val")
    debug_symbol = False
    if "--debug-symbol" in argv:
        debug_symbol = True
        argv.remove("--debug-symbol")
    global _use_kicad_power
    if "--kicad-power" in argv:
        _use_kicad_power = True
        argv.remove("--kicad-power")
    if not argv:
        print(f"Usage: {sys.argv[0]} [--debug-bbox] [--debug-ref-val] "
              f"[--debug-symbol] [--kicad-power] <file.DSN> [output_dir]",
              file=sys.stderr)
        sys.exit(1)

    dsn_path = Path(argv[0])
    if not dsn_path.exists():
        print(f"DSN not found: {dsn_path}", file=sys.stderr)
        sys.exit(1)

    if len(argv) > 1:
        output_dir = Path(argv[1])
    else:
        output_dir = Path(dsn_path.stem + "_kicad")

    output_dir.mkdir(parents=True, exist_ok=True)

    project_name = dsn_path.stem
    safe_project = re.sub(r'[^A-Za-z0-9_.-]', '_', project_name)

    if _use_kicad_power:
        print("Loading KiCad power library...")
        load_kicad_power_library()

    print(f"Opening {dsn_path.name}...")
    if not _HAS_FREETYPE:
        print("  (freetype-py not installed — using rough 0.6 width "
              "ratio for text sizing; install `freetype-py` and ensure "
              "Arial TTF is available for exact measurements)")
    ole = olefile.OleFileIO(str(dsn_path))
    dsn_bytes = dsn_path.read_bytes()

    # Parse title-block fields (project-wide, applied to every page)
    title_block = parse_title_block(ole)
    if title_block:
        bits = [f"{k}={v!r}" for k, v in title_block.items()]
        print(f"  Title block: {', '.join(bits)}")
    else:
        print(f"  Title block: (none found in Library stream)")

    # Parse the Library stream's style table (font/weight/italic per style ID).
    # Text records on each page reference these by style_id (1-based).
    library_styles = parse_library_styles(ole)
    if library_styles:
        n_bold = sum(1 for s in library_styles if s['weight'] == 700)
        n_italic = sum(1 for s in library_styles if s['italic'])
        print(f"  Library styles: {len(library_styles)} records "
              f"({n_bold} bold, {n_italic} italic)")

    # Parse the Library stream's value string table for component values.
    value_strings = parse_library_value_strings(ole)
    print(f"  Library value strings: {len(value_strings)} entries")
    library_power_names = extract_library_power_names(value_strings)
    if library_power_names:
        print(f"  Library POWER.OLB names: {len(library_power_names)}")
    # Note: the DSN's title-block fields are what's *stored* in the file —
    # not necessarily the latest version printed in the PDF. For renamed
    # or re-exported DSNs the DocNumber may differ from the filename.

    # Parse hierarchy for global net analysis
    print("  Parsing Hierarchy stream...")
    hierarchy_nets = parse_hierarchy_nets(ole)
    print(f"  Found {len(hierarchy_nets)} nets in hierarchy")

    # Get page streams
    page_streams = get_page_streams(ole)
    print(f"  Found {len(page_streams)} pages")

    # Determine which nets appear on multiple pages (→ global labels)
    all_page_nets = defaultdict(set)
    page_data_cache = {}
    for i, stream_path in enumerate(page_streams):
        data = ole.openstream(stream_path).read()
        page_data_cache[stream_path] = data
        page_nets = parse_net_table(data)
        for net_name in page_nets.values():
            all_page_nets[net_name].add(i)

    global_nets = {n for n, pages in all_page_nets.items() if len(pages) > 1}
    print(f"  {len(global_nets)} global nets, "
          f"{len(all_page_nets) - len(global_nets)} local nets")

    # Parse Cache stream for complete cell pin definitions
    print("  Parsing Cache stream...")
    _cell_pin_defs.clear()
    _cell_body_rects.clear()
    _cell_body_lines.clear()
    _cell_body_ellipses.clear()
    _cell_body_arcs.clear()
    _cell_body_polygons.clear()
    _cell_body_polylines.clear()
    _cell_text_annotations.clear()
    _cell_centers.clear()
    _cell_pin_lists.clear()
    _cell_bboxes.clear()
    _pin_extension_deltas.clear()
    _cache_pin_visibility.clear()
    _orcad_power_glyphs.clear()
    _orcad_power_glyphs.update(extract_orcad_power_glyphs(ole))
    if _orcad_power_glyphs:
        glyph_names = ", ".join(sorted(_orcad_power_glyphs))
        print(f"  OrCAD power glyphs: {glyph_names}")
    _cache_pin_visibility.update(parse_cache_pin_visibility(ole))
    _cell_bboxes.update(parse_cache_bboxes(ole))
    (cache_cells, cache_body_rects, cache_body_lines, cache_pin_numbers,
     cache_text_annotations, cache_body_ellipses, cache_body_arcs,
     cache_body_polygons, cache_body_polylines) = parse_cache_cells(ole)
    register_cache_cells(cache_cells, cache_body_rects, cache_body_lines,
                         cache_pin_numbers, cache_text_annotations,
                         cache_body_ellipses, cache_body_arcs,
                         cache_body_polygons, cache_body_polylines)
    cache_count = len(_cell_pin_defs)
    for cname, cpins in cache_cells.items():
        print(f"    {cname}: {len(cpins)} pins")
    print(f"  {cache_count} cells from Cache (+ R, C built-in)")
    vis_count = sum(1 for v in _cache_pin_visibility.values()
                    if not v[0] or not v[1])
    print(f"  Pin visibility overrides: {vis_count} cells")

    # Detect multi-unit components (cells sharing the same ref designator)
    print("  Detecting multi-unit components...")
    multi_groups = detect_multi_unit_components(ole)
    if multi_groups:
        for base, umap in sorted(multi_groups.items()):
            print(f"    {base}: {len(umap)} units")
    else:
        print("    (none)")

    # Supplement with page-stream pin data for cells not found in Cache
    print("  Scanning pages for additional cell definitions...")
    for stream_path in page_streams:
        data = page_data_cache[stream_path]
        components = parse_components(data)
        for comp in components:
            if comp['pins'] and comp['cell'] not in _cell_pin_defs:
                register_cell_pins(comp['cell'], comp['pins'],
                                   comp['orient'], comp['x'], comp['y'])

    extra = len(_cell_pin_defs) - cache_count
    if extra:
        print(f"  +{extra} cells from page streams")

    print(f"  Total: {len(_cell_pin_defs)} cell definitions (+ R, C built-in)")

    # Pass 2: generate schematics
    page_filenames = []
    page_names = []
    total_stats = defaultdict(int)
    project_power_names = set()
    project_power_symbol_styles = {}
    project_used_cells = set()
    power_ref_index = 1

    for i, stream_path in enumerate(page_streams):
        page_key = stream_path.split("/")[-1]
        data = page_data_cache[stream_path]

        page_name, paper = parse_page_header(data)
        if not page_name:
            page_name = page_key

        safe_name = re.sub(r'[^A-Za-z0-9_.-]', '_', page_key)
        safe_name = re.sub(r'_+', '_', safe_name).strip('_')
        filename = f"{safe_name}.kicad_sch"

        print(f"  [{i + 1:2d}/{len(page_streams)}] {page_name} ({paper})...",
              end=" ", flush=True)

        net_table = parse_net_table(data)
        wires = parse_wires(data, net_table)
        components = parse_components(data, net_table)
        power_syms = parse_power_symbols(data, net_table)
        power_syms, page_power_names = resolve_power_symbol_nets(
            power_syms, wires, components)
        page_power_styles = power_symbol_styles(power_syms)
        page_power_names.update(
            name for name in net_table.values() if name in library_power_names)
        texts = parse_text_annotations(data, paper)
        page_rects, page_lines, page_ellipses, page_polygons = \
            parse_page_graphics(data, paper)
        aliases = parse_net_aliases(data, net_table)

        seed_uuid_rng(dsn_bytes, filename)
        content = generate_page_sch(
            page_name, paper, wires, components, power_syms,
            net_table, global_nets, texts=texts,
            title_block=title_block,
            sheet_number=i + 1,
            total_sheets=len(page_streams),
            page_rects=page_rects,
            page_lines=page_lines,
            page_ellipses=page_ellipses,
            page_polygons=page_polygons,
            library_styles=library_styles,
            debug_bbox=debug_bbox,
            debug_ref_val=debug_ref_val,
            debug_symbol=debug_symbol,
            net_aliases=aliases,
            power_net_names=page_power_names,
            power_symbol_styles=page_power_styles,
        )
        content, power_ref_index = annotate_power_references_in_schematic(
            content, power_ref_index)
        (output_dir / filename).write_text(content, encoding='utf-8')

        page_filenames.append(filename)
        page_names.append(page_name)

        total_stats['wires'] += len(wires)
        total_stats['components'] += len(components)
        total_stats['nets'] += len(net_table)
        for comp in components:
            if comp['cell']:
                project_used_cells.add(comp['cell'])

        project_power_names.update(page_power_names)
        project_power_symbol_styles.update(page_power_styles)

        pwr_counts = defaultdict(int)
        for ps in power_syms:
            if ps.get('matched'):
                pwr_counts[ps['name']] += 1
            else:
                pwr_counts[ps.get('record_name', ps['name'])] += 1
        for pname, pcount in pwr_counts.items():
            total_stats[f'pwr_{pname}'] += pcount

        pwr_summary = ", ".join(f"{c} {n}" for n, c in sorted(pwr_counts.items()))
        if not pwr_summary:
            pwr_summary = "0 power"

        print(f"{len(wires)} wires, {len(components)} components, "
              f"{pwr_summary}, {len(net_table)} nets")

    # Root schematic
    print("  Generating root schematic...")
    seed_uuid_rng(dsn_bytes, f"{safe_project}.kicad_sch")
    root_content = generate_root_sch(page_filenames, page_names, safe_project)
    (output_dir / f"{safe_project}.kicad_sch").write_text(root_content, encoding='utf-8')

    # Symbol library
    print("  Generating symbol library...")
    sym_lib = generate_symbol_library(safe_project,
                                      power_names=project_power_names,
                                      used_cells=project_used_cells,
                                      power_symbol_styles=project_power_symbol_styles)
    (output_dir / f"{safe_project}.kicad_sym").write_text(sym_lib, encoding='utf-8')

    # sym-lib-table
    sym_lib_table = (
        f"(sym_lib_table\n"
        f"  (version 7)\n"
        f"  (lib (name \"{safe_project}\")"
        f"(type \"KiCad\")"
        f"(uri \"${{KIPRJMOD}}/{safe_project}.kicad_sym\")"
        f"(options \"\")(descr \"\"))\n"
        f")\n"
    )
    (output_dir / "sym-lib-table").write_text(sym_lib_table, encoding='utf-8')

    # Project file
    (output_dir / f"{safe_project}.kicad_pro").write_text(
        generate_project(safe_project), encoding='utf-8')

    pwr_totals = {k[4:]: v for k, v in total_stats.items() if k.startswith('pwr_')}
    pwr_total_summary = ", ".join(f"{c} {n}" for n, c in sorted(pwr_totals.items()))
    if not pwr_total_summary:
        pwr_total_summary = "0 power"

    print(f"\nDone → {output_dir}/")
    print(f"  {len(page_streams)} pages, {total_stats['wires']} wires, "
          f"{total_stats['components']} components, {pwr_total_summary}, "
          f"{total_stats['nets']} nets")


if __name__ == "__main__":
    main()
