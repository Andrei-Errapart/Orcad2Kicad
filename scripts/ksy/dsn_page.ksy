meta:
  id: dsn_page
  title: OrCAD DSN — Views/SCHEMATIC1/Pages/<page>
  endian: le
  license: CC0-1.0
  imports:
    - dsn_common

doc: |
  One schematic page of an OrCAD Capture 16.x .DSN file.

  This is the most important stream for `scripts/dsn2kicad`: it contains
  the page header, the per-page net-id↔name table, all wire segments,
  component instance placements, the pin placements that follow each
  component, power-symbol placements, and text annotations.

  Records are framed by a 4-byte marker (`FF E4 5C 39`). The bytes
  immediately after the marker start a per-record header, but there is no
  universal discriminator across all page-record families. `dsn2kicad`
  locates records by
  scanning for the marker and unpacking known offsets relative to it; this
  schema mirrors that approach.

  Coordinates are signed integers in units of 10 mils (0.254 mm). Page
  streams use a mix of int16 and int32 widths — wire endpoints are int32,
  pin placement and power-symbol coordinates are int16, component instance
  positions are int16. Y grows downward.

  Currently modeled record types:
    - page_header               (first record in the stream)
    - wire_body                 (wire segments, type 0x30)
    - net_alias_record          (net-name labels, type 0x30 with x1==0)
    - power_symbol_body         (GND/VCC instances)
    - off-page connector placements (decoded by dsn2kicad.hs from the
                                      StructGraphicInst records)
    - net_table_entry           (per-page net id ↔ name table)
    - component_instance        (component placement)
    - display_prop_record       (ref/value text-offset records that
                                 trail a component instance)
    - ref_record                (refdes for the previous component)
    - pin_placement             (pin records following a component)
    - page_text_record          (free text — titles, headings,
                                 paragraphs, table cell text)
    - page_rect_record          (decorative rectangle outlines)
    - page_line_record          (decorative line segments)
    - page_ellipse_record       (decorative ellipses / circles)
    - page_polygon_record       (filled polygons, e.g. LED triangles)

  Not yet modeled: hierarchical block references and the TitleBlock cell
  instance. Off-page connectors are not represented as a declarative type
  below yet, but their record layout and electrical hotpoint transform are
  implemented in dsn2kicad.hs.

  Graphic-primitive color: each rectangle / line / ellipse / polygon
  record (and each page_text_record) is preceded by a StructGraphicInst
  wrapper whose color is a single uint8 palette index sitting 37 bytes
  BEFORE the record marker (`marker − 37`). It indexes a fixed 48-entry
  RGBA palette (`_ORCAD_PALETTE_RGBA` in dsn2kicad_py.py); index 48 means
  "default", emitted as black.

seq:
  - id: header
    type: page_header
    doc: |
      Page-level header following the very first record marker in the
      stream. Located by `parse_page_header` in dsn2kicad.

  - id: records
    type: framed_record
    repeat: until
    repeat-until: _io.eof
    doc: |
      Marker-framed records covering wires, component instances, pin
      placements, power symbols, etc. The producer of this schema must
      handle the fact that record contents extend past the next marker —
      consumers in `dsn2kicad` re-seek to the next marker (`pos = idx + 4`)
      rather than computing record sizes.

