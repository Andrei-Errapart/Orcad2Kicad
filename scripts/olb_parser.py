"""
Parser for OrCAD OLB (and DSN Package stream) binary format.

Reimplements the prefix/checkpoint/preamble framework from OpenOrCadParser (C++)
in Python, using olefile for OLE compound document access.
"""

import struct
import base64
from dataclasses import dataclass, field
from typing import Optional


# --- Enums ---

LINE_STYLE_NAMES = {0: "0", 1: "1", 2: "2", 3: "3", 4: "4", 5: "5"}
LINE_WIDTH_NAMES = {0: "0", 1: "1", 2: "2", 3: "3"}
FILL_STYLE_NAMES = {0: "0", 1: "1", 2: "2"}
HATCH_STYLE_NAMES = {-1: "-1", 0: "0", 1: "1", 2: "2", 3: "3", 4: "4", 5: "5"}


# --- Data classes ---

@dataclass
class Point:
    x: int = 0
    y: int = 0


@dataclass
class LogFont:
    height: int = 0
    width: int = 0
    escapement: int = 0
    orientation: int = 0
    weight: int = 0
    italic: int = 0
    underline: int = 0
    strike_out: int = 0
    charset: int = 0
    out_precision: int = 0
    clip_precision: int = 0
    quality: int = 0
    pitch_and_family: int = 0
    face_name: str = ""


@dataclass
class PageSettings:
    create_date_time: int = 0
    modify_date_time: int = 0
    width: int = 0
    height: int = 0
    pin_to_pin: int = 0
    horizontal_count: int = 0
    vertical_count: int = 0
    horizontal_width: int = 0
    vertical_width: int = 0
    horizontal_char: int = 0
    horizontal_ascending: int = 0
    vertical_char: int = 0
    vertical_ascending: int = 0
    is_metric: int = 0
    border_displayed: int = 0
    border_printed: int = 0
    grid_ref_displayed: int = 0
    grid_ref_printed: int = 0
    titleblock_displayed: int = 0
    titleblock_printed: int = 0
    ansi_grid_refs: int = 0


@dataclass
class SymbolDisplayProp:
    name_idx: int = 0
    x: int = 0
    y: int = 0
    text_font_idx: int = 0
    rotation: int = 0
    prop_color: int = 0
    disp_type: int = 0
    value_if_value_exist: int = 0


@dataclass
class SymbolBBox:
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0


@dataclass
class GeneralProperties:
    implementation_path: str = ""
    implementation: str = ""
    ref_des: str = ""
    part_value: str = ""
    pin_name_visible: bool = True
    pin_name_rotate: bool = True
    pin_number_visible: bool = True
    implementation_type: int = 0


@dataclass
class PrimLine:
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    line_style: int = 0
    line_width: int = 0


@dataclass
class PrimRect:
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    line_style: int = 0
    line_width: int = 0
    fill_style: int = 1
    hatch_style: int = 0


@dataclass
class PrimArc:
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    start_x: int = 0
    start_y: int = 0
    end_x: int = 0
    end_y: int = 0
    line_style: int = 0
    line_width: int = 0


@dataclass
class PrimEllipse:
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    line_style: int = 0
    line_width: int = 0
    fill_style: int = 1
    hatch_style: int = 0


@dataclass
class PrimBezier:
    line_style: int = 0
    line_width: int = 0
    points: list = field(default_factory=list)


@dataclass
class PrimPolyline:
    line_style: int = 0
    line_width: int = 0
    points: list = field(default_factory=list)


@dataclass
class PrimPolygon:
    line_style: int = 0
    line_width: int = 0
    fill_style: int = 1
    hatch_style: int = 0
    points: list = field(default_factory=list)


@dataclass
class PrimCommentText:
    loc_x: int = 0
    loc_y: int = 0
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    text_font_idx: int = 0
    name: str = ""


@dataclass
class PrimBitmap:
    loc_x: int = 0
    loc_y: int = 0
    x1: int = 0
    y1: int = 0
    x2: int = 0
    y2: int = 0
    bmp_width: int = 0
    bmp_height: int = 0
    raw_img_data: bytes = b""


@dataclass
class SymbolPin:
    name: str = ""
    start_x: int = 0
    start_y: int = 0
    hotpt_x: int = 0
    hotpt_y: int = 0
    pin_shape: int = 0
    port_type: int = 0
    display_props: list = field(default_factory=list)


