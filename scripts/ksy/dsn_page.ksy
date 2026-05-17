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

  Records are framed by a 4-byte marker (`FF E4 5C 39`). The byte
  immediately after the marker is the start of a per-record header whose
  type discriminator varies by record. `dsn2kicad` locates records by
  scanning for the marker and unpacking known offsets relative to it; this
  schema mirrors that approach.

  Coordinates are signed integers in units of 10 mils (0.254 mm). Page
  streams use a mix of int16 and int32 widths — wire endpoints are int32,
  pin placement and power-symbol coordinates are int16, component instance
  positions are int16. Y grows downward.

  Currently modeled record types:
    - page_header               (first record in the stream)
    - wire_body                 (wire segments, type 0x30)
    - power_symbol_body         (GND/VCC instances)
    - net_table_entry           (per-page net id ↔ name table)
    - component_instance        (component placement)
    - ref_record                (refdes for the previous component)
    - pin_placement             (pin records following a component)
    - page_text_record          (free text — titles, headings,
                                 paragraphs, table cell text)
    - page_rect_record          (decorative rectangle outlines)
    - page_line_record          (decorative line segments)
    - page_ellipse_record       (decorative ellipses / circles)

  Not yet modeled: hierarchical block references, off-page connectors,
  the TitleBlock cell instance, attribute properties.

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
  # Generic record envelope — discriminates on the byte/word after marker
  # -------------------------------------------------------------------------

  framed_record:
    doc: |
      A record begins at the next `FF E4 5C 39` marker. The 4 bytes that
      follow the marker are typically zero (for the "real" structured
      records used by dsn2kicad). After those 4 bytes, a per-record-type
      discriminator follows.

      Note: this schema does NOT length-prefix records; consumers should
      treat `body` as parsed up to either the next marker or EOF. In
      practice `dsn2kicad` uses `data.find(MARKER, pos+4)` to advance.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: tag
        type: u4
        doc: |
          Four bytes after the marker. For wire and power-symbol records
          this is zero; for some non-zero values, the record is something
          else (continuation, graphics, attributes — not modeled).
      - id: discriminator
        type: u4
        doc: |
          Reading the value at +12 (= marker + 8 after `tag`) which is used
          by dsn2kicad as the record kind:
            - wire records have `body_discriminator == 0x30` (at marker+16)
          The actual discriminator location is record-type dependent; this
          field is a heuristic anchor.
      - id: body_kind
        type: u4
        doc: |
          For wire records this is the literal value 0x30 found at offset
          +16 from the marker. Other record types put different values
          here. dsn2kicad branches on this.
      - id: body
        type:
          switch-on: body_kind
          cases:
            0x30: wire_or_power_body
            _: unknown_body
        doc: |
          Discriminated body. 0x30 covers both wire segments and power
          symbols (the converter splits them by inspecting subsequent
          bytes: wires have nonzero `tag`, power symbols have zero `tag`
          and a printable name immediately after).

  # -------------------------------------------------------------------------
  # Wire record (parse_wires in dsn2kicad)
  # -------------------------------------------------------------------------

  wire_body:
    doc: |
      Layout (from `parse_wires`, dsn2kicad lines 197–224):
        marker(4)        FF E4 5C 39
        zeros(4)         (4 zero bytes — note: 'zeros' here is not the same
                         field as in power records; consumers treat tag!=0
                         as a wire indicator)
        record_id(4)     unique record id (at marker+4)  [Kaitai: tag]
        net_id(4)        at marker+12, references net table
        subtype(4)       at marker+16, == 0x30 for wires
        x1(4 signed)     at marker+20
        y1(4 signed)
        x2(4 signed)
        y2(4 signed)
      Total: 36 bytes from marker start.
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
  # Power symbol record (parse_power_symbols)
  # -------------------------------------------------------------------------

  power_symbol_body:
    doc: |
      Power-symbol record (GND, VCC_BAR, …). Distinguished from wire and
      component records by:
        - `tag` (4 bytes after marker) is 0
        - The bytes after a 4-byte rec_type and 4-byte header form a
          length-prefixed null-terminated symbol name
        - The name does NOT end with ".Normal" / ".Convert" and does not
          contain TitleBlock / Border / OFFPAGE
        - The name matches a power-net prefix (GND, VCC, VDD, …)

      Layout (from `parse_power_symbols`, dsn2kicad lines 326–371):
        marker(4)
        zeros(4)             at marker+4, == 0
        rec_type(4)          at marker+8
        header(4)            at marker+12, varies widely
        name_len(2)          at marker+16
        name(name_len)       at marker+18
        null(1)              at marker+18+name_len
        cell_id(4)           at name_end + 1
        x(2 signed)          at name_end + 1 + 4
        y(2 signed)          at name_end + 1 + 6

      **CAVEAT**: empirical testing shows these (x, y) values do NOT
      land on any wire endpoint of the matching net. The bbox at
      `+4..+11` (10×20 OrCAD units for GND, 22×65/72 for VCC_BAR)
      matches the dimensions of the **caption text label** drawn
      next to the glyph, not the glyph anchor itself. The actual
      GND / VCC glyph is rendered by OrCAD implicitly at the wire
      endpoint when the net is a power net. `scripts/dsn2kicad`
      therefore ignores these records as a source of glyph
      positions and synthesizes glyphs at dangling power-net wire
      endpoints (filtered against component pin positions to avoid
      stacking a glyph at every pin of a multi-pin connector
      whose pins each emit a "free" wire stub).
    seq:
      - id: rec_type
        type: u4
      - id: header
        type: u4
      - id: name
        type: dsn_common::u2_prefixed_string
      - id: cell_id
        type: u4
      - id: x
        type: s2
      - id: y
        type: s2

  wire_or_power_body:
    doc: |
      Both wires and power symbols share `body_kind == 0x30`. Application
      code must choose between them after inspecting the `tag` field of
      the enclosing record (wire: nonzero; power: zero followed by a
      valid name). This schema models them as alternatives; pick one in
      post-processing.
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

      Layout (from `parse_components`, dsn2kicad lines 251–323):
        cell_name (ASCII, regex: [A-Za-z0-9_./+\-()]+)
        '.'
        style    "Normal" | "Convert"
        null     (0x00)
        +0   unknown(2)
        +2   0xFF              constant
        +3   unknown(3)
        +6   x(2 signed)       component X position
        +8   y(2 signed)       component Y position
        +10  unknown(6)
        +16  0x30              marker byte (orientation prefix, if present)
        +17  orient_byte       0x00..0x07 (see enum)
        ...  reference desig record (search forward up to 300 bytes for 0x18)
      Followed by pin placement records starting near cell_end+100.
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
        size: 6
      - id: orient_prefix
        type: u1
        doc: 0x30 when followed by an orientation byte, else other.
      - id: orient
        type: u1
        enum: orcad_orient
        doc: |
          Orientation byte. Values 0x01/0x05 and 0x02/0x06 etc. differ in
          mirror state (suspected).
      # The reference designator record (`0x18 + u2 ref_len + ref`) follows
      # within ~300 bytes but at an unknown offset; the converter searches
      # forward for the 0x18 byte.

  ref_record:
    doc: |
      Reference designator record found by linear search after a
      component_instance. Layout:
        0x18
        u2 ref_len
        ref (ASCII, matching [A-Z]{1,3}\d+[A-Z]?)
    seq:
      - id: tag
        contents: [0x18]
      - id: ref_len
        type: u2
      - id: ref
        type: str
        size: ref_len
        encoding: ASCII

  pin_placement:
    doc: |
      Pin placement record following a component_instance (see
      `_parse_pin_records`, dsn2kicad lines 227–248). Marker-framed.

      Layout from marker:
        marker(4)
        zeros(4)
        pin_num(2)        1-based index into the Cache pin list for the cell
        pin_x(2 signed)   hotpoint X in page-stream coordinates (10-mil units)
        pin_y(2 signed)   hotpoint Y
      Total: 18 bytes; spacing observed at ~45 bytes between records.
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
          `library.style_records[style_id - 1]` is the font/weight/
          italic record for this text. Previously misread as
          "font_size" — the rendered point size comes from the
          `bbox` height in the page-stream record itself (not from
          the Library record).
      - id: unknown
        type: u2
        doc: |
          Varies; meaning not decoded. Observed values 0, 67, 2153,
          7424, 53569, etc. Tested as a possible font-color field —
          ruled out: it's zero for both the green title and 3 of the
          4 red CAUTION paragraph lines on the microSD cover page,
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
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x28, 0x28, 0x28, 0x00]
        doc: '"01 00 28 28 28 00" — page-stream rectangle.'
      - id: zeros3
        size: 6
      - id: x1
        type: u4
      - id: y1
        type: u4
      - id: x2
        type: u4
      - id: y2
        type: u4
      - id: zeros4
        size: 4
      - id: style_index
        type: u2
        enum: page_graphic_style
        doc: |
          Style index. Observed values 0 and 1, which OrCAD renders as:
            0 = black, thin   (0.36 pt stroke)
            1 = red,   thick  (1.08 pt stroke)
          The byte's role is not 100% clear — earlier guesses included
          "color" and "emphasis flag". It is NOT an index into the
          Library stream's style records (those are all font entries),
          but may index an implicit OrCAD-side rendering palette that
          couples color and stroke width together.
      - id: trailer
        size: 8

  # -------------------------------------------------------------------------
  # Page-stream decorative line (parse_page_graphics in dsn2kicad)
  # -------------------------------------------------------------------------

  page_line_record:
    doc: |
      Decorative line segment on a schematic page (e.g. table dividers).
      54-byte marker-framed record. Layout identical to
      `page_rect_record` up to the coordinates, but the record ends
      sooner so the color flag at the rectangle's +50 offset overlaps
      the next record's marker — line colors are not reliably
      extractable from this offset and `dsn2kicad` treats all lines as
      black.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x29, 0x29, 0x20, 0x00]
        doc: '"01 00 29 29 20 00" — page-stream line.'
      - id: zeros3
        size: 6
      - id: x1
        type: u4
      - id: y1
        type: u4
      - id: x2
        type: u4
      - id: y2
        type: u4
      - id: trailer
        size: 4

  # -------------------------------------------------------------------------
  # Page-stream decorative ellipse (parse_page_graphics in dsn2kicad)
  # -------------------------------------------------------------------------

  page_ellipse_record:
    doc: |
      Decorative ellipse or circle on a schematic page (e.g. length-matching
      bus ovals). 62-byte marker-framed record, same size as
      `page_rect_record`. The bounding box at +30 defines the axis-aligned
      rectangle circumscribing the ellipse.

      OrCAD renders these in green, but the color is not stored in the
      DSN — it comes from OrCAD's implicit rendering palette.
      `scripts/dsn2kicad` emits KiCad `(circle ...)` for equal-axis
      ellipses and a 32-segment `(polyline ...)` for true ellipses.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        size: 8
      - id: subtype
        contents: [0x30, 0x00]
      - id: zeros2
        size: 2
      - id: type_word
        contents: [0x01, 0x00, 0x2b, 0x2b, 0x28, 0x00]
        doc: '"01 00 2b 2b 28 00" — page-stream ellipse.'
      - id: zeros3
        size: 6
      - id: x1
        type: u4
      - id: y1
        type: u4
      - id: x2
        type: u4
      - id: y2
        type: u4
      - id: zeros4
        size: 4
      - id: style_index
        type: u2
        enum: page_graphic_style
        doc: |
          Style index, same encoding as `page_rect_record.style_index`.
          Always 0 in observed data.
      - id: trailer
        size: 8

enums:
  page_graphic_style:
    0: normal     # rendered black, thin (0.36 pt)
    1: emphasis   # rendered red, thick  (1.08 pt)

  orcad_orient:
    0x00: rot0
    0x01: rot90_a
    0x02: rot180_a
    0x03: rot270_a
    0x05: rot90_b
    0x06: rot180_b
    0x07: rot270_b
