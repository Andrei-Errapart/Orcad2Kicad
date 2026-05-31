meta:
  id: olb_package
  title: OrCAD OLB Package stream
  endian: le
  license: CC0-1.0
  imports:
    - olb_common
    - olb_primitives

doc: |
  A `Packages/<name>` OLE stream inside an OrCAD .OLB file.

  Each package stream contains a flat sequence of part cells (each
  with nested library parts holding the symbol graphics and pins),
  followed by the package metadata structure.

  The format uses a prefix/checkpoint/preamble framework:
  - **Prefixes** encode checkpoint offsets into the following data.
    The number of prefixes is fixed per structure type (see below).
  - **Preambles** (FF E4 5C 39 + length + data) appear after prefix
    blocks and after each graphic primitive.
  - **Checkpoints** are positions in the data where specific fields
    start; the parser can jump to them to skip unknown regions.

  Empirically determined prefix counts:
    0x06 (PartCell):         3 full + 1 short = 4 prefixes
    0x18 (LibraryPart):      variable (typically 4-6)
    0x1A (SymbolPinScalar):  2 full + 1 short = 3 prefixes
    0x1B (SymbolPinBus):     2 full + 1 short = 3 prefixes
    0x1F (Package):          3 full + 1 short = 4 prefixes
    0x20 (Device):           2 full + 1 short = 3 prefixes
    0x27 (SymbolDisplayProp): 1 full + 1 short = 2 prefixes

  Kaitai limitations:
  - LibraryPart prefix count is not fixed; described here with the
    most common count (5).  Files with a different count will fail.
  - The checkpoint-jump after primitives (to skip unknown trailing
    bytes before pins) is modeled as reading fields sequentially;
    this may fail if unknown gaps exist between primitives and pins.
  - The optional preamble before GeneralProperties cannot be probed
    without lookahead; it is modeled as mandatory.

seq:
  - id: part_cell_count
    type: u2
  - id: part_cells
    type: part_cell_with_parts
    repeat: expr
    repeat-expr: part_cell_count
  - id: package
    type: package_struct