@dataclass
class LibraryPart:
    name: str = ""
    source_library: str = ""
    primitives: list = field(default_factory=list)
    symbol_pins: list = field(default_factory=list)
    display_props: list = field(default_factory=list)
    general_properties: Optional[GeneralProperties] = None
    bbox: Optional[SymbolBBox] = None


@dataclass
class PartCell:
    ref: str = ""
    view_number: int = 0
    normal_name: str = ""
    convert_name: str = ""
    library_parts: list = field(default_factory=list)


@dataclass
class Device:
    unit_ref: str = ""
    ref_des: str = ""
    pin_map: list = field(default_factory=list)
    pin_ignore: list = field(default_factory=list)
    pin_group: list = field(default_factory=list)


@dataclass
class Package:
    name: str = ""
    source_library: str = ""
    ref_des: str = ""
    pcb_footprint: str = ""
    devices: list = field(default_factory=list)
    part_cells: list = field(default_factory=list)
    timestamp: int = 0
    timezone: int = 0
    alphabetic_numbering: int = 2
    is_homogeneous: int = 1


@dataclass
class Library:
    introduction: str = ""
    db_type: str = ""
    version_major: int = 0
    version_minor: int = 0
    create_date: int = 0
    modify_date: int = 0
    text_fonts: list = field(default_factory=list)
    some_data: list = field(default_factory=list)
    part_field_mapping: list = field(default_factory=list)
    page_settings: Optional[PageSettings] = None
    str_lst: list = field(default_factory=list)
    part_aliases: list = field(default_factory=list)


@dataclass
class OlbFile:
    path: str = ""
    library: Optional[Library] = None
    packages: list = field(default_factory=list)


# --- Binary reader ---

class DataStream:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def remaining(self) -> int:
        return len(self.data) - self.pos

    def read_uint8(self) -> int:
        val = self.data[self.pos]
        self.pos += 1
        return val

    def read_int8(self) -> int:
        val = struct.unpack_from('<b', self.data, self.pos)[0]
        self.pos += 1
        return val

    def read_uint16(self) -> int:
        val = struct.unpack_from('<H', self.data, self.pos)[0]
        self.pos += 2
        return val

    def read_int16(self) -> int:
        val = struct.unpack_from('<h', self.data, self.pos)[0]
        self.pos += 2
        return val

    def read_uint32(self) -> int:
        val = struct.unpack_from('<I', self.data, self.pos)[0]
        self.pos += 4
        return val

    def read_int32(self) -> int:
        val = struct.unpack_from('<i', self.data, self.pos)[0]
        self.pos += 4
        return val

    def read_bytes(self, n: int) -> bytes:
        val = self.data[self.pos:self.pos + n]
        self.pos += n
        return val

    def peek(self, n: int) -> bytes:
        return self.data[self.pos:self.pos + n]

    def read_string_len_zero_term(self) -> str:
        length = self.read_uint16()
        s = self.data[self.pos:self.pos + length]
        self.pos += length
        if self.pos < len(self.data) and self.data[self.pos] == 0:
            self.pos += 1
        return s.decode('ascii', errors='replace')

    def skip(self, n: int):
        self.pos += n

    def assume_zeros(self, n: int):
        for i in range(n):
            b = self.data[self.pos + i]
            if b != 0:
                raise ValueError(f"Expected zero at offset {self.pos + i}, got 0x{b:02x}")
        self.pos += n


# --- Preamble and Prefix framework ---

PREAMBLE_MAGIC = b'\xff\xe4\x5c\x39'


def read_preamble(ds: DataStream) -> bool:
    if ds.remaining() < 8:
        return False
    if ds.peek(4) != PREAMBLE_MAGIC:
        return False
    ds.skip(4)
    data_len = ds.read_uint32()
    ds.skip(data_len)
    return True


def read_prefixes(ds: DataStream, count: int) -> list:
    """Read `count` prefixes. First count-1 are full (9 bytes), last is short (3 bytes).
    Returns list of (type_byte, offset_or_size) tuples.
    """
    prefixes = []
    for i in range(count):
        type_byte = ds.read_uint8()
        if i < count - 1:
            byte_offset = ds.read_uint32()
            ds.skip(4)  # unknown
            prefixes.append((type_byte, byte_offset))
        else:
            size = ds.read_int16()
            if size >= 0:
                for _ in range(size):
                    ds.read_uint32()  # name index
                    ds.read_uint32()  # value index
            prefixes.append((type_byte, size))
    return prefixes