types:

  # -------------------------------------------------------------------------
  # Header — first record after stream start (see parse_page_header)
  # -------------------------------------------------------------------------

  page_header:
    doc: |
      Page header. After the first `record_marker` and 4 zero bytes, the
      page name is a length-prefixed null-terminated string, followed by
      the paper size as another length-prefixed null-terminated string.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: page_name
        type: dsn_common::u2_prefixed_string
      - id: paper_size
        type: dsn_common::u2_prefixed_string
        doc: |
          ASCII string, one of A0..A4 or A..E.

  # -------------------------------------------------------------------------
  # Generic record envelope — marker plus record-type-dependent words
  # -------------------------------------------------------------------------

  framed_record:
    doc: |
      A record begins at the next `FF E4 5C 39` marker. The 4 bytes that
      follow the marker are record-type dependent: power-symbol and many
      display/property records use zero here, while wire records may carry
      a nonzero id/flag word. There is no single discriminator that works
      for every page record.

      Note: this schema does NOT length-prefix records; consumers should
      treat `body` as parsed up to either the next marker or EOF. In
      practice `dsn2kicad` uses `data.find(MARKER, pos+4)` to advance.
      Record-specific parsers should seek back to the marker and unpack the
      documented offsets for that record type; do not rely on the generic
      words below for dispatch.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: word0
        type: u4
        doc: |
          Bytes at marker+4. Zero for power-symbol, display-prop, and
          pin-placement records. Wire records are accepted by the converter
          without checking this word.
      - id: word1
        type: u4
        doc: Bytes at marker+8; meaning is record-type dependent.
      - id: word2
        type: u4
        doc: |
          Bytes at marker+12. For wire records this is the page-local
          net_id. For net aliases this is the label Y coordinate. For
          power-symbol records this is a header word.
      - id: word3
        type: u4
        doc: |
          Bytes at marker+16. For wire and net-alias records this is the
          literal subtype 0x30. For power-symbol records this overlaps the
          name_len field and the first bytes of the symbol name, so it is
          not a generic body kind.
      - id: body
        type: unknown_body
        doc: |
          Opaque remainder. Re-parse from the marker using one of the
          record-specific layouts below (`wire_body`, `net_alias_record`,
          `power_symbol_body`, etc.).

  # -------------------------------------------------------------------------
  # Wire record (parse_wires in dsn2kicad)
  # -------------------------------------------------------------------------

  wire_body:
    doc: |
      Layout (from `parse_wires` in dsn2kicad_py.py):
        marker(4)        FF E4 5C 39
        word0(4)         record id / flags (not decoded by dsn2kicad)
        word1(4)         record id / flags (not decoded by dsn2kicad)
        net_id(4)        at marker+12, references net table
        subtype(4)       at marker+16, == 0x30 for wires
        x1(4 signed)     at marker+20
        y1(4 signed)
        x2(4 signed)
        y2(4 signed)
      Total: 36 bytes from marker start. The `seq` below models only the
      coordinate tail starting at marker+20; the marker and header words
      are documented above because the converter unpacks them directly by
      absolute offset.
    seq:
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4

  # -------------------------------------------------------------------------
  # Net-alias label record (parse_net_aliases)
  # -------------------------------------------------------------------------

  net_alias_record:
    doc: |
      A net-name label (net alias) placed on a wire. Shares the marker and
      the `0x30` subtype with `wire_body`, but instead of valid wire
      endpoints it carries an ASCII net name, and the field at the wire's
      `x1` offset (marker+20) is **zero** — that zero is what `parse_net_aliases`
      uses to tell aliases apart from wires.

      Layout from marker (from `parse_net_aliases` in dsn2kicad_py.py):
        marker(4)          FF E4 5C 39
        zeros(4)           at marker+4
        x(4)               at marker+8   alias position X, 10-mil units
        y(4)               at marker+12  alias position Y
        subtype(4)         at marker+16, == 0x30
        zero_marker(4)     at marker+20, == 0 (distinguishes from a wire,
                           whose marker+20 holds x1)
        type(4)            at marker+24
        name_len(2)        at marker+28
        name(name_len)     at marker+30, ASCII net-alias name

      The parser canonicalises the name against the page net table
      (case-insensitive) so the label matches the net it annotates.
      The `seq` below starts at marker+8 (`x`), matching the useful
      payload offsets after the marker and zero word.
    seq:
      - id: x
        type: u4
      - id: y
        type: u4
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: zero_marker
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: prop_type
        type: u4
      - id: name
        type: dsn_common::u2_prefixed_string

  # -------------------------------------------------------------------------
  # Power symbol record (parse_power_symbols)
  # -------------------------------------------------------------------------

  power_symbol_body:
    doc: |
      Power-symbol record (GND, VCC_BAR, VCC, VCC_CIRCLE, …).
      Distinguished from wire and
      component records by:
        - the marker+4 word is 0
        - The bytes after a 4-byte rec_type and 4-byte header form a
          length-prefixed null-terminated symbol name
        - The name does NOT end with ".Normal" / ".Convert" and does not
          contain TitleBlock / Border / OFFPAGE
        - The name matches a power-net prefix (GND, VCC, VDD, …)

      Layout (from `parse_power_symbols`). The `seq` below starts at
      marker+8, after `marker(4) + zeros(4)`:
        marker(4)
        zeros(4)             at marker+4, == 0
        rec_type(4)          at marker+8
        header(4)            at marker+12, varies widely
        name_len(2)          at marker+16
        name(name_len)       at marker+18
        null(1)              at marker+18+name_len
        cell_id(4)           at name_end + 1, instance ID
        n0..n5(6 * s2)       coordinate-like fields
        orient(2)            e.g. 0x0030, 0x0130, 0x0330, 0x0430
        unknown(2)           observed gap before display-prop count
        prop_count(2)         at after_null+20, when present (<= 8)
        display_props         marker-framed SymbolDisplayProp records:
                                name_idx at marker+8
                                x/y offset at marker+12/+14
                                rot_font at marker+16
                                color at marker+18

      The six int16 fields are not direct placement coordinates, but they
      encode a derivable electrical hotpoint in the same raw page coordinate
      space as wire endpoints and component pins. Application code derives
      the hotpoint from the extracted Cache GlobalSymbol glyph anchor and the
      page instance transform. The fallback logical box is 20-by-10 with
      `n4,n5` as its origin; when an extracted Cache GlobalSymbol glyph is
      available, `_power_symbol_logical_anchor` may expand width/height to
      the glyph's primitive extents:

        GND/GND_POWER/etc.:  logical anchor (10, 0)
        VCC_BAR/VCC/CIRCLE: logical anchor (10, 10)

        rot 0: x = n4 + ax,            y = n5 + ay
        rot 1: x = n4 + ay,            y = n5 + (width - ax)
        rot 2: x = n4 + (width - ax),  y = n5 + (height - ay)
        rot 3: x = n4 + (height - ay), y = n5 + ax

      where `rot = (orient >> 8) & 3`. A hotpoint match resolves the
      connected page-local net_id and marks that net as an object-derived
      power net.

      Each VCC_BAR record is followed by a secondary marker record with
      `rec_type = 0xE0`. Observed secondary records contain small coordinates
      such as (-8, -12, 0) and extra tagged values, but no decoded net_id or
      value index. This schema does not currently model that auxiliary record.
    seq:
      - id: rec_type
        type: u4
      - id: header
        type: u4
      - id: name
        type: dsn_common::u2_prefixed_string
      - id: cell_id
        type: u4
      - id: n0
        type: s2
      - id: n1
        type: s2
      - id: n2
        type: s2
      - id: n3
        type: s2
      - id: n4
        type: s2
      - id: n5
        type: s2
      - id: orient
        type: u2

  wire_or_power_body:
    doc: |
      Historical placeholder. Wire and net-alias records have subtype
      0x30 at marker+16; power-symbol records do not. Application code
      chooses the parser by inspecting the marker-relative offsets directly
      (wire: subtype 0x30 and valid coordinates; alias: subtype 0x30 with
      marker+20 == 0 and a printable name; power: marker+4 == 0 and a
      valid power symbol name at marker+18).
    seq:
      - id: raw
        size-eos: true
        doc: Re-parse as `wire_body` or `power_symbol_body` in app logic.

  unknown_body:
    seq:
      - id: raw
        size-eos: true

  # -------------------------------------------------------------------------
  # Net name table (parse_net_table)
  # -------------------------------------------------------------------------
  #
  # The net table is preceded by the anchor bytes 30000000 05000000 03000000
  # (the last such occurrence in the stream). After the anchor:
  #   extra_count(u2) + skip_entries(extra_count * 4) + net_count(u2) + entries
  # Each entry is (length-prefixed name, null, u4 net_id).
  # Kaitai cannot easily auto-locate it; treat the entry layout as a
  # subtype the application invokes by seeking to the table offset.

  net_table_entry:
    doc: |
      Single entry in the net-id ↔ name table.
        u2  name_len
        N   name (ASCII)
        u1  null terminator (0x00)
        u4  net_id
    seq:
      - id: name
        type: dsn_common::u2_prefixed_string
      - id: net_id
        type: u4

  # -------------------------------------------------------------------------
  # Component instance + trailing pin records
  # -------------------------------------------------------------------------
  #
  # Component instances are NOT marker-framed in the same way. They are
  # located by regex-matching `CellName.Normal\0` or `CellName.Convert\0`
  # bytes in the stream and then unpacking fixed offsets after the match.
  # Pin placement records that follow ARE marker-framed.

  component_instance:
    doc: |
      Component instance, located by scanning for `CellName.{Normal,Convert}\0`.
      `cell_name` and `style` are part of the leading bytes; after the null
      terminator, the structured fields follow.

      Layout (from `parse_components` in dsn2kicad_py.py). Offsets below are
      relative to `cell_end`, the byte just past the `\0` that terminates
      `CellName.{Normal,Convert}\0`:
        cell_name (ASCII, regex: [A-Za-z0-9_./+\-()]+)
        '.'
        style    "Normal" | "Convert"
        null     (0x00)
        +0   unknown(2)
        +2   0xFF              constant
        +3   unknown(3)
        +6   x(2 signed)       component X position
        +8   y(2 signed)       component Y position
        +12  loc_x(2 signed)   StructPlacedInstance placement point X
        +14  loc_y(2 signed)   StructPlacedInstance placement point Y;
                               the ref/value display-prop offsets are
                               anchored relative to (loc_x, loc_y)
        +16  0x30              marker byte (orientation prefix, if present)
        +17  orient_byte       0x00..0x07 (see enum)
        ...  reference desig record (search forward up to 300 bytes for 0x18)
        ...  value_idx(u2)     immediately AFTER the ref string + 1 byte:
                               index into the Library value-string table
                               (see dsn_library.ksy / parse_library_value_strings),
                               resolved to the component's Value text.
      Followed first by the ref/value text-offset records
      (`display_prop_record`, the markers within ~200 bytes whose
      marker+4 word is zero and marker+8 word < 0x100), then by the
      `pin_placement` cluster.
    seq:
      - id: cell_name
        type: strz
        encoding: ASCII
        terminator: 0x2e  # '.'
        doc: Read up to the '.' that separates cell name from style.
      - id: style
        type: strz
        encoding: ASCII
        doc: '"Normal" or "Convert".'
      - id: unknown1
        size: 2
      - id: const_ff
        contents: [0xff]
      - id: unknown2
        size: 3
      - id: x
        type: s2
      - id: y
        type: s2
      - id: unknown3
        size: 2
      - id: loc_x
        type: s2
        doc: StructPlacedInstance placement point X; text-offset anchor.
      - id: loc_y
        type: s2
        doc: StructPlacedInstance placement point Y; text-offset anchor.
      - id: orient_prefix
        type: u1
        doc: 0x30 when followed by an orientation byte, else other.
      - id: orient
        type: u1
        enum: orcad_orient
        doc: |
          Orientation byte. Values 0x01/0x05 and 0x02/0x06 etc. differ in
          mirror state (suspected). The converter masks `orient & 0x03` for
          the base 0/90/180/270 rotation.
      # The reference designator record (`0x18 + u2 ref_len + ref`) follows
      # within ~300 bytes but at an unknown offset; the converter searches
      # forward for the 0x18 byte. The value_idx (u2) sits one byte past the
      # end of the ref string.

  ref_record:
    doc: |
      Reference designator record found by linear search after a
      component_instance. Layout:
        0x18
        u2 ref_len
        ref (ASCII, matching [A-Z]{1,8}\d+[A-Z]?)
    seq:
      - id: tag
        contents: [0x18]
      - id: ref_len
        type: u2
      - id: ref
        type: str
        size: ref_len
        encoding: ASCII

  display_prop_record:
    doc: |
      Ref/value text-offset record. Two of these trail each component_instance
      (one for the Reference, one for the Value); some instances store them
      reversed, so the converter classifies each by its SymbolDisplayProp
      name index rather than by position. Located by scanning the markers in
      the ~200 bytes after `cell_end` and keeping those whose marker+4 word
      is 0 and whose marker+8 word is < 0x100.

      Layout from marker (per OpenOrCadParser StructSymbolDisplayProp):
        marker(4)
        zeros(4)           at marker+4, == 0
        name_idx(4)        at marker+8, < 0x100; SymbolDisplayProp name index
                           (e.g. resolves to "Part Reference" / "Value")
        x_off(2 signed)    at marker+12, text-box top-left X offset from loc
        y_off(2 signed)    at marker+14, text-box top-left Y offset from loc
        rot_font(2)        at marker+16, packed:
                             bits 0..13  = text font index
                             bits 14..15 = rotation enum (0/1/2/3 → 0/90/180/270°)
                           Equivalently, rotation = (byte at marker+17 >> 6) & 3.

      The x_off/y_off are page-space offsets to the rendered text box's
      top-left corner; they are NOT rotated or mirrored with the component.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: name_idx
        type: u4
      - id: x_off
        type: s2
      - id: y_off
        type: s2
      - id: rot_font
        type: u2
        doc: 'bits 0..13 = font index; bits 14..15 = rotation (×90°).'

  pin_placement:
    doc: |
      Pin placement record following a component_instance (see
      `_parse_pin_records` in dsn2kicad_py.py). Marker-framed.

      The component header word at `cell_end+20` (u2 LE) is a count of
      non-pin marker records (the ref/value display-prop records and other
      metadata) that precede the contiguous pin cluster; the parser skips
      that many markers, then reads pins until the gap to the next marker
      exceeds PIN_STRIDE_MAX (= 50 bytes).

      Layout from marker:
        marker(4)
        zeros(4)          at marker+4, == 0
        pin_num(2)        at marker+8, 1-based index into the Cache pin list
        pin_x(2 signed)   at marker+10, hotpoint X in page coords (10-mil units)
        pin_y(2 signed)   at marker+12, hotpoint Y
        ...
        net_id(4)         at marker+18, page-local net id for this pin
                          (resolved against the net table when present)
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: pin_num
        type: u2
      - id: pin_x
        type: s2
      - id: pin_y
        type: s2
      - id: unknown
        size: 4
        doc: 4 bytes between pin_y and net_id; not decoded.
      - id: net_id
        type: u4
        doc: Page-local net id for the wire attached to this pin.

  # -------------------------------------------------------------------------
  # Free-text record (parse_text_annotations in dsn2kicad)
  # -------------------------------------------------------------------------

  page_text_record:
    doc: |
      Free-text annotation: titles, headings, paragraph text, table cell
      labels. Located by scanning for the type word `0x2e2e0001`
      (literal bytes `01 00 2e 2e`); fixed 42-byte header followed by
      the ASCII text payload.

      The six coordinate u32s `(p1..p6)` encode the text's bounding
      rectangle in OrCAD 10-mil units:
        (p1, p2) = bbox top-left      (cap-line, left edge)
        (p3, p4) = bbox bottom-right  (baseline, right edge)
        (p5, p6) = repeat of (p1, p2)
      The "top" is the cap-line (top of capital letters) and the
      "bottom" is the **baseline**, not the descender line —
      glyph descenders (g, p, y, j) extend below the bbox by
      ~30% of the em height when rendered.

      Long paragraphs may contain `\n` (0x0a) bytes; consumers should
      split on `\n` and distribute lines across the bbox by
      `bbox_height / line_count`.

      `parse_text_annotations` stores the text anchor as the bbox top-left
      `(p1, p2)` and preserves the full bbox. `generate_page_sch` later
      emits one KiCad text item per non-empty line, converting each row
      to a baseline-left anchor inside the preserved bbox.

      Visible labels next to some VCC_BAR power ports use this same page-text
      record format. Intersecting the text payload with the page net table can
      identify power-net names, but not all power ports have explicit text
      records; some labels are rendered implicitly by OrCAD.
    seq:
      - id: type_word
        contents: [0x01, 0x00, 0x2e, 0x2e]
        doc: |
          Discriminates page-stream text records from the Cache stream's
          text annotations (`0x2e2e` alone). The `01 00` prefix
          distinguishes them.
      - id: rec_len
        type: u4
        doc: Total record length from this point onward.
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: bbox_x1
        type: u4
        doc: Bbox top-left X (`p1`), 10-mil units.
      - id: bbox_y1
        type: u4
        doc: Bbox top-left Y (`p2`) — cap-line.
      - id: bbox_x2
        type: u4
        doc: Bbox bottom-right X (`p3`).
      - id: bbox_y2
        type: u4
        doc: Bbox bottom-right Y (`p4`) — baseline of the last line.
      - id: bbox_x1_repeat
        type: u4
        doc: Repeat of `bbox_x1` (purpose unclear).
      - id: bbox_y1_repeat
        type: u4
        doc: Repeat of `bbox_y1`.
      - id: style_id
        type: u2
        doc: |
          1-based index into the Library stream's style table.
          `library.style_records[style_id - 1]` supplies face, weight,
          italic, and escapement for this text. Previously misread as
          "font_size" — the emitted KiCad size is fitted from the page
          text bbox width/height and text metrics, not read directly from
          the Library record.
      - id: unknown
        type: u2
        doc: |
          Varies; meaning not decoded. Observed values 0, 67, 2153,
          7424, 53569, etc. Tested as a possible font-color field —
          ruled out: it's zero for both the green title and 3 of the
          4 red CAUTION paragraph lines on one cover page,
          while non-zero only for `Page` (black) and `CAUTION` (red).
          Possibly leftover bytes / noise rather than a real field.
      - id: text_len
        type: u2
      - id: text
        type: str
        size: text_len
        encoding: ASCII
        doc: |
          May contain newline `\n` (0x0a) bytes for multi-line paragraphs.

  # -------------------------------------------------------------------------
  # Page-stream decorative rectangle (parse_page_graphics in dsn2kicad)
  # -------------------------------------------------------------------------

  page_rect_record:
    doc: |
      Decorative rectangle on a schematic page (e.g. INDEX table outer
      frame, CAUTION block border). 62-byte marker-framed record.

      Color comes from the StructGraphicInst wrapper byte at `marker − 37`
      (see the top-level "Graphic-primitive color" note), NOT from any field
      inside this record. The four style words below were formerly mis-modeled
      as a single `style_index` u2; the converter now reads them as four
      separate u32 fields (`parse_page_graphics` in dsn2kicad_py.py).
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x28, 0x28, 0x28, 0x00]
        doc: '"01 00 28 28 28 00" — page-stream rectangle.'
      - id: zeros3
        size: 6
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
        enum: line_style
        doc: 'at marker+46. 0=solid, 1=dash, 2=dot, 3=dash-dot, 4=dash-dot-dot.'
      - id: line_width
        type: u4
        enum: line_width
        doc: |
          at marker+50. 0=thin(0.15mm), 1=medium(0.30mm), 2=wide(0.50mm),
          3=default(0.15mm) — see _ORCAD_LINE_WIDTH_MM in dsn2kicad_py.py.
      - id: fill_style
        type: u4
        enum: fill_style
        doc: 'at marker+54. 0=solid color fill, 1=no fill, 2=diagonal hatch.'
      - id: hatch_style
        type: s4
        enum: hatch_style
        doc: |
          at marker+58. -1=invalid, 0=horiz, 1=vert, 2=diag-left,
          3=diag-right, 4=checkerboard, 5=mesh.

  # -------------------------------------------------------------------------
  # Page-stream decorative line (parse_page_graphics in dsn2kicad)
  # -------------------------------------------------------------------------

  page_line_record:
    doc: |
      Decorative line segment on a schematic page (e.g. table dividers).
      54-byte marker-framed record. Layout identical to `page_rect_record`
      up to the coordinates, but the record ends sooner, so the rectangle's
      line/fill style words at +46.. would overlap the next record's marker.
      The converter does not read style/fill for lines; it uses a fixed
      0.15 mm width and takes the line color only from the StructGraphicInst
      wrapper byte at `marker − 37`.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x29, 0x29, 0x20, 0x00]
        doc: '"01 00 29 29 20 00" — page-stream line.'
      - id: zeros3
        size: 6
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: trailer
        size: 8

  # -------------------------------------------------------------------------
  # Page-stream decorative ellipse (parse_page_graphics in dsn2kicad)
  # -------------------------------------------------------------------------

  page_ellipse_record:
    doc: |
      Decorative ellipse or circle on a schematic page (e.g. length-matching
      bus ovals). 62-byte marker-framed record, same size as
      `page_rect_record`. The bounding box at +30 defines the axis-aligned
      rectangle circumscribing the ellipse.

      Color comes from the StructGraphicInst wrapper byte at `marker − 37`.
      `scripts/dsn2kicad` emits KiCad `(circle ...)` for equal-axis
      ellipses and a 32-segment `(polyline ...)` for true ellipses.
      The line/fill style words are read the same way as for
      `page_rect_record` (62-byte record).
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x2b, 0x2b, 0x28, 0x00]
        doc: '"01 00 2b 2b 28 00" — page-stream ellipse.'
      - id: zeros3
        size: 6
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
        enum: line_style
        doc: 'at marker+46, same encoding as page_rect_record.line_style.'
      - id: line_width
        type: u4
        enum: line_width
        doc: 'at marker+50, same encoding as page_rect_record.line_width.'
      - id: fill_style
        type: u4
        enum: fill_style
        doc: 'at marker+54, same encoding as page_rect_record.fill_style.'
      - id: hatch_style
        type: s4
        enum: hatch_style
        doc: 'at marker+58, same encoding as page_rect_record.hatch_style.'

  # -------------------------------------------------------------------------
  # Page-stream filled polygon (parse_page_graphics / _parse_page_polygon)
  # -------------------------------------------------------------------------

  page_polygon_record:
    doc: |
      Filled polygon on a schematic page. OrCAD draws small filled triangles
      (LED indicators on block-diagram pages) as polygons. Each triangle is
      typically stored as TWO records with identical vertices: a solid
      color-filled one (FillStyle 0) and a darker outline-only one
      (FillStyle 1).

      Located by the type word `01 00 2c 2c 2e 00` at marker+18.
      Layout from marker (from `_parse_page_polygon` in dsn2kicad_py.py):
        type_word          at marker+18: 01 00 2c 2c 2e 00
        fill_style(u32)    at marker+38: 0=solid color fill, 1=outline only
        vertex_count(u16)  at marker+46
        vertices           at marker+48: vertex_count × (y, x) u16 pairs

      NOTE: vertices are stored as (y, x), not (x, y) — the same swapped
      order as the Cache 0x2c2c polygon records. The first point is repeated
      to close the path (and a trailing duplicate may also appear); the
      converter collapses both. Color comes from `marker − 37`.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x2c, 0x2c, 0x2e, 0x00]
        doc: '"01 00 2c 2c 2e 00" — page-stream filled polygon.'
      - id: pre_fill
        size: 14
        doc: Bytes between the type word and fill_style (marker+24 .. marker+37).
      - id: fill_style
        type: u4
        enum: fill_style
        doc: 'at marker+38. 0=solid color fill, 1=outline only.'
      - id: between
        size: 4
        doc: marker+42 .. marker+45; not decoded.
      - id: vertex_count
        type: u2
        doc: at marker+46.
      - id: vertices
        type: yx_point
        repeat: expr
        repeat-expr: vertex_count
        doc: Vertices stored as (y, x) u16 pairs — swap to get (x, y).

  yx_point:
    doc: A polygon vertex stored y-first, then x (10-mil units).
    seq:
      - id: y
        type: u2
      - id: x
        type: u2

enums:
  # Graphic-primitive style/fill words (page_rect_record, page_ellipse_record,
  # page_polygon_record). Page line records do not carry these (record too
  # short — the fields would overlap the next marker).
  line_style:
    0: solid
    1: dash
    2: dot
    3: dash_dot
    4: dash_dot_dot

  line_width:
    0: thin       # 0.15 mm
    1: medium     # 0.30 mm
    2: wide       # 0.50 mm
    3: default    # 0.15 mm

  fill_style:
    0: solid_color   # filled with the wrapper color
    1: none          # outline only
    2: hatch         # diagonal hatch

  hatch_style:
    -1: invalid    # no hatch (fill_style != hatch)
    0: horizontal
    1: vertical
    2: diagonal_left
    3: diagonal_right
    4: checkerboard
    5: mesh

  orcad_orient:
    0x00: rot0
    0x01: rot90_a
    0x02: rot180_a
    0x03: rot270_a
    0x05: rot90_b
    0x06: rot180_b
    0x07: rot270_b