types:

  # --- Prefix blocks (fixed counts per structure type) ---

  prefix_block_2:
    seq:
      - id: p0
        type: full_prefix
      - id: last
        type: short_prefix

  prefix_block_3:
    seq:
      - id: p0
        type: full_prefix
      - id: p1
        type: full_prefix
      - id: last
        type: short_prefix

  prefix_block_4:
    seq:
      - id: p0
        type: full_prefix
      - id: p1
        type: full_prefix
      - id: p2
        type: full_prefix
      - id: last
        type: short_prefix

  prefix_block_5:
    seq:
      - id: p0
        type: full_prefix
      - id: p1
        type: full_prefix
      - id: p2
        type: full_prefix
      - id: p3
        type: full_prefix
      - id: last
        type: short_prefix

  # --- Top-level structures ---

  part_cell_with_parts:
    doc: A PartCell followed by its LibraryParts.
    seq:
      - id: part_cell
        type: part_cell
      - id: library_part_count
        type: u2
      - id: library_parts
        type: library_part
        repeat: expr
        repeat-expr: library_part_count

  part_cell:
    doc: |
      PartCell (type 0x06): a view reference within a package.
      Contains a ref string, view number, and 1-2 view name strings
      (Normal and optionally Convert).
    seq:
      - id: prefixes
        type: prefix_block_4
      - id: preamble
        type: preamble
      - id: ref
        type: len_string
      - id: unknown_str
        type: len_string
      - id: view_number
        type: u2
        doc: 1 = Normal only, 2 = Normal + Convert.
      - id: normal_name
        type: len_string
      - id: convert_name
        type: len_string
        if: view_number == 2

  library_part:
    doc: |
      LibraryPart (type 0x18): a symbol view (Normal or Convert)
      containing graphic primitives, pins, display properties,
      bounding box, and general properties.

      The prefix count for LibraryPart varies across files.
      This schema assumes 5 prefixes (4 full + 1 short), which is
      the most common.  Files with a different count will not parse.
    seq:
      - id: prefixes
        type: prefix_block_5
      - id: preamble
        type: preamble
      - id: name
        type: len_string
      - id: source_library
        type: len_string
      - id: unknown_4
        size: 4
      - id: primitive_count
        type: u2
      - id: primitives
        type: primitive_entry
        repeat: expr
        repeat-expr: primitive_count
      - id: bbox
        type: symbol_bbox
      - id: pin_count
        type: u2
      - id: pins
        type: pin_or_skip
        repeat: expr
        repeat-expr: pin_count
      - id: display_prop_count
        type: u2
      - id: display_props
        type: symbol_display_prop
        repeat: expr
        repeat-expr: display_prop_count
      - id: gp_preamble
        type: preamble
      - id: general_properties
        type: general_properties

  primitive_entry:
    doc: |
      A graphic primitive prefixed by a 2-byte type tag where both
      bytes must be identical.  The body is dispatched by type.
    seq:
      - id: type_byte_1
        type: u1
      - id: type_byte_2
        type: u1
        if: type_byte_1 != 0x30
      - id: body
        type:
          switch-on: type_byte_1
          cases:
            0x28: prim_rect
            0x29: prim_line
            0x2a: prim_arc
            0x2b: prim_ellipse
            0x2c: prim_polygon
            0x2d: prim_polyline
            0x2e: prim_comment_text
            0x2f: prim_bitmap
            0x57: prim_bezier

  symbol_bbox:
    doc: Symbol bounding box (4x s2) plus 4 unknown bytes.
    seq:
      - id: x1
        type: s2
      - id: y1
        type: s2
      - id: x2
        type: s2
      - id: y2
        type: s2
      - id: unknown
        size: 4

  pin_or_skip:
    doc: |
      Either a SymbolPin or a null-byte separator.
      If the first byte is 0x00, the entry is a skip marker.
    seq:
      - id: first_byte
        type: u1
      - id: pin
        type: symbol_pin_rest
        if: first_byte != 0

  symbol_pin_rest:
    doc: |
      SymbolPin body (type 0x1A or 0x1B), minus the first prefix
      type_byte which was already consumed by pin_or_skip.

      The full prefix block for a pin is 3 entries (2 full + 1 short).
      Since the first type_byte was already consumed, we read the
      remaining prefix bytes then the pin data.
    seq:
      - id: p0_offset
        type: u4
      - id: p0_unknown
        size: 4
      - id: p1
        type: full_prefix
      - id: last
        type: short_prefix
      - id: preamble
        type: preamble
      - id: name
        type: len_string
      - id: start_x
        type: s4
      - id: start_y
        type: s4
      - id: hotpt_x
        type: s4
      - id: hotpt_y
        type: s4
      - id: pin_shape
        type: u2
      - id: unknown_u16
        type: u2
      - id: port_type
        type: u4
      - id: unknown_4
        size: 4
      - id: sdp_count
        type: u2
      - id: display_props
        type: symbol_display_prop
        repeat: expr
        repeat-expr: sdp_count

  symbol_display_prop:
    doc: |
      SymbolDisplayProp (type 0x27): a property display descriptor
      specifying position, font, rotation, and display style.
    seq:
      - id: prefixes
        type: prefix_block_2
      - id: preamble
        type: preamble
      - id: name_idx
        type: u4
        doc: Index into the Library string list.
      - id: x
        type: s2
      - id: y
        type: s2
      - id: rot_font
        type: u2
        doc: |
          Packed field: bits 0-13 = text_font_idx,
          bits 14-15 = rotation (0=0, 1=90, 2=180, 3=270).
      - id: prop_color
        type: u1
      - id: disp_flags
        type: u1
      - id: disp_type
        type: u1
      - id: unknown_u8
        type: u1
    instances:
      text_font_idx:
        value: rot_font & 0x3FFF
      rotation:
        value: (rot_font >> 14) & 0x03

  general_properties:
    doc: |
      GeneralProperties: implementation info, ref des template,
      part value, and pin visibility flags.
    seq:
      - id: implementation_path
        type: len_string
      - id: implementation
        type: len_string
      - id: ref_des
        type: len_string
      - id: part_value
        type: len_string
      - id: properties_byte
        type: u1
        doc: |
          Packed flags:
            bit 0: pin_name_visible
            bit 1: pin_name_rotate
            bit 2: pin_number_hidden (inverted: 0 = visible)
            bits 3-5: implementation_type
      - id: unknown_u8
        type: u1
    instances:
      pin_name_visible:
        value: (properties_byte & 0x01) != 0
      pin_name_rotate:
        value: (properties_byte & 0x02) != 0
      pin_number_visible:
        value: (properties_byte & 0x04) == 0
      implementation_type:
        value: (properties_byte >> 3) & 0x07

  package_struct:
    doc: |
      Package (type 0x1F): top-level package metadata with
      ref des, footprint, and device pin mappings.
    seq:
      - id: prefixes
        type: prefix_block_4
      - id: preamble
        type: preamble
      - id: name
        type: len_string
      - id: source_library
        type: len_string
      - id: ref_des
        type: len_string
      - id: unknown_str
        type: len_string
      - id: pcb_footprint
        type: len_string
      - id: device_count
        type: u2
      - id: devices
        type: device
        repeat: expr
        repeat-expr: device_count

  device:
    doc: |
      Device (type 0x20): a unit within a multi-unit package,
      containing the pin-name-to-number mapping.
    seq:
      - id: prefixes
        type: prefix_block_3
      - id: preamble
        type: preamble
      - id: unit_ref
        type: len_string
      - id: ref_des
        type: len_string
      - id: pin_count
        type: u2
      - id: pins
        type: device_pin
        repeat: expr
        repeat-expr: pin_count

  device_pin:
    doc: |
      A pin entry inside a Device.  A length of -1 (0xFFFF as s2)
      means the pin slot is empty (unused).
    seq:
      - id: name_len_raw
        type: s2
      - id: name
        type: str
        size: name_len_raw
        encoding: ASCII
        if: name_len_raw >= 0
      - id: name_term
        contents: [0x00]
        if: name_len_raw >= 0
      - id: pin_grp_cfg
        type: u1
        if: name_len_raw >= 0
        doc: |
          bit 7: pin_ignore flag.
          bits 0-6: pin_group number.