def auto_read_prefixes(ds: DataStream, expected_type: Optional[int] = None) -> tuple:
    """Try 1-10 prefix counts, return (prefix_list, checkpoint_offsets).
    checkpoint_offsets are computed from full prefix byte_offset values.
    """
    start = ds.pos
    for count in range(10, 0, -1):
        ds.pos = start
        try:
            prefixes = read_prefixes(DataStream(ds.data[start:start + count * 9 + 10]), count)
            all_same_type = all(p[0] == prefixes[0][0] for p in prefixes)
            if not all_same_type:
                continue
            if expected_type is not None and prefixes[0][0] != expected_type:
                continue
            ds.pos = start
            prefixes = read_prefixes(ds, count)
            checkpoint_offsets = []
            prefix_start = start
            for i, (_, offset) in enumerate(prefixes[:-1]):
                cp_pos = prefix_start + 9 + offset
                checkpoint_offsets.append(cp_pos)
                prefix_start += 9
            return prefixes, checkpoint_offsets
        except (struct.error, IndexError, ValueError):
            continue
    ds.pos = start
    raise ValueError(f"Could not determine prefix count at offset 0x{start:x}")


# --- Primitive parsers ---

PRIM_LINE = 0x29
PRIM_RECT = 0x28
PRIM_ARC = 0x2A
PRIM_ELLIPSE = 0x2B
PRIM_POLYGON = 0x2C
PRIM_POLYLINE = 0x2D
PRIM_COMMENT_TEXT = 0x2E
PRIM_BITMAP = 0x2F
PRIM_SYMBOL_VECTOR = 0x30
PRIM_BEZIER = 0x57

PRIMITIVE_TYPES = {
    PRIM_LINE, PRIM_RECT, PRIM_ARC, PRIM_ELLIPSE, PRIM_POLYGON,
    PRIM_POLYLINE, PRIM_COMMENT_TEXT, PRIM_BITMAP, PRIM_SYMBOL_VECTOR, PRIM_BEZIER
}


def read_prim_prefix(ds: DataStream) -> int:
    p1 = ds.read_uint8()
    p2 = ds.read_uint8()
    if p1 != p2:
        raise ValueError(f"Primitive prefix mismatch: 0x{p1:02x} != 0x{p2:02x}")
    return p1


def read_prim_line(ds: DataStream) -> PrimLine:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    line = PrimLine()
    line.x1 = ds.read_int32()
    line.y1 = ds.read_int32()
    line.x2 = ds.read_int32()
    line.y2 = ds.read_int32()
    if byte_length >= 32:
        line.line_style = ds.read_uint32()
        line.line_width = ds.read_uint32()
    ds.pos = start + byte_length
    read_preamble(ds)
    return line


def read_prim_rect(ds: DataStream) -> PrimRect:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    rect = PrimRect()
    rect.x1 = ds.read_int32()
    rect.y1 = ds.read_int32()
    rect.x2 = ds.read_int32()
    rect.y2 = ds.read_int32()
    if byte_length >= 32:
        rect.line_style = ds.read_uint32()
        rect.line_width = ds.read_uint32()
    if byte_length >= 40:
        rect.fill_style = ds.read_uint32()
        rect.hatch_style = ds.read_int32()
    ds.pos = start + byte_length
    read_preamble(ds)
    return rect


def read_prim_arc(ds: DataStream) -> PrimArc:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    arc = PrimArc()
    arc.x1 = ds.read_int32()
    arc.y1 = ds.read_int32()
    arc.x2 = ds.read_int32()
    arc.y2 = ds.read_int32()
    arc.start_x = ds.read_int32()
    arc.start_y = ds.read_int32()
    arc.end_x = ds.read_int32()
    arc.end_y = ds.read_int32()
    if byte_length >= 48:
        arc.line_style = ds.read_uint32()
        arc.line_width = ds.read_uint32()
    ds.pos = start + byte_length
    read_preamble(ds)
    return arc


