meta:
  id: dsn_cache
  title: OrCAD DSN — Cache stream
  endian: le
  license: CC0-1.0
  imports:
    - dsn_common

doc: |
  The `Cache` stream of an OrCAD Capture .DSN file. Contains the cached
  cell/symbol definitions imported from .OLB libraries, including:
    - body rectangle
    - graphic primitives (text annotations, bounding box)
    - pin records (name, body endpoint, hotpoint endpoint)

  Cell organisation: each cell name appears three times as
  `CellName.Normal\0` (or `.Convert\0`). The second occurrence carries
  the body rect, graphic primitives, and pin records. The first is a
  header (no pins) and the third is a library back-reference (no pins).

  As with page streams, records are located by scanning for the marker
  `FF E4 5C 39`; this schema cannot strictly auto-traverse the stream
  because there is no length field. The types below describe what the
  scanner finds at each marker. Coordinates are int32 LE in 10-mil units.

seq:
  - id: data
    size-eos: true
    doc: |
      Treat as a byte blob; locate cells via regex on
      `[A-Za-z0-9_./+\-()]+\.(Normal|Convert)\0` and then use the types
      below to parse the regions between consecutive cell-name matches.

types:

  # -------------------------------------------------------------------------
  # Body rectangle (second occurrence, after OLB path)
  # -------------------------------------------------------------------------

  body_rect_record:
    doc: |
      Container wrapper (subtype 0x30) for the first body graphic of a cell.
      Written immediately after the OLB path string of the second occurrence.
      Layout:
        subtype(4)    == 0x30
        unknown(2)
        type_word(2)  == 0x2828 (rectangle) or 0x2b2b (ellipse)
        unknown(8)
        x1(4 signed)                   bounding box corner 1
        y1(4 signed)
        x2(4 signed)                   bounding box corner 2
        y2(4 signed)
      Total: 32 bytes from subtype start.

      When type_word is 0x2828, the bbox defines the body rectangle.
      When type_word is 0x2b2b, it defines the inscribed ellipse/circle.
    seq:
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: unknown1
        size: 2
      - id: type_word
        type: u2
        doc: |
          0x2828 = body rectangle, 0x2b2b = ellipse/circle.
      - id: unknown2
        size: 8
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4

  # -------------------------------------------------------------------------
  # Text annotation record (graphic primitive)
  # -------------------------------------------------------------------------

  text_annotation_record:
    doc: |
      Internal text annotation drawn inside the symbol body. Type word
      `0x2e2e`.

      Carries a short ASCII label (typically a single character) along
      with a text-bounding rectangle and an anchor point. 

      Layout from marker:
        marker(4)              FF E4 5C 39
        zeros(4)
        type_word(2)           == 0x2e2e
        subtype(1)             == 0x28
        zeros(1)
        zeros(4)
        bbox_x1(4 signed)      text bounding rectangle, top-left
        bbox_y1(4 signed)
        bbox_x2(4 signed)      bottom-right
        bbox_y2(4 signed)
        anchor_x(4 signed)     anchor point, usually = (bbox_x1, bbox_y1)
        anchor_y(4 signed)
        flag_word(4)           varies (e.g. 0x00000003 or 0x00000008)
        text_len(2)            1..4 ASCII bytes
        text(text_len)
        null(1)

      The bbox is typically ~8×9 OrCAD units (~2.0×2.3 mm), i.e. one
      glyph cell.

      The third coordinate pair —
      a near-duplicate of the first — is actually the text anchor and
      is what gives the giveaway. The trailing bytes carry the embedded
      ASCII character. See doc/ORCAD_DSN_FILES.md for the corrected
      interpretation.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros1
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: type_word
        contents: [0x2e, 0x2e]
      - id: subtype
        type: u1
        doc: Observed 0x28.
      - id: unknown1
        size: 1
      - id: zeros2
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: bbox_x1
        type: s4
      - id: bbox_y1
        type: s4
      - id: bbox_x2
        type: s4
      - id: bbox_y2
        type: s4
      - id: anchor_x
        type: s4
      - id: anchor_y
        type: s4
      - id: flag_word
        type: u4
        doc: |
          Per-annotation flags. Observed values 0x00000003 and
          0x00000008 in the same cell; meaning not yet decoded.
      - id: text_len
        type: u2
      - id: text
        type: str
        size: text_len
        encoding: ASCII
      - id: terminator
        contents: [0x00]

  # -------------------------------------------------------------------------
  # Outer / secondary body rectangle (graphic primitive)
  # -------------------------------------------------------------------------

  body_rect_record_outer:
    doc: |
      Second body rectangle for cells with composite outlines. Type
      bytes `28 28 28` at offset 0 from the marker tail; bbox at
      offset 10 as int32 LE × 4. Total record length ~42 bytes.

      `dsn2kicad` emits this as an additional KiCad `(rectangle ...)`
      primitive on the symbol's `_0_1` sub-symbol.

      The geometry is interpreted as the cell's outer body outline.
    seq:
      - id: type_bytes
        contents: [0x28, 0x28, 0x28]
      - id: unknown
        size: 7
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4
      - id: trailer
        size: 12
        doc: Remaining bytes of the 42-byte record.

  # -------------------------------------------------------------------------
  # Line segment record (graphic primitive)
  # -------------------------------------------------------------------------

  line_segment_record:
    doc: |
      Standalone line segment forming part of the symbol body graphic.
      Type word `0x2929`. Same layout as `ellipse_record` — only the
      type word differs.

      Layout from marker:
        marker(4)              FF E4 5C 39
        zeros(4)
        type_word(2)           == 0x2929
        unknown(8)
        x1(4 signed)           start X
        y1(4 signed)           start Y
        x2(4 signed)           end X
        y2(4 signed)           end Y
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: type_word
        contents: [0x29, 0x29]
      - id: unknown
        size: 8
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4

  # -------------------------------------------------------------------------
  # Ellipse / circle record (graphic primitive)
  # -------------------------------------------------------------------------

  ellipse_record:
    doc: |
      Ellipse or circle bounding box. Type word `0x2b2b`. When both axes
      are equal it is a circle. Can appear standalone (after marker) or
      wrapped inside the `body_rect_record` container (subtype 0x30) with
      inner_type 0x2b2b at offset +6, bbox at offset +16.

      Layout from marker (standalone form):
        marker(4)              FF E4 5C 39
        zeros(4)
        type_word(2)           == 0x2b2b
        unknown(8)
        x1(4 signed)           bounding box corner 1 X
        y1(4 signed)           bounding box corner 1 Y
        x2(4 signed)           bounding box corner 2 X
        y2(4 signed)           bounding box corner 2 Y

      `dsn2kicad` emits KiCad `(circle ...)` for equal-axis cases and a
      32-segment `(polyline ...)` for true ellipses.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: type_word
        contents: [0x2b, 0x2b]
      - id: unknown
        size: 8
      - id: x1
        type: s4
      - id: y1
        type: s4
      - id: x2
        type: s4
      - id: y2
        type: s4

  # -------------------------------------------------------------------------
  # Pin record (the main payload of a Cache cell's second occurrence)
  # -------------------------------------------------------------------------

  pin_record:
    doc: |
      Pin definition. Marker-framed (see `parse_cache_cells`, lines
      1503–1525).

      Layout from marker:
        marker(4)
        zeros(4)
        name_len(2)        length of pin name (1..10)
        pin_name(name_len) ASCII
        null(1)
        body_x(4 signed)   X where pin meets body
        body_y(4 signed)   Y where pin meets body
        hot_x(4 signed)    X wire connection point (hotspot)
        hot_y(4 signed)    Y wire connection point (hotspot)

      Pin direction is derived from the hotpoint→body vector. Pin length
      is the distance between the two points.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: name_len
        type: u2
      - id: pin_name
        type: str
        size: name_len
        encoding: ASCII
      - id: terminator
        contents: [0x00]
      - id: body_x
        type: s4
      - id: body_y
        type: s4
      - id: hot_x
        type: s4
      - id: hot_y
        type: s4

  # -------------------------------------------------------------------------
  # Cell-name occurrence locator
  # -------------------------------------------------------------------------
  # Not used as a parser, but documents the regex that scans the Cache:

  cell_name_marker:
    doc: |
      A `CellName.Normal\0` or `CellName.Convert\0` byte sequence. Used by
      `parse_cache_cells` to slice the Cache into per-cell regions. The
      cell name itself matches `[A-Za-z0-9_./+\-()]+`.
    seq:
      - id: cell_name
        type: strz
        encoding: ASCII
        terminator: 0x2e
      - id: style
        type: strz
        encoding: ASCII
        doc: '"Normal" or "Convert"; the strz consumes the trailing NUL.'
