meta:
  id: olb_primitives
  title: OrCAD OLB graphic primitive records
  endian: le
  license: CC0-1.0
  imports:
    - olb_common

doc: |
  Graphic primitives used inside LibraryPart symbol definitions.

  Each primitive begins with a 2-byte prefix where both bytes are
  identical and encode the primitive type.  The body starts with a
  u4 byte_length (total size including itself), 4 zero bytes, then
  type-specific fields.  After the body, a preamble (FF E4 5C 39)
  follows.

  For variable-geometry primitives (polyline, polygon, bezier), the
  presence of optional style fields is determined from byte_length:
    Version A (no style):  byte_length = 10 + 4*point_count
    Version B (with style): byte_length = 18 + 4*point_count
    Version C (style+fill): byte_length = 26 + 4*point_count (polygon only)

  Primitive type codes:
    0x28 = rectangle    0x2C = polygon
    0x29 = line          0x2D = polyline
    0x2A = arc           0x2E = comment_text
    0x2B = ellipse       0x2F = bitmap
    0x30 = symbol_vector 0x57 = bezier

types:

  prim_prefix:
    doc: |
      Two identical bytes identifying the primitive type.
      Exception: type 0x30 (symbol_vector) consumes only 1 byte
      and the second byte belongs to the body.
    seq:
      - id: type_byte
        type: u1
      - id: type_check
        type: u1

  prim_line:
    doc: |
      Line segment.  byte_length >= 24 for coords only,
      >= 32 includes line_style and line_width.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: line_style
        type: u4
        if: byte_length >= 32
      - id: line_width
        type: u4
        if: byte_length >= 32
      - id: trailing
        size: "byte_length > 32 ? byte_length - 32 : (byte_length > 24 ? byte_length - 24 : 0)"
      - id: preamble
        type: preamble

  prim_rect:
    doc: |
      Rectangle.  byte_length >= 24 for coords,
      >= 32 includes style, >= 40 includes fill.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: line_style
        type: u4
        if: byte_length >= 32
      - id: line_width
        type: u4
        if: byte_length >= 32
      - id: fill_style
        type: u4
        if: byte_length >= 40
      - id: hatch_style
        type: s4
        if: byte_length >= 40
      - id: trailing
        size: "byte_length > 40 ? byte_length - 40 : 0"
      - id: preamble
        type: preamble

  prim_arc:
    doc: |
      Arc defined by bounding rectangle + start/end points.
      byte_length >= 40 for coords, >= 48 includes style.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: start_x
        type: s4
      - id: start_y
        type: s4
      - id: end_x
        type: s4
      - id: end_y
        type: s4
      - id: line_style
        type: u4
        if: byte_length >= 48
      - id: line_width
        type: u4
        if: byte_length >= 48
      - id: trailing
        size: "byte_length > 48 ? byte_length - 48 : 0"
      - id: preamble
        type: preamble

  prim_ellipse:
    doc: |
      Ellipse defined by bounding rectangle.
      Same field layout as prim_rect.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: line_style
        type: u4
        if: byte_length >= 32
      - id: line_width
        type: u4
        if: byte_length >= 32
      - id: fill_style
        type: u4
        if: byte_length >= 40
      - id: hatch_style
        type: s4
        if: byte_length >= 40
      - id: trailing
        size: "byte_length > 40 ? byte_length - 40 : 0"
      - id: preamble
        type: preamble

  prim_polyline:
    doc: |
      Polyline (open path).  Style fields are optional:
        No style:  byte_length = 10 + 4*point_count
        With style: byte_length = 18 + 4*point_count
      Detection: has_style when (byte_length - 8 - 10) % 4 == 0 and
      the resulting point count >= 2.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: line_style
        type: u4
        if: has_style
      - id: line_width
        type: u4
        if: has_style
      - id: point_count
        type: u2
      - id: points
        type: point_yx
        repeat: expr
        repeat-expr: point_count
      - id: trailing
        size: byte_length - 8 - (has_style ? 8 : 0) - 2 - point_count * 4
        if: byte_length - 8 - (has_style ? 8 : 0) - 2 - point_count * 4 > 0
      - id: preamble
        type: preamble
    instances:
      remaining:
        value: byte_length - 8
      has_style:
        value: remaining >= 10 and (remaining - 10) % 4 == 0

  prim_polygon:
    doc: |
      Polygon (closed path).  Three versions:
        A (no style):      byte_length = 10 + 4*point_count
        B (style only):    byte_length = 18 + 4*point_count
        C (style + fill):  byte_length = 26 + 4*point_count
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: line_style
        type: u4
        if: has_style
      - id: line_width
        type: u4
        if: has_style
      - id: fill_style
        type: u4
        if: has_fill
      - id: hatch_style
        type: s4
        if: has_fill
      - id: point_count
        type: u2
      - id: points
        type: point_yx
        repeat: expr
        repeat-expr: point_count
      - id: trailing
        size: byte_length - 8 - (has_fill ? 16 : (has_style ? 8 : 0)) - 2 - point_count * 4
        if: byte_length - 8 - (has_fill ? 16 : (has_style ? 8 : 0)) - 2 - point_count * 4 > 0
      - id: preamble
        type: preamble
    instances:
      remaining:
        value: byte_length - 8
      has_fill:
        value: remaining >= 18 and (remaining - 18) % 4 == 0
      has_style:
        value: has_fill or (remaining >= 10 and (remaining - 10) % 4 == 0)

  prim_bezier:
    doc: |
      Bezier curve.  Same version detection as prim_polyline.
      Points come in groups of 4 (cubic bezier segments).
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: line_style
        type: u4
        if: has_style
      - id: line_width
        type: u4
        if: has_style
      - id: point_count
        type: u2
      - id: points
        type: point_yx
        repeat: expr
        repeat-expr: point_count
      - id: trailing
        size: byte_length - 8 - (has_style ? 8 : 0) - 2 - point_count * 4
        if: byte_length - 8 - (has_style ? 8 : 0) - 2 - point_count * 4 > 0
      - id: preamble
        type: preamble
    instances:
      remaining:
        value: byte_length - 8
      has_style:
        value: remaining >= 10 and (remaining - 10) % 4 == 0

  prim_comment_text:
    doc: |
      Text annotation inside a symbol.
      Note: byte_length in the file is 8 less than the total record
      size (the C++ parser adds 8 to account for the byte_length and
      zeros fields themselves).
    seq:
      - id: byte_length_raw
        type: u4
      - id: zeros
        size: 4
      - id: loc_x
        type: s4
      - id: loc_y
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: text_font_idx
        type: u2
      - id: unknown
        size: 2
      - id: name
        type: len_string
      - id: trailing
        size: (byte_length_raw + 8) - (_io.pos - _start)
        if: (byte_length_raw + 8) - (_io.pos - _start) > 0
      - id: preamble
        type: preamble
    instances:
      _start:
        value: _io.pos - byte_length_raw - 8

  prim_bitmap:
    doc: Embedded bitmap image.
    seq:
      - id: byte_length
        type: u4
      - id: zeros
        size: 4
      - id: loc_x
        type: s4
      - id: loc_y
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: bmp_width
        type: u4
      - id: bmp_height
        type: u4
      - id: data_size
        type: u4
      - id: raw_img_data
        size: data_size
      - id: trailing
        size: byte_length - 44 - data_size
        if: byte_length - 44 - data_size > 0
      - id: preamble
        type: preamble