def read_prim_ellipse(ds: DataStream) -> PrimEllipse:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    ell = PrimEllipse()
    ell.x1 = ds.read_int32()
    ell.y1 = ds.read_int32()
    ell.x2 = ds.read_int32()
    ell.y2 = ds.read_int32()
    if byte_length >= 32:
        ell.line_style = ds.read_uint32()
        ell.line_width = ds.read_uint32()
    if byte_length >= 40:
        ell.fill_style = ds.read_uint32()
        ell.hatch_style = ds.read_int32()
    ds.pos = start + byte_length
    read_preamble(ds)
    return ell


def read_prim_bezier(ds: DataStream) -> PrimBezier:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    bez = PrimBezier()
    # Version detection: version B has lineStyle+lineWidth (8 extra bytes)
    # Version A: byteLength = 10 + 4*pointCount
    # Version B: byteLength = 18 + 4*pointCount
    # We detect by checking if (byteLength - 10) is divisible by 4 with valid point count
    remaining_after_header = byte_length - 8  # after byteLength+zeros already read
    # Try version B first (more common in test files)
    has_style = False
    if remaining_after_header >= 10:
        # Try reading as version B: 8 bytes style + 2 bytes count + points
        save = ds.pos
        try_style_a = (remaining_after_header - 2) // 4  # version A point count
        try_style_b = (remaining_after_header - 10) // 4  # version B point count
        if try_style_b >= 4 and (remaining_after_header - 10) % 4 == 0:
            has_style = True
        elif try_style_a >= 4 and (remaining_after_header - 2) % 4 == 0:
            has_style = False
        else:
            has_style = (byte_length - 8 - 2) % 4 != 0
    if has_style:
        bez.line_style = ds.read_uint32()
        bez.line_width = ds.read_uint32()
    point_count = ds.read_uint16()
    for _ in range(point_count):
        y = ds.read_uint16()
        x = ds.read_uint16()
        bez.points.append(Point(x, y))
    ds.pos = start + byte_length
    read_preamble(ds)
    return bez


def read_prim_polyline(ds: DataStream) -> PrimPolyline:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    poly = PrimPolyline()
    remaining_after_header = byte_length - 8
    has_style = False
    if remaining_after_header >= 10:
        try_style_a = (remaining_after_header - 2) // 4
        try_style_b = (remaining_after_header - 10) // 4
        if try_style_b >= 2 and (remaining_after_header - 10) % 4 == 0:
            has_style = True
        elif try_style_a >= 2 and (remaining_after_header - 2) % 4 == 0:
            has_style = False
        else:
            has_style = (byte_length - 8 - 2) % 4 != 0
    if has_style:
        poly.line_style = ds.read_uint32()
        poly.line_width = ds.read_uint32()
    point_count = ds.read_uint16()
    for _ in range(point_count):
        y = ds.read_uint16()
        x = ds.read_uint16()
        poly.points.append(Point(x, y))
    ds.pos = start + byte_length
    read_preamble(ds)
    return poly


def read_prim_polygon(ds: DataStream) -> PrimPolygon:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    pgon = PrimPolygon()
    remaining = byte_length - 8
    # Version C: style(8) + fill(8) + count(2) + points
    # Version B: style(8) + count(2) + points
    # Version A: count(2) + points
    if remaining >= 18 and (remaining - 18) % 4 == 0:
        pgon.line_style = ds.read_uint32()
        pgon.line_width = ds.read_uint32()
        pgon.fill_style = ds.read_uint32()
        pgon.hatch_style = ds.read_int32()
    elif remaining >= 10 and (remaining - 10) % 4 == 0:
        pgon.line_style = ds.read_uint32()
        pgon.line_width = ds.read_uint32()
    point_count = ds.read_uint16()
    for _ in range(point_count):
        y = ds.read_uint16()
        x = ds.read_uint16()
        pgon.points.append(Point(x, y))
    ds.pos = start + byte_length
    read_preamble(ds)
    return pgon


def read_prim_comment_text(ds: DataStream) -> PrimCommentText:
    start = ds.pos
    byte_length = ds.read_uint32() + 8  # C++ adds 8 to account for byteLength+zeros fields
    ds.assume_zeros(4)
    ct = PrimCommentText()
    ct.loc_x = ds.read_int32()
    ct.loc_y = ds.read_int32()
    ct.x2 = ds.read_int32()
    ct.y2 = ds.read_int32()
    ct.x1 = ds.read_int32()
    ct.y1 = ds.read_int32()
    ct.text_font_idx = ds.read_uint16()
    ds.skip(2)  # unknown
    ct.name = ds.read_string_len_zero_term()
    ds.pos = start + byte_length
    read_preamble(ds)
    return ct


