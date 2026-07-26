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
    - body rectangle(s)
    - graphic primitives (lines, ellipses, arcs, filled polygons, open
      polylines, internal text annotations)
    - pin records (name, body endpoint, hotpoint endpoint, label flags)
    - per-cell physical pin-number lists (0x7f-separated)
    - GlobalSymbol glyph definitions for power symbols
    - LibraryPart structures carrying pin-name/number visibility and the
      symbol body bounding box

  Cell organisation: each cell name appears more than once as
  `CellName.Normal\0` (or `.Convert\0`). The first occurrence is a header
  (no graphics); later occurrences carry the body graphics and pins.
  `parse_cache_cells` tracks a `seen_names` set and parses graphics only on
  an occurrence after a name's first sighting; for those it reads a u16 OLB
  path length immediately after the cell-name match, skips
  `2 + path_len + 1` bytes, and begins primitive scanning there (`aps`).
  Pin records are scanned over the whole region between consecutive
  cell-name matches.

  As with page streams, records are located by scanning for the marker
  `FF E4 5C 39`; this schema cannot strictly auto-traverse the stream
  because there is no length field. The types below describe what the
  scanner finds at each marker or at the type-word offset immediately after
  a marker tail. Box/segment coordinates are int32 LE in
  10-mil units; polygon/polyline vertex pairs are int16 LE and stored as
  (y, x) — see `polygon_record` / `polyline_record`.

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
        type_word(2)  == 0x2828 (rectangle), 0x2929 (line),
                         0x2b2b (ellipse), or 0x2a2a (arc)
        unknown(8)
        x1(4 signed)                   bounding box corner 1 / line start
        y1(4 signed)
        x2(4 signed)                   bounding box corner 2 / line end
        y2(4 signed)
        (for 0x2a2a arcs, 4 more i32: start_x, start_y, end_x, end_y)
      Total: 32 bytes from subtype start (48 for arcs).

      When type_word is 0x2828, the bbox defines the body rectangle.
      When type_word is 0x2929, x1,y1→x2,y2 defines a line segment.
      When type_word is 0x2b2b, it defines the inscribed ellipse/circle.
      When type_word is 0x2a2a, it defines an arc (bbox + start + end).
    seq:
      - id: subtype
        contents: [0x30, 0x00, 0x00, 0x00]
      - id: unknown1
        size: 2
      - id: type_word
        type: u2
        doc: |
          0x2828 = rectangle, 0x2929 = line, 0x2b2b = ellipse/circle,
          0x2a2a = arc.
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

      Layout from the type-word offset `tw` (`_parse_cache_graphics`
      reaches it as marker+8):
        type_word(2)           == 0x2e2e
        unknown(8)
        bbox_x1(4 signed)      at tw+10, text bounding rectangle, top-left
        bbox_y1(4 signed)
        bbox_x2(4 signed)      bottom-right
        bbox_y2(4 signed)
        anchor_x(4 signed)     at tw+26, usually = (bbox_x1, bbox_y1)
        anchor_y(4 signed)
        flag_word(4)           at tw+34, varies (e.g. 0x00000003 or 0x00000008)
        text_len(2)            at tw+38, 1..100 ASCII bytes
        text(text_len)         at tw+40
        null(1)

      The bbox is typically ~8×9 OrCAD units (~2.0×2.3 mm), i.e. one
      glyph cell.

      The third coordinate pair —
      a near-duplicate of the first — is actually the text anchor and
      is what gives the giveaway. The trailing bytes carry the embedded
      ASCII character. See doc/ORCAD_FILE_FORMAT.md for the corrected
      interpretation.

      `_parse_cache_graphics` in dsn2kicad_py.py reads this record by
      resyncing on the 2-byte type word `0x2e2e`, not by parsing a
      marker-framed structure from the marker start.
    seq:
      - id: type_word
        contents: [0x2e, 0x2e]
      - id: unknown
        size: 8
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
  # Arc record (graphic primitive)
  # -------------------------------------------------------------------------

  arc_record:
    doc: |
      Arc segment on the ellipse described by its bounding box. Type word
      `0x2a2a`. The arc runs counterclockwise (in OrCAD screen space,
      Y-down) from start to end. Can appear standalone (after marker) or
      wrapped inside the `body_rect_record` container (subtype 0x30) with
      inner_type 0x2a2a at offset +6.

      Layout from marker (standalone form, 42 bytes from marker start):
        marker(4)              FF E4 5C 39
        zeros(4)
        type_word(2)           == 0x2a2a
        unknown(8)
        bbox_x1(4 signed)      bounding box of full ellipse, corner 1
        bbox_y1(4 signed)
        bbox_x2(4 signed)      corner 2
        bbox_y2(4 signed)
        start_x(4 signed)      arc start point (on the ellipse)
        start_y(4 signed)
        end_x(4 signed)        arc end point (on the ellipse)
        end_y(4 signed)

      Wrapped form (inside 0x30, 56 bytes from subtype):
        subtype(4)             == 0x30
        unknown(2)
        type_word(2)           == 0x2a2a
        unknown(8)
        bbox + start + end as above (8 × i32 = 32 bytes)

      `dsn2kicad` emits KiCad `(arc ...)` for circular arcs or a
      32-segment `(polyline ...)` for elliptical arcs.
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: zeros
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: type_word
        contents: [0x2a, 0x2a]
      - id: unknown
        size: 8
      - id: bbox_x1
        type: s4
      - id: bbox_y1
        type: s4
      - id: bbox_x2
        type: s4
      - id: bbox_y2
        type: s4
      - id: start_x
        type: s4
      - id: start_y
        type: s4
      - id: end_x
        type: s4
      - id: end_y
        type: s4

  # -------------------------------------------------------------------------
  # Pin record (the main payload of a Cache cell's second occurrence)
  # -------------------------------------------------------------------------

  pin_record:
    doc: |
      Pin definition. Marker-framed (see `parse_cache_cells` in dsn2kicad_py.py).

      Layout from marker:
        marker(4)
        zeros(4)
        name_len(2)        length of pin name (1..200; most are short)
        pin_name(name_len) ASCII
        null(1)
        body_x(4 signed)   X where pin meets body
        body_y(4 signed)   Y where pin meets body
        hot_x(4 signed)    X wire connection point (hotspot)
        hot_y(4 signed)    Y wire connection point (hotspot)
        pin_flags(1)       observed pin label visibility bits

      Pin direction is derived from the hotpoint→body vector. Pin length
      is the distance between the two points.

      Observed `pin_flags` values:
        0x21  pin number shown
        0x20  pin number hidden
      `dsn2kicad` preserves this byte and uses bit 0 when choosing KiCad
      symbol-level `(pin_numbers hide)` defaults.
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
      - id: pin_flags
        type: u1
        doc: |
          Observed pin-label visibility byte. Bit 0 appears to control
          pin-number display: set (`0x21`) means shown, clear (`0x20`)
          means hidden.

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

  # -------------------------------------------------------------------------
  # Filled polygon (graphic primitive, type word 0x2c2c)
  # -------------------------------------------------------------------------

  polygon_record:
    doc: |
      Filled polygon body primitive. Type word `0x2c2c`. Used by symbols
      whose body is drawn as a closed filled shape rather than a rectangle
      (see `_parse_cache_graphics` in dsn2kicad_py.py).

      Layout from the type word (NOT preceded by the usual marker tail here;
      `_parse_cache_graphics` resyncs on the 2-byte type word, then on the
      next marker):
        type_word(2)       == 0x2c2c
        unknown(24)
        vertex_count(2)    at type_word+26
        vertices           at type_word+28: vertex_count × (y, x) i16 pairs

      NOTE: vertices are stored (y, x), opposite to the (x, y) order of the
      line/rect/ellipse records. The converter swaps them, collapses
      collinear runs, and may split off near-degenerate spans as separate
      line segments (`_normalize_cache_polygon`).
    seq:
      - id: type_word
        contents: [0x2c, 0x2c]
      - id: unknown
        size: 24
      - id: vertex_count
        type: u2
      - id: vertices
        type: yx_point
        repeat: expr
        repeat-expr: vertex_count

  # -------------------------------------------------------------------------
  # Open polyline (graphic primitive, type word 0x2d2d)
  # -------------------------------------------------------------------------

  polyline_record:
    doc: |
      Open polyline body primitive. Type word `0x2d2d`. Carries an explicit
      byte length, so this is one of the few self-delimiting Cache records.

      Layout from the type word:
        type_word(2)       == 0x2d2d
        byte_length(u32)   at type_word+2; record continues for `byte_length`
                           bytes past type_word+2
        ...                a header whose size has two observed variants,
                           selected by `byte_length`:
                             variant A (remaining = byte_length-8, (remaining-10)%4==0):
                               vertex_count(u16) at type_word+18, points at +20
                             variant B (remaining = byte_length-8, (remaining-2)%4==0):
                               vertex_count(u16) at type_word+10, points at +12
        vertices           vertex_count × (y, x) i16 pairs

      As with polygons, vertices are stored (y, x). Consecutive duplicates
      are collapsed; the path is left open (not auto-closed).
    seq:
      - id: type_word
        contents: [0x2d, 0x2d]
      - id: byte_length
        type: u4
        doc: Record length in bytes counted from just after this field.

  # -------------------------------------------------------------------------
  # Per-cell physical pin-number list (0x7f-separated)
  # -------------------------------------------------------------------------

  pin_number_list:
    doc: |
      The physical (package) pin numbers for a cell, parallel to the cell's
      marker-framed pin_record list at the same indices. Located by
      `_parse_cache_pin_numbers` via the regex
      `([A-Za-z0-9_.+/()-]{2,30})\0(..)` — a cell name, a NUL, then a u16
      count — and validated by walking the entries.

      Layout:
        cell_name          ASCII, then a single 0x00
        count(u2)          number of pin-number entries (2..500)
        entries            count × { len(u2) + ASCII(len) + sep }
                           where `sep` is 0x7f or 0x00; runs of 0x00/0x7f
                           between entries are skipped.

      Entry i is the physical pin number string for pin i of the cell.
    seq:
      - id: cell_name
        type: strz
        encoding: ASCII
      - id: count
        type: u2
      - id: entries
        type: pin_number_entry
        repeat: expr
        repeat-expr: count

  pin_number_entry:
    seq:
      - id: len
        type: u2
      - id: value
        type: str
        size: len
        encoding: ASCII
      - id: separator
        type: u1
        doc: 0x7f or 0x00.

  # -------------------------------------------------------------------------
  # GlobalSymbol glyph record (power-symbol graphics)
  # -------------------------------------------------------------------------

  global_symbol_record:
    doc: |
      A GlobalSymbol definition embedded in the Cache, used for the
      vector glyphs of OrCAD power symbols (GND, VCC, VCC_BAR,
      VCC_CIRCLE, …). `extract_orcad_power_glyphs` finds candidates by
      scanning for the prefix byte 0x21, then decodes the structure with
      the OLB-format readers in `olb_parser.py`
      (`auto_read_prefixes`, `read_preamble`, `read_primitive`, …) — the
      layout is the OLB GlobalSymbol layout, not a DSN-specific one, so it
      is described in `olb_*.ksy` rather than re-specified here.

      Sketch of the head:
        prefixes           auto_read_prefixes(stream, 0x21) → checkpoints
        preamble
        name               len+zero-terminated string (the symbol name)
        source_library     len+zero-terminated string
        (seek to checkpoint)
        color(u32)
        primitive_count(u16)   (<= 20)
        primitives             read via olb_parser.read_primitive; an
                               all-zero 8-byte separator may appear between
                               primitives.
    seq:
      - id: note
        size: 0
        doc: Placeholder — decode via olb_parser; see olb_library.ksy.

  # -------------------------------------------------------------------------
  # LibraryPart locator (pin-name/number visibility + body bbox)
  # -------------------------------------------------------------------------

  library_part_locator:
    doc: |
      Cache also embeds OLB-format `LibraryPart` structures. `dsn2kicad`
      finds them with the regex `(.{4})\1\x18\x00\x18` (four bytes repeated,
      followed by `18 00 18`); the LibraryPart begins 10 bytes after the
      match start. They are then decoded with `olb_parser.read_library_part`.

      Used for:
        - parse_cache_pin_visibility →
            general_properties.pin_name_visible / pin_number_visible
        - parse_cache_bboxes → the symbol body bounding box (cache units,
            same frame as the pin hot-points)

      The LibraryPart layout itself is the OLB one; see `olb_library.ksy` /
      `olb_package.ksy`.
    seq:
      - id: note
        size: 0
        doc: Placeholder — locate via the regex above, decode via olb_parser.

  # -------------------------------------------------------------------------
  # Shared: polygon/polyline vertex stored y-first
  # -------------------------------------------------------------------------

  yx_point:
    doc: |
      A polygon/polyline vertex stored y-first, then x (int16 LE, 10-mil
      units). Swap to (x, y) for use.
    seq:
      - id: y
        type: s2
      - id: x
        type: s2