def read_prim_bitmap(ds: DataStream) -> PrimBitmap:
    start = ds.pos
    byte_length = ds.read_uint32()
    ds.assume_zeros(4)
    bm = PrimBitmap()
    bm.loc_x = ds.read_int32()
    bm.loc_y = ds.read_int32()
    bm.x2 = ds.read_int32()
    bm.y2 = ds.read_int32()
    bm.x1 = ds.read_int32()
    bm.y1 = ds.read_int32()
    bm.bmp_width = ds.read_uint32()
    bm.bmp_height = ds.read_uint32()
    data_size = ds.read_uint32()
    bm.raw_img_data = ds.read_bytes(data_size)
    ds.pos = start + byte_length
    read_preamble(ds)
    return bm


def read_primitive(ds: DataStream, prim_type: int):
    readers = {
        PRIM_LINE: read_prim_line,
        PRIM_RECT: read_prim_rect,
        PRIM_ARC: read_prim_arc,
        PRIM_ELLIPSE: read_prim_ellipse,
        PRIM_BEZIER: read_prim_bezier,
        PRIM_POLYLINE: read_prim_polyline,
        PRIM_POLYGON: read_prim_polygon,
        PRIM_COMMENT_TEXT: read_prim_comment_text,
        PRIM_BITMAP: read_prim_bitmap,
    }
    reader = readers.get(prim_type)
    if reader is None:
        byte_length = ds.read_uint32()
        ds.skip(byte_length - 4)
        read_preamble(ds)
        return None
    return reader(ds)


# --- Structure parsers ---

STRUCT_PART_CELL = 0x06
STRUCT_LIBRARY_PART = 0x18
STRUCT_SYMBOL_PIN_SCALAR = 0x1A
STRUCT_SYMBOL_PIN_BUS = 0x1B
STRUCT_PACKAGE = 0x1F
STRUCT_DEVICE = 0x20
STRUCT_SYMBOL_DISPLAY_PROP = 0x27


def read_symbol_display_prop(ds: DataStream) -> SymbolDisplayProp:
    prefixes, checkpoints = auto_read_prefixes(ds, STRUCT_SYMBOL_DISPLAY_PROP)
    read_preamble(ds)
    # checkpoint
    sdp = SymbolDisplayProp()
    sdp.name_idx = ds.read_uint32()
    sdp.x = ds.read_int16()
    sdp.y = ds.read_int16()
    rot_font = ds.read_uint16()
    sdp.text_font_idx = rot_font & 0x3FFF
    sdp.rotation = (rot_font >> 14) & 0x03
    sdp.prop_color = ds.read_uint8()
    _disp_byte0 = ds.read_uint8()  # flags, not fully decoded
    sdp.disp_type = ds.read_uint8()
    sdp.value_if_value_exist = 0
    ds.skip(1)  # assumed zero
    # checkpoint
    return sdp


def read_symbol_bbox(ds: DataStream) -> SymbolBBox:
    bbox = SymbolBBox()
    bbox.x1 = ds.read_int16()
    bbox.y1 = ds.read_int16()
    bbox.x2 = ds.read_int16()
    bbox.y2 = ds.read_int16()
    ds.skip(4)  # unknown
    return bbox


def read_general_properties(ds: DataStream) -> GeneralProperties:
    gp = GeneralProperties()
    gp.implementation_path = ds.read_string_len_zero_term()
    gp.implementation = ds.read_string_len_zero_term()
    gp.ref_des = ds.read_string_len_zero_term()
    gp.part_value = ds.read_string_len_zero_term()
    properties = ds.read_uint8()
    pin_props = properties & 0x07
    gp.pin_name_visible = bool(pin_props & 0x01)
    gp.pin_name_rotate = bool(pin_props & 0x02)
    gp.pin_number_visible = not bool(pin_props & 0x04)
    gp.implementation_type = (properties >> 3) & 0x07
    ds.skip(1)  # assumed zero
    return gp


def read_symbol_pin(ds: DataStream) -> SymbolPin:
    prefixes, checkpoints = auto_read_prefixes(ds)
    read_preamble(ds)
    pin = SymbolPin()
    pin.name = ds.read_string_len_zero_term()
    pin.start_x = ds.read_int32()
    pin.start_y = ds.read_int32()
    pin.hotpt_x = ds.read_int32()
    pin.hotpt_y = ds.read_int32()
    pin.pin_shape = ds.read_uint16()
    ds.skip(2)  # unknown
    pin.port_type = ds.read_uint32()
    ds.skip(4)  # unknown
    len_sdp = ds.read_uint16()
    for _ in range(len_sdp):
        pin.display_props.append(read_symbol_display_prop(ds))
    return pin


def read_library_part(ds: DataStream) -> LibraryPart:
    prefixes, checkpoints = auto_read_prefixes(ds, STRUCT_LIBRARY_PART)
    sorted_cps = sorted(checkpoints)
    read_preamble(ds)

    lp = LibraryPart()
    lp.name = ds.read_string_len_zero_term()
    lp.source_library = ds.read_string_len_zero_term()

    ds.skip(4)  # unknown
    len_prims = ds.read_uint16()

    for _ in range(len_prims):
        prim_type = read_prim_prefix(ds)
        if prim_type == PRIM_SYMBOL_VECTOR:
            ds.pos -= 1
        prim = read_primitive(ds, prim_type)
        if prim is not None:
            lp.primitives.append(prim)

    # BBox is in the trailing data after primitives (8 bytes: x1, y1, x2, y2 as int16)
    if ds.remaining() >= 8:
        bbox = SymbolBBox()
        bbox.x1 = ds.read_int16()
        bbox.y1 = ds.read_int16()
        bbox.x2 = ds.read_int16()
        bbox.y2 = ds.read_int16()
        lp.bbox = bbox

    # Skip to the checkpoint where pins/SDPs start
    if len(sorted_cps) >= 3:
        ds.pos = sorted_cps[2]

    len_pins = ds.read_uint16()
    for _ in range(len_pins):
        if ds.peek(1) == b'\x00':
            ds.skip(1)
            continue
        lp.symbol_pins.append(read_symbol_pin(ds))

    len_sdp = ds.read_uint16()
    for _ in range(len_sdp):
        lp.display_props.append(read_symbol_display_prop(ds))

    # GeneralProperties follows SDPs (may have preamble or not)
    save = ds.pos
    read_preamble(ds)
    try:
        lp.general_properties = read_general_properties(ds)
    except (struct.error, IndexError, ValueError):
        ds.pos = save

    return lp


def read_part_cell(ds: DataStream) -> PartCell:
    prefixes, checkpoints = auto_read_prefixes(ds, STRUCT_PART_CELL)
    read_preamble(ds)
    # checkpoint 0
    pc = PartCell()
    pc.ref = ds.read_string_len_zero_term()
    _some_str = ds.read_string_len_zero_term()
    # checkpoint 1
    pc.view_number = ds.read_uint16()
    if pc.view_number == 1:
        pc.normal_name = ds.read_string_len_zero_term()
    elif pc.view_number == 2:
        pc.normal_name = ds.read_string_len_zero_term()
        pc.convert_name = ds.read_string_len_zero_term()
    else:
        raise ValueError(f"viewNumber = {pc.view_number}, expected 1 or 2")
    # checkpoint 2
    return pc


def read_device(ds: DataStream) -> Device:
    prefixes, checkpoints = auto_read_prefixes(ds, STRUCT_DEVICE)
    read_preamble(ds)
    # checkpoint 0
    dev = Device()
    dev.unit_ref = ds.read_string_len_zero_term()
    dev.ref_des = ds.read_string_len_zero_term()
    pin_count = ds.read_uint16()
    for _ in range(pin_count):
        str_len = struct.unpack_from('<h', ds.data, ds.pos)[0]
        if str_len == -1:
            ds.skip(2)
            continue
        pin_name = ds.read_string_len_zero_term()
        dev.pin_map.append(pin_name)
        pin_grp_cfg = ds.read_uint8()
        dev.pin_ignore.append(bool((pin_grp_cfg >> 7) & 1))
        dev.pin_group.append(pin_grp_cfg & 0x7F)
    # checkpoint 1
    return dev


def read_package_struct(ds: DataStream) -> Package:
    prefixes, checkpoints = auto_read_prefixes(ds, STRUCT_PACKAGE)
    read_preamble(ds)
    # checkpoint 0
    pkg = Package()
    pkg.name = ds.read_string_len_zero_term()
    pkg.source_library = ds.read_string_len_zero_term()
    # checkpoint 1
    pkg.ref_des = ds.read_string_len_zero_term()
    _unknown_str1 = ds.read_string_len_zero_term()
    pkg.pcb_footprint = ds.read_string_len_zero_term()
    len_devices = ds.read_uint16()
    for _ in range(len_devices):
        pkg.devices.append(read_device(ds))
    # checkpoint 2
    return pkg


# --- Stream parsers ---

def parse_package_stream(data: bytes) -> Package:
    """Parse a Packages/* OLE stream. Returns a Package with its PartCells and LibraryParts."""
    ds = DataStream(data)

    len_part_cells = ds.read_uint16()

    part_cells = []
    for _ in range(len_part_cells):
        pc = read_part_cell(ds)
        len_lib_parts = ds.read_uint16()
        for _ in range(len_lib_parts):
            lp = read_library_part(ds)
            pc.library_parts.append(lp)
        part_cells.append(pc)

    pkg = read_package_struct(ds)
    pkg.part_cells = part_cells

    return pkg


def parse_logfont(data: bytes, offset: int = 0) -> tuple:
    """Parse a LOGFONTA structure (60 bytes). Returns (LogFont, new_offset)."""
    lf = LogFont()
    lf.height = struct.unpack_from('<i', data, offset)[0]; offset += 4
    lf.width = struct.unpack_from('<i', data, offset)[0]; offset += 4
    lf.escapement = struct.unpack_from('<i', data, offset)[0]; offset += 4
    lf.orientation = struct.unpack_from('<i', data, offset)[0]; offset += 4
    lf.weight = struct.unpack_from('<i', data, offset)[0]; offset += 4
    lf.italic = data[offset]; offset += 1
    lf.underline = data[offset]; offset += 1
    lf.strike_out = data[offset]; offset += 1
    lf.charset = data[offset]; offset += 1
    lf.out_precision = data[offset]; offset += 1
    lf.clip_precision = data[offset]; offset += 1
    lf.quality = data[offset]; offset += 1
    lf.pitch_and_family = data[offset]; offset += 1
    face_raw = data[offset:offset + 32]
    offset += 32
    null_idx = face_raw.find(0)
    if null_idx >= 0:
        lf.face_name = face_raw[:null_idx].decode('ascii', errors='replace')
    else:
        lf.face_name = face_raw.decode('ascii', errors='replace')
    return lf, offset


def parse_library_stream(data: bytes) -> Library:
    """Parse the Library OLE stream."""
    lib = Library()

    # Introduction: zero-terminated string padded to 32 bytes
    null_idx = data.find(0, 0, 32)
    if null_idx >= 0:
        lib.introduction = data[:null_idx].decode('ascii', errors='replace')
    else:
        lib.introduction = data[:32].decode('ascii', errors='replace')
    offset = 32

    if lib.introduction.startswith("OrCAD Windows Design"):
        lib.db_type = "Design"
    elif lib.introduction.startswith("OrCAD Windows Library"):
        lib.db_type = "Library"
    else:
        lib.db_type = "Unknown"

    lib.version_major = struct.unpack_from('<H', data, offset)[0]; offset += 2
    lib.version_minor = struct.unpack_from('<H', data, offset)[0]; offset += 2
    lib.create_date = struct.unpack_from('<I', data, offset)[0]; offset += 4
    lib.modify_date = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 4  # assumed zeros

    text_font_len = struct.unpack_from('<H', data, offset)[0]; offset += 2

    for _ in range(text_font_len - 1):
        lf, offset = parse_logfont(data, offset)
        lib.text_fonts.append(lf)

    some_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
    for _ in range(some_len):
        val = struct.unpack_from('<H', data, offset)[0]; offset += 2
        lib.some_data.append(val)

    offset += 4  # unknown
    offset += 4  # unknown

    for _ in range(8):
        str_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
        s = data[offset:offset + str_len].decode('ascii', errors='replace'); offset += str_len
        if offset < len(data) and data[offset] == 0:
            offset += 1
        lib.part_field_mapping.append(s)

    # PageSettings
    ps = PageSettings()
    ps.create_date_time = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.modify_date_time = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 4 * 4  # 4 unknown u32
    ps.width = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.height = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.pin_to_pin = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 2  # unknown u16
    ps.horizontal_count = struct.unpack_from('<H', data, offset)[0]; offset += 2
    ps.vertical_count = struct.unpack_from('<H', data, offset)[0]; offset += 2
    offset += 2  # unknown u16
    ps.horizontal_width = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.vertical_width = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 4 * 12  # 12 unknown u32
    ps.horizontal_char = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 4  # unknown u32
    ps.horizontal_ascending = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.vertical_char = struct.unpack_from('<I', data, offset)[0]; offset += 4
    offset += 4  # unknown u32
    ps.vertical_ascending = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.is_metric = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.border_displayed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.border_printed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.grid_ref_displayed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.grid_ref_printed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.titleblock_displayed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.titleblock_printed = struct.unpack_from('<I', data, offset)[0]; offset += 4
    ps.ansi_grid_refs = struct.unpack_from('<I', data, offset)[0]; offset += 4
    lib.page_settings = ps

    # strLst — try u32 first, fallback to u16 if it looks wrong
    if offset + 4 <= len(data):
        str_lst_len_u32 = struct.unpack_from('<I', data, offset)[0]
        str_lst_len_u16 = struct.unpack_from('<H', data, offset)[0]
        # Heuristic: if u32 value is unreasonably large, use u16
        if str_lst_len_u32 > 10000:
            str_lst_len = str_lst_len_u16
            offset += 2
        else:
            str_lst_len = str_lst_len_u32
            offset += 4
    else:
        str_lst_len = 0

    for _ in range(str_lst_len):
        str_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
        s = data[offset:offset + str_len].decode('ascii', errors='replace'); offset += str_len
        if offset < len(data) and data[offset] == 0:
            offset += 1
        lib.str_lst.append(s)

    # aliasLst
    if offset + 2 <= len(data):
        alias_lst_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
        for _ in range(alias_lst_len):
            alias_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
            alias = data[offset:offset + alias_len].decode('ascii', errors='replace'); offset += alias_len
            if offset < len(data) and data[offset] == 0:
                offset += 1
            pkg_len = struct.unpack_from('<H', data, offset)[0]; offset += 2
            package = data[offset:offset + pkg_len].decode('ascii', errors='replace'); offset += pkg_len
            if offset < len(data) and data[offset] == 0:
                offset += 1
            lib.part_aliases.append((alias, package))

    return lib


@dataclass
class DirectoryEntry:
    name: str = ""
    type_byte: int = 0
    stream_size: int = 0
    modify_date: int = 0


def parse_directory_stream(data: bytes) -> list:
    """Parse a *Directory OLE stream. Returns list of DirectoryEntry."""
    ds = DataStream(data)
    modify_date = ds.read_uint32()
    count = ds.read_uint16()
    entries = []
    for _ in range(count):
        entry = DirectoryEntry()
        entry.modify_date = modify_date
        entry.name = ds.read_string_len_zero_term()
        entry.type_byte = ds.read_uint8()
        ds.skip(1)  # unknown
        ds.skip(16)  # two FILETIMEs
        entry.stream_size = ds.read_uint16()
        entries.append(entry)
    return entries


# --- Top-level OLB parser ---

def parse_olb(ole) -> OlbFile:
    """Parse an OLB file opened with olefile.OleFileIO. Returns OlbFile."""
    olb = OlbFile()

    # Parse Library stream
    if ole.exists('Library'):
        lib_data = ole.openstream('Library').read()
        olb.library = parse_library_stream(lib_data)

    # Get package entries from directory or OLE listing
    dir_entries = []
    if ole.exists('Packages Directory'):
        dir_data = ole.openstream('Packages Directory').read()
        dir_entries = parse_directory_stream(dir_data)
    else:
        for entry in ole.listdir():
            if len(entry) == 2 and entry[0] == 'Packages':
                de = DirectoryEntry()
                de.name = entry[1]
                dir_entries.append(de)

    # Parse each package stream
    for dir_entry in dir_entries:
        stream_path = f'Packages/{dir_entry.name}'
        if ole.exists(stream_path):
            pkg_data = ole.openstream(stream_path).read()
            try:
                pkg = parse_package_stream(pkg_data)
                pkg.timestamp = dir_entry.modify_date
                pkg.timezone = dir_entry.stream_size
                olb.packages.append(pkg)
            except Exception as e:
                import sys
                print(f"Warning: failed to parse package '{dir_entry.name}': {e}", file=sys.stderr)

    return olb
