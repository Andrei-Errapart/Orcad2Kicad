# OrCAD / PCB editor File Format Notes

Notes about the DSN files used during development.

## Development fixtures

The current local fixtures cover multiple boards, including small two-page
schematics and a larger multi-page schematic. Each fixture has a DSN and, where
available, a matching PDF export for visual cross-checking.

---

## DSN File Format (OrCAD Capture Schematic)

### Container

OLE Compound Document (compound-file storage). Readable with Python `olefile`.

```python
import olefile
f = olefile.OleFileIO('path/to/file.DSN')
for s in f.listdir():
    print('/'.join(s), f.get_size('/'.join(s)))
```

### OLE Stream Layout (larger multi-page board)

```
Stream                                              Size (bytes)
─────────────────────────────────────────────────────────────────
AdminData                                                      6
Cache                                                    123,456
Cells Directory                                            2,345
DsnStream                                                    123
ExportBlocks Directory                                         6
Graphics/$Types$                                               0
Graphics Directory                                             6
HSObjects                                                     16
Library                                                   54,321
NetBundleMapData                                               4
Packages/<unit_0>                                         80,333
Packages/<unit_1>                                         80,334
Packages/<unit_2>                                         80,335
Packages/<unit_3>                                         80,336
Packages Directory                                            88
Parts Directory                                            1,334
Symbols/$Types$                                                8
Symbols/ERC                                                   86
Symbols Directory                                             32
Views/SCHEMATIC1/Hierarchy/Hierarchy                      12,345
Views/SCHEMATIC1/Pages/01_INTRODUCTION                    23,456
Views/SCHEMATIC1/Pages/02_OVERVIEW                        34,567
Views/SCHEMATIC1/Pages/03_CPU                             45,678
Views/SCHEMATIC1/Pages/04_DDR4                            56,789
Views/SCHEMATIC1/Pages/05_UART                            67,890
Views/SCHEMATIC1/Pages/06_USB3                            78,901
Views/SCHEMATIC1/Pages/07_SFP                             89,012
Views/SCHEMATIC1/Pages/08_CAMERA                          90,123
Views/SCHEMATIC1/Pages/09_WIRELESS                        98,765
Views/SCHEMATIC1/Pages/10_GPIO                            87,654
Views/SCHEMATIC1/Pages/11_POWER                           76,543
Views/SCHEMATIC1/Pages/12_NVME                            65,432
Views/SCHEMATIC1/Schematic                                54,321
Views Directory                                               41
```

### DsnStream

123 bytes. Contains a JSON string with license and version info:

```json
{
  "InstallMode": "0",
  "License": "Concept_HDL_studio",
  "InstalledVersionBase": "17.4-2019",
  "InstalledVersionISR": "S014"
}
```

Preceded by a 32-byte binary header.

### `*Directory` index streams (shared envelope)

All `*Directory` streams in a DSN share a single envelope — confirmed
on DSNs by `scripts/dsn_dump` and
the Kaitai sketch `scripts/ksy/dsn_directory.ksy`. The streams that use
this envelope are: `Cells Directory`, `Parts Directory`,
`Packages Directory`, `Symbols Directory`, `Views Directory`,
`ExportBlocks Directory`, `Graphics Directory`.

**Stream layout:**

```
header:
  uint32 LE   unix_timestamp     seconds since 1970-01-01 UTC
  uint16 LE   count              number of dir_entry records
entries:
  count × dir_entry
```

**Per-entry layout** (variable size = 21 + name_len bytes):

```
uint16 LE   name_len
bytes       name (ASCII)
uint8       0x00 terminator
uint16 LE   kind                see table below
uint64 LE   filetime_created    Windows FILETIME (100-ns since 1601 UTC)
uint64 LE   filetime_modified   Windows FILETIME
bytes(4)    trailer             constant within a stream kind, see below
```

The previously documented "~28-byte fixed-size record" was incorrect:
the record is variable-length because the name field is length-prefixed,
and the 4-byte leading word is a *stream-level* Unix timestamp, not a
per-entry field.

**`kind` and `trailer` values** (constant within each stream, varying
between streams):

| Stream | Example entries | `kind` | trailer |
|--------|-----------------|--------|---------|
| `Cells Directory`        | `<unit_0>M`, `<unit_1>N`, ...  | `0x0006` | `d8 04 02 00` |
| `Parts Directory`        | `<unit_0>E.Normal`, ...        | `0x0018` | `d8 04 02 00` |
| `Packages Directory`     | `<unit_0>`..`<unit_3>`         | `0x001f` | `d8 04 02 00` |
| `Symbols Directory`      | `ERC` (single entry)           | `0x004b` | `03 00 02 00` |
| `Views Directory`        | `SCHEMATIC1` (single entry)    | `0x0009` | `03 00 02 00` |
| `ExportBlocks Directory` | (empty)                        | n/a     | n/a     |
| `Graphics Directory`     | (empty)                        | n/a     | n/a     |

Empty directories degenerate to 6 bytes (header only with `count = 0`),
which is what the DSNs show for `ExportBlocks Directory`,
`Graphics Directory`, and several others that some of the schematics do not
populate.

**Cells Directory** entries are the cell (symbol) names — large multi-unit
symbols use names like `<unit_0>M`, `<unit_1>N`, `<unit_2>O`,
`<unit_3>P`.

**Parts Directory** entries are part names that map to cells; the
`.Normal` suffix likely distinguishes body styles (Normal vs DeMorgan).
Example: `<unit_0>E.Normal`, `<unit_0>S.Normal`, `<unit_1>N.Normal`.

**Verification**: one larger board `Cells Directory` is 3,542 bytes =
`6 + 104 entries × 34 bytes` (each 9-character name); `Parts Directory`
is 4,270 bytes, 104 entries, consumed exactly with zero leftover.

**Timestamp note**: The FILETIMEs appear to be encoded as local-time epochs
mis-tagged as UTC. Consumers should compare FILETIMEs relatively rather
than treating them as authoritative absolute UTC.

### Cache

Symbol definition cache. Contains cached cell/symbol definitions from OLB libraries, including graphical primitives and pin positions for each symbol. The coordinate unit is 10 mils (0.254 mm), matching page stream coordinates 1:1.

#### Cell region layout

Each cell name appears in the Cache as a regex match of `CellName.Normal\0` (or `.Convert\0`). Cell names may contain letters, digits, `_./+-()`. Each cell typically has **three occurrences** of its name:

1. **First occurrence**: Cell header. Contains the OLB library path and metadata. No pin records.
2. **Second occurrence**: Cell definition. Contains the OLB library path, body rectangle, graphic primitives (lines, text), and pin records.
3. **Third occurrence**: Library reference. Points to other cells or libraries. No pin records.

The region between consecutive `CellName.Normal\0` matches defines the data extent for each occurrence.

#### Body rectangle (second occurrence)

After the cell name match in the second occurrence:

```
path_len(2, LE) + path(path_len) + null(1)
```

Immediately after the null terminator:

```
subtype(4, LE) = 0x30
unknown(2)
type_word(2, LE) = 0x2828     ← identifies standard body rectangle
unknown(8)
x1(4, LE signed)              ← body rectangle corner 1
y1(4, LE signed)
x2(4, LE signed)              ← body rectangle corner 2
y2(4, LE signed)
```

Total: 32 bytes from subtype start. The body rectangle defines the main outline of the symbol. Verified across all three DSN files.

**Examples**:

| Cell | Body rect | Pin hotpoint range | Padding |
|------|-----------|-------------------|---------|
| BOARD_CONNECTOR | (0,0)→(50,160) | x=[-10..60], y=[10..150] | 10 units top/bottom |
| BGA_153 | (0,0)→(180,1220) | x=[-30..210], y=[10..1200] | 10/20 units |
| CARD_SOCKET | (0,10)→(110,80) | x=[-30..120], y=[10..120] | irregular (bottom pins extend below body) |

#### Graphic primitives (second occurrence, after body rect)

Between the body rectangle and the first pin record, there are graphic primitives as `RECORD_MARKER`-delimited records:

**Text annotations** (type `0x2e2e`):

```
ff e4 5c 39              RECORD_MARKER
00 00 00 00              zeros
2e 2e 28 00              type = 0x2e2e (text annotation), 0x28 = subtype
00 00 00 00              zeros
bbox_x1(4, LE signed)    text bounding rectangle: top-left X
bbox_y1(4, LE signed)                              top-left Y
bbox_x2(4, LE signed)                              bottom-right X
bbox_y2(4, LE signed)                              bottom-right Y
anchor_x(4, LE signed)   text anchor X (usually = bbox_x1)
anchor_y(4, LE signed)   text anchor Y (usually = bbox_y1)
flag_word(4, LE)         per-annotation flags (e.g. 0x00000003, 0x00000008)
text_len(2, LE)          length of ASCII text (1–4 bytes)
text(text_len)           text characters (e.g., 'A', 'B', 'G')
null(1)                  null terminator
```

Total: 42 bytes per record (with a 1-character label). Text annotations are symbol-internal labels visible on the schematic — for example the six letters `A`, `B`, `G`, `G`, `G`, `G` placed above the bottom-row contacts of the `CARD_SOCKET` card socket. Bounding boxes are typically ~8×9 OrCAD units (~2.0×2.3 mm), i.e. one glyph cell.

Text annotations are extracted from the Cache and rendered as KiCad `(text "X" (at x y 0) ...)` primitives in the symbol definition (`_0_1` sub-symbol). The annotation anchor is the bbox centre, converted to mm using the same centering transform as pin positions.

**Prevalence**: 21 of 120 cells in the one larger board DSN carry text annotations (e.g., multi-unit symbols, connectors, PMICs). The previous "cells with line segments" counts are unchanged in arithmetic, only their interpretation.

**Line segment** (type `0x2929`):

```
ff e4 5c 39              RECORD_MARKER
00 00 00 00              zeros
29 29                    type = 0x2929 (line segment)
00 00 00 00 00 00 00 00  unknown (8 bytes)
x1(4, LE signed)         start X
y1(4, LE signed)         start Y
x2(4, LE signed)         end X
y2(4, LE signed)         end Y
```

Standalone line segments forming part of the symbol body graphic (e.g.,
pin-stub lines for test pads, internal dividers). Same record layout as
`0x2b2b` ellipses — the type word at offset +4 (after zeros) is the only
difference.

**Ellipse / circle** (type `0x2b2b`):

```
ff e4 5c 39              RECORD_MARKER
00 00 00 00              zeros
2b 2b                    type = 0x2b2b (ellipse bounding box)
00 00 00 00 00 00 00 00  unknown (8 bytes)
x1(4, LE signed)         bounding box corner 1 X
y1(4, LE signed)         bounding box corner 1 Y
x2(4, LE signed)         bounding box corner 2 X
y2(4, LE signed)         bounding box corner 2 Y
```

The bounding box defines the axis-aligned rectangle circumscribing the
ellipse. When `|x2−x1| == |y2−y1|` it is a circle. Can appear either as
a standalone record or wrapped inside a `0x0030` container record (see
below).

**Inside a `0x0030` wrapper**: the inner type word at wrapper offset +6
is `0x2b2b` and the bounding box is at wrapper offset +16 (4 × i32 LE),
same layout as wrapped `0x2828` rectangles but 6 bytes deeper into the
wrapper.

`scripts/dsn2kicad` emits KiCad `(circle (center X Y) (radius R) ...)`
for equal-axis ellipses and a 32-segment `(polyline ...)` approximation
for true ellipses.

**Arc** (type `0x2a2a`):

```
FF E4 5C 39              record marker
00 00 00 00              zeros
2a 2a                    type = 0x2a2a (arc)
xx xx xx xx xx xx xx xx  unknown (8 bytes)
xx xx xx xx              bbox_x1 (i32 LE) — bounding box of full ellipse
xx xx xx xx              bbox_y1
xx xx xx xx              bbox_x2
xx xx xx xx              bbox_y2
xx xx xx xx              start_x (i32 LE) — arc start point on ellipse
xx xx xx xx              start_y
xx xx xx xx              end_x (i32 LE) — arc end point on ellipse
xx xx xx xx              end_y
```

Total: 42 bytes from marker start. The bounding box describes the full
ellipse; `start` and `end` are points on that ellipse. The arc sweeps
counterclockwise in OrCAD screen space (Y-down) from start to end.

Can also appear wrapped inside a `0x0030` container (inner type
`0x2a2a` at +6, bbox + start + end at +16, total wrapper: 48 bytes).

Used for screw-head domes, common-mode choke bumps, inductor bumps,
ferrite bead bumps, etc. `scripts/dsn2kicad` emits KiCad
`(arc (start X Y) (mid X Y) (end X Y) ...)` for circular arcs and a
32-segment `(polyline ...)` for elliptical arcs.

**Filled polygon / compound path** (type `0x2c2c`):

```
ff e4 5c 39              RECORD_MARKER
00 00 00 00              zeros
2c 2c                    type = 0x2c2c (filled polygon / path)
00 00 00 00 00 00 00 00  unknown (8 bytes)
00 00 00 00 00 00 00 00  unknown (8 bytes)
vertex_count(2, LE)
vertex_count × {
    y(2, LE signed)
    x(2, LE signed)
}
```

The vertex order is `(y, x)`, unlike line, rectangle, ellipse, and arc
records, whose coordinates are stored as `(x, y)`. Records often repeat
the first vertex and may append the first vertex again as a close marker;
do not globally de-duplicate vertices because repeated points can encode
path structure.

Most observed records are simple filled triangles used for LED arrowheads
and transistor arrows. Some records appear to be compound paths: a closed
filled subpath followed by extra stroke vertices. The exact semantics of
those trailing vertices are not fully decoded.

**Container wrapper** (subtype `0x0030`):

The body rectangle record described above (in "Body rectangle") uses
subtype `0x30` as a wrapper that contains an inner graphic primitive.
The wrapper layout:

```
+0   u32  subtype = 0x00000030
+4   2B   unknown
+6   u16  inner_type         0x2828 = rectangle, 0x2929 = line,
                             0x2b2b = ellipse, 0x2a2a = arc
+8   8B   unknown
+16  i32  x1                 inner primitive bounding box
+20  i32  y1
+24  i32  x2
+28  i32  y2
     (for 0x2a2a arcs, 4 more i32 follow: start_x, start_y, end_x, end_y)
```

Total: 32 bytes for rectangle/ellipse/line, 48 bytes for arc. The
inner type at +6 determines interpretation. This is the first body graphic
encountered per cell (the "inner" body rectangle, ellipse, or arc).
Additional standalone graphics (`0x282828` outer rect, `0x2b2b`
standalone ellipse, `0x2a2a` standalone arc, `0x2929` lines) follow as
separate `RECORD_MARKER`-delimited records.

**Outer body rectangle** (type `0x282828`):

A 42-byte record with type bytes `28 28 28` at offset 0 (after marker+zeros). Contains rectangle coordinates at offsets 10–26 as int32 LE. This is a *second* body rectangle that, together with the inner rectangle from the preceding `0x0030` record, draws cells with composite outlines.

`scripts/dsn2kicad` now emits both rectangles as KiCad `(rectangle ...)` primitives on the symbol's `_0_1` sub-symbol. Earlier versions parsed this record but skipped it during symbol generation.

#### Pin records (second occurrence)

After the graphic primitives, pin records follow as `RECORD_MARKER`-delimited records:

```
ff e4 5c 39              RECORD_MARKER
00 00 00 00              4 zero bytes
name_len(2, LE)          pin name length (1–40)
pin_name(name_len)       ASCII pin name (e.g., "1", "DAT0", "NC")
null(1)                  null terminator
body_x(4, LE signed)     X where pin meets body
body_y(4, LE signed)     Y where pin meets body
hot_x(4, LE signed)      X wire connection point (hotspot)
hot_y(4, LE signed)      Y wire connection point (hotspot)
```

Pin name validation: all bytes must be printable ASCII (32–126). Coordinate validation: all four values must be within ±5000 units. Pin names can be up to 40 characters (e.g., `SEL_DFC/SCL_DFC1` at 16 chars).

The **body point** is where the pin stub meets the symbol body rectangle. The **hotpoint** is the wire connection end of the pin. Pin direction is derived from the hotpoint→body vector. Pin length is the distance between hotpoint and body point.

**Pin numbering**: Physical pin numbers are stored in a separate **0x7f-separated pin number list** (see below). The N-th entry in that list is the physical pin number for the N-th pin in the IC-style Cache pin list. For most ICs and connectors the list is simply sequential (1, 2, 3, ...), but for components like DIP switches the ordering differs from the Cache storage order — e.g., DIP-6 maps cache positions to physical pins [1, 2, 3, 8, 7, 6, 4, 5, 9, 10, 11, 12] following the standard DIP convention (down the left side, up the right side). Page-stream `pin_num = N` references the N-th pin in the Cache list for that cell. The pin *name* (e.g., "Vdda", "AD20") is distinct from the pin *number*.

**Pin names**: For simple components (R, C), pin names are just numbers ("1", "2"). For ICs and connectors, names may be signal names ("DAT0", "CLK") or "NC" for unconnected pins. BGA pins use ball designators as names. Multi-pin components may have duplicate names, for example many repeated "NC" pins on a large BGA component.

**Empirical examples**:

| Cell | Pins | Pin 1 hotpoint | Pin 1 body | Pin length |
|------|------|---------------|------------|------------|
| R | 2 | (-10, 10) | (0, 10) | 10 units (2.54 mm) |
| C | 2 | (-10, 10) | (0, 10) | 10 units (2.54 mm) |
| BOARD_CONNECTOR | 30 | (-10, 10) | (0, 10) | 10 units (left pins), 10 units (right pins) |
| BGA_153 | 153 | (210, 10) | (180, 10) | 30 units (right pins), 30 units (left pins) |
| CARD_SOCKET | 14 | (-30, 10) | (0, 10) | 30 units (left pins 1–8), 30 units (bottom pins 9–14) |

#### Text annotations (second occurrence, after pins)

After pin records, there may be text annotation records with different type bytes at offset 8. These contain reference designator prefixes (e.g., "CN") and other symbol text metadata. Note: type bytes `0x1e`/`0x1f` (or `0x1c`/`0x1d`) in the *page stream* are Value/Reference text position records — see "Value/Reference text position records" in the Page stream section.

### Library

The `Library` stream is the project's **style table + title-block field storage**. Two distinct regions:

1. **Header** (32 bytes): the ASCII string `OrCAD Windows Design` (space-padded, null-terminated), then 2 bytes of version (`03 00 02 00`), then a 4-byte Unix `time_t` mtime, then 8 bytes of zeros.

2. **Style records** (60 bytes each, packed back-to-back): describe fonts and other reusable styling.

#### Style record layout

```
+0   i32   tag         negative value identifying the kind of record:
                         -7, -8, -9 = font reference / face entry
                         -11, -13   = additional font binding (different
                                      usage contexts: schematic body,
                                      net label, hierarchical reference,
                                      etc.)
                         -16, -20, -21, -24, -27, -29, -48, -64
                                    = extra/extended font binding slots
+4   u32   index        per-tag index (0, 4, 5, 7, 8, …)
+8   i32   escapement   LOGFONT lfEscapement: text rotation in tenths
                          of degrees, counterclockwise.
                          0    = horizontal (left-to-right)
                          2700 = 270° = vertical (top-to-bottom)
+12  4B   reserved
+16  u32   weight       Windows GDI LOGFONT lfWeight value:
                          0x190 = 400 = Normal
                          0x2BC = 700 = Bold
+20  u32   italic       LOGFONT lfItalic-style flag:
                          0x00000000 = upright
                          0x000000FF = italic
+24  u8    pitch/family   GDI LOGFONT lfPitchAndFamily (e.g. 0x07, 0x03)
+25  u8    charset        GDI LOGFONT lfCharSet (e.g. 0x02 = SYMBOL_CHARSET)
+26  u8    flag           (typically 0x01)
+27  u8    quality        GDI LOGFONT lfQuality (e.g. 0x22, 0x31)
+28..  null-terminated face name ("Arial", "Courier New", "Arial Narrow")
+ rest   usage tag strings (e.g. "ABLE_EXPRESS_CONNECT", "ORRECT_PROP_CHAIN")
```

#### Value string table

After a binary header, the `Library`
stream contains a sequence of **u16-LE length-prefixed ASCII strings**
(`u16_LE(len) + chars(len) + null_terminator`). These serve as:

1. **Field-name headers** (first 7 entries): "1ST PART FIELD" through
   "7TH PART FIELD".
2. **Component value data** (remaining entries): a mix of INS instance
   IDs (`INSTANCE_A`, `INSTANCE_B`, ...), value strings
   (`10K/1005`, `0.1u/10V/0603/X7R`, `BOARD_CONNECTOR`, ...),
   title-block fields, library paths, and GUIDs.

Page-stream component records carry a **u16 LE value index** (located
immediately after the ref-name null terminator — see "Component records"
below). The actual value string is at position `value_index + 7` in
this table (the offset of 7 skips the field-name headers).

Example (one small board, 358 total entries):

| Ref    | u16 index | +7 → table position | Resolved value        |
|--------|-----------|---------------------|-----------------------|
| R1–R5  | 0x00EE (238) | [245]           | `10K/1005`            |
| R6     | 0x0022 (34)  | [41]            | `100K/1005/1% *DNP`   |
| C1, C3 | 0x0035 (53)  | [60]            | `0.1u/10V/0603/X7R`   |
| C2     | 0x004D (77)  | [84]            | `10u/16V/1608`        |
| CN1    | 0x00F3 (243) | [250]           | `BOARD_CONNECTOR`|
| SD1    | 0x00B9 (185) | [192]           | `CARD_SOCKET`     |
| SP1    | 0x0114 (276) | [283]           | `TH 2.2mm`           |
| SCR1   | 0x00FE (254) | [261]           | `M2x4mm`             |

Same-value components share the same index (all five 10K resistors have
value index 0x00EE). The index is a u16 (not a single byte) — SP1
demonstrates this with high byte = 0x01.

**Do Not Populate (DNP)**: OrCAD marks DNP components solely via the
` *DNP` suffix on the value string (e.g., `10K/1005 *DNP`). There is no
binary flag in the component record or any other stream. The converter
strips the suffix for display and emits `(dnp yes)` + `(in_bom no)` in
the KiCad output.

Implemented in `scripts/dsn2kicad` as `parse_library_value_strings()`
and `lookup_component_value()`.

#### Title-block field run

The title-block fields are embedded within the same u16-length-prefixed
string table described above. `parse_title_block` in `scripts/dsn2kicad`
locates the live Title / Document Number / Rev values by heuristic; see
the "Title-block" subsection of "Page Streams" below.

#### Status

- Font names, weight (Normal/Bold), and italic flag are decoded
  cleanly. Confirmed: 6 records in the one small board's `Library`
  carry `weight = 700`, and one of them (`@ 0x07ee`, tag = -64) is
  bold-italic Arial.
- **Page-stream text records reference Library styles by a 1-based
  index** stored at offset +36 of the text record:
  `library_styles[text.style_id - 1]` is the style for that text.
  The text record field was originally misnamed `font_size`; it is
  actually a **style ID**, NOT a point size.
- Verified on the one cover page: every distinct text style ID
  maps to a Library record whose weight + italic flag match the
  visible rendering — the bold-italic title `the board title`
  (`style_id=34`) hits the only bold-italic Arial record (index 33),
  bold body paragraphs (`style_id=35`) hit bold Arial records, plain
  black labels (`style_id=15, 17`) hit normal Arial records.
- Font **color has not been found in the DSN.** Investigation
  summary (one cover page, where there are 3 visible colors —
  black body text, green `INDEX` and `the board title` title,
  red `CAUTION` heading and body paragraphs):

  | Place we looked | Result |
  |---|---|
  | Library record `ext_word` (u32 at +34) | Same value `0x0194d2f6` in record 33 (green BI title) and record 35 (red CAUTION). For records with face names longer than 5 chars (`Courier New`, `Arial Narrow`) these bytes are part of the face-name string spillover, not a separate field. |
  | Page-stream text record `+38` u16 | Zero for both the green title and 3/4 of the red paragraphs. The two non-zero values (`Page`: 0x0043, `CAUTION`: 0xd141) don't correlate with color — `Page` is black, and `CAUTION` is the only `0xd141` record. |
  | 18-byte prefix between marker and type-word | Identical sequence across every text record on the page. |
  | Full byte-diff of Library records 33 vs 35 (green BI vs red B, both Arial) | Only `tag` (+0) and `italic` flag (+20) differ. No color byte exists. |
  | Library `tag` value as a color discriminator | Tags are **not** unique per Library record (e.g. tag=-13 appears in 5 records, mapped to both black and red texts). So tag alone can't determine color either. |
  | Page-stream text record vs decorative rectangle style mechanism | Rectangles use a u16 "style index" at offset +50 with 2 values (0=black-thin, 1=red-thick). Text records have no equivalent byte at +50 or any other position that correlates with color. The two mechanisms are unrelated. |

  Our investigation has **not located** the field encoding text
  color anywhere in the DSN streams we currently parse. It may still
  be present in bytes/streams we haven't decoded — we just haven't
  found it. As a workflow note: it was customary in OrCAD Capture
  installations to customize color preferences without baking them
  into the schematic file, so a project's rendered appearance could
  vary between machines. The KiCad output produced from the DSN
  inherits this limitation — the green title and red CAUTION text
  come out black until either the color field is decoded or the
  user re-colors them in KiCad.

- Rendered **point size** likewise is not stored in the Library
  record; the size comes from the text record's bounding rectangle
  in the page stream (`bbox_y2 - bbox_y1` per line).

### Packages

Four per-unit package streams — these are the units of a large multi-unit symbol. Binary format containing pin definitions, coordinates, and graphics for each unit. Uses a different pin list encoding from the IC-style Cache records:

```
pin_count(2, LE)         number of pins in this unit
name_len(2, LE)          length of first pin name
pin_name(name_len)       ASCII ball designator (e.g., "AD20", "V18")
null(1)                  null terminator
[0x7f separator          marker between pins
 name_len(2, LE)         length of next pin name
 pin_name(name_len)      next pin name
 null(1)]...             repeats (pin_count - 1) times
```

Pin numbering is sequential: 1st pin = pin 1, 2nd = pin 2, etc. BGA pins use ball designators (e.g., "AJ22", "AA21") as names.

The same 0x7f-separated format also appears in the **Cache stream** for non-BGA cells, indexed by `CellName\x00` (without `.Normal` suffix). Here the entries are physical pin *numbers* (as ASCII strings), not pin *names*. Each entry maps the corresponding IC-style Cache pin at the same index to its physical pin number. For most components the list is simply `["1", "2", ..., "N"]`, but for DIP-package components the list reflects the standard DIP pin convention (e.g., DIP-8: `["1","2","3","4","5","6","7","8","16","15","14","13","12","11","10","9"]`).

### Hierarchy Stream

Contains schematic-level net records. The current parser extracts net IDs and
net names from this stream, but the pin-to-net connectivity records after the
net names are still only partially understood. Treat this as an important
netlist source, not yet as a fully decoded schematic netlist.

**Header**: Starts with `42 31` marker ("B1"), followed by schematic name `SCHEMATIC1`.

**Net records**: Each net has a record containing:
- A marker byte sequence including `\x30\x00\x00`
- A length byte
- The net name as a null-terminated ASCII string
- Followed by binary connectivity data

From the one larger-board Hierarchy stream, 574 nets were extracted:
- 331 named signal nets (PCIE_REFCLKP0, VDD5G_1P8_EN, ETC_RESETN, etc.)
- 243 anonymous nets (ANON_NET_B, ANON_NET_C, etc.)

From the one small-board Hierarchy stream, 16 nets were extracted:
- Interface clock, command, data, reset, ground, and supply nets

After the net name records, there are repeating blocks containing `BH` markers and binary data — likely the pin-to-net connectivity records linking component pins to nets. These records are ~26 bytes each and repeat once per connection point.

**The Hierarchy stream provides cross-page net-name information.** Net names can
be used to determine which nets are global (appear on multiple pages → global
labels in KiCad) versus local (single page → local labels). The per-page net
tables in each page stream provide the actual wire-to-net assignments currently
used by `scripts/dsn2kicad`.

### Page Streams

Each page stream contains the schematic drawing data for one page.

**Header** (first ~300 bytes):
- `0x0a` record marker
- Page name (e.g., `15_POWER1`, `02_MEMORY`)
- Paper size string (e.g., `A2`)
- Page dimensions as 32-bit LE integers
- Drawing area bounds

**Body**: Binary records containing:
- Component instance placements (position, rotation, cell reference)
- Wire segments (coordinate pairs)
- Net labels (text + position)
- Power symbols
- Text annotations

The page streams contain embedded ASCII strings for:
- Net names at their label positions
- Component reference designators (but not as simple ref strings — they're embedded in component instance records)
- Property values
- Pin names from symbol instantiations

From one page stream, interface signal names, supply names, and ground were found as embedded strings.

**Coordinate system**: All coordinates in OrCAD page streams are in units of 10 mils (0.254 mm). Y increases downward. To convert to KiCad schematic millimeters: `coord × 0.254`.

**Record marker**: The 4-byte sequence `ff e4 5c 39` is the primary record separator throughout page streams. Nearly all structured records begin with this marker.

#### Page header

After the first `ff e4 5c 39` marker + 4 zero bytes:

```
name_len(2, LE) + name(name_len) + null(1) + paper_len(2, LE) + paper(paper_len) + null(1)
```

Paper size is an ASCII string: `A0`–`A4`, `A`–`E`.

#### Net name table

Preceded by the 12-byte anchor sequence `30 00 00 00 05 00 00 00 03 00 00 00` (the same bytes appear many times in the page stream as part of per-pin records with value `34 17` after them; the net table follows the **last** occurrence). After the anchor:

```
extra_count(2, LE)                  — number of 4-byte entries to skip (often 0)
skip_entries(extra_count * 4)       — optional ID list (purpose unknown)
net_count(2, LE)                    — number of net entries that follow
net_entry[]                         — repeated net_count times:
    name_len(2, LE) + name(name_len) + null(1) + net_id(4, LE)
```

Net IDs are 32-bit unsigned integers. Net names are printable ASCII (1–50 chars). The declared `net_count` matches the actual number of parseable entries.

#### Wire records

```
ff e4 5c 39          record marker
zeros(4)             4 zero bytes
record_id(4, LE)     unique record ID
net_id(4, LE)        references net name table
30 00 00 00          subtype = 0x30 (wire)
x1(4, LE signed)     start X in 10-mil units
y1(4, LE signed)     start Y
x2(4, LE signed)     end X
y2(4, LE signed)     end Y
```

Total: 36 bytes from marker start. Wire segments connect at shared endpoints. Three or more segments meeting at a point form a junction.

#### Bus wires

Bus wires use the **identical** record format as regular wires (same marker
`FF E4 5C 39`, same subtype `0x30`, same 36-byte layout). There is no binary
distinction between a bus segment and a regular wire segment.

The only way to identify a bus wire is by resolving its `net_id` against the
net name table: bus nets use vector bracket notation in their name, e.g.
`DDR0_CAA[5..0]` or `P[3..0]`. The regex `\[\d+\.\.\d+\]` identifies them.

**Bus entries are implicit.** OrCAD does not store the 45-degree diagonal
connectors between individual wires and the bus line. There is a 10-unit gap
(one grid step) between member wire endpoints and the bus segment endpoints.
Bus entries must be synthesized during conversion by finding wire endpoints
that are exactly ±10 units away in both X and Y from a bus point on the
matching bus net.

Member wires of a bus (e.g. `DDR0_CAA3` is a member of `DDR0_CAA[5..0]`) share
the prefix and have a numeric suffix matching one of the vector indices.

#### Component instance records

Found by regex-matching `CellName.Normal\0` or `CellName.Convert\0` in the binary stream. After the null terminator (position = `cell_end`):

```
cell_end + 0:   unknown(2)
cell_end + 2:   0xFF (constant)
cell_end + 3:   unknown(3)
cell_end + 6:   x(2, LE signed)     component X position
cell_end + 8:   y(2, LE signed)     component Y position
cell_end + 10:  unknown(6)
cell_end + 16:  0x30 marker byte     (if present)
cell_end + 17:  orient_byte          orientation encoding
cell_end + 18:  unknown(2)
cell_end + 20:  pre_pin_count(2, LE) number of RECORD_MARKER-delimited
                                     records before the pin placement cluster
                                     (ref/val position records + extra metadata)
```

**Orientation encoding**:

The orient byte encodes both rotation and mirror as a 3-bit field:
- Bits 0–1: rotation (0=0°, 1=90°CW, 2=180°, 3=270°CW)
- Bit 2: mirror flag (horizontal flip, negates X)

| Byte value | Rotation | Mirror | Description |
|------------|----------|--------|-------------|
| 0x00       | 0°       | No     | Default horizontal |
| 0x01       | 90° CW   | No     | |
| 0x02       | 180°     | No     | |
| 0x03       | 270° CW  | No     | |
| 0x04       | 0°       | Yes    | Mirrored horizontally |
| 0x05       | 90° CW   | Yes    | Mirrored + 90° |
| 0x06       | 180°     | Yes    | Mirrored + 180° |
| 0x07       | 270° CW  | Yes    | Mirrored + 270° |

The forward transform applies mirror first (negate X), then rotation.
The inverse transform undoes rotation first, then undoes mirror (negate X).

**KiCad angle conversion**: KiCad applies rotation first, then mirror — the
opposite order from OrCAD. To compensate, mirrored components (bit 2 set) need
their rotation angle negated: 90°↔270°, while 0° and 180° are unchanged.
Non-mirrored orientations map directly to the KiCad angle.

**Reference designator**: Found by scanning from `cell_end + 16` for up to 300 bytes, looking for `0x18` marker byte followed by:

```
0x18
ref_len(2, LE)       length of reference string
ref(ref_len)         ASCII reference (e.g., "R4", "C1", "U3")
0x00                 null terminator
value_idx(2, LE)     index into Library value string table
```

The reference matches the pattern `[A-Z]{1,3}\d+[A-Z]?`.

**Value index**: The u16 LE immediately after the ref null terminator is
an index into the Library stream's value string table. The actual value
string is at table position `value_idx + 7` (the +7 skips the 7
field-name header strings). This resolves to the component's Value field
content: e.g., "10K/1005", "0.1u/10V/0603/X7R", "CARD_SOCKET".
Same-value components share the same index.

**Component position**: The stored (x, y) at `cell_end + 6/8` is NOT the cell origin and NOT the pin center. Its meaning is unclear (possibly a text anchor or reference point). To determine the actual component origin, match page-stream pin records to Cache pin definitions (see below).

#### Value/Reference text position records

Between the orientation byte and the pin placement records, two
`RECORD_MARKER`-delimited records encode the page-relative offsets for the
component's Reference and Value text. They normally appear as a consecutive
pair:

```
ff e4 5c 39          record marker
00 00 00 00          4 zero bytes
prop_id(4, LE)       property ID (file-specific, see below)
x_off(2, LE signed)  X offset from component origin (10-mil units)
y_off(2, LE signed)  Y offset from component origin (10-mil units)
```

**Order used by `scripts/dsn2kicad`**: the first record is the **Reference**
text position; the second is the **Value** text position. The second record
normally immediately precedes the `0x18` reference designator tag. Earlier
notes had this order reversed.

**Property ID**: The `prop_id` field varies between DSN files (e.g.,
0x1e/0x1f in one board, 0x1c/0x1d in other boards). These are likely
indices into a file-internal property table. Current parser behavior treats
the first position record as Reference and the second as Value regardless of
the specific ID values.

**Coordinate system**: Offsets are in page coordinates (not component-local),
so they do not need rotation transformation. Byte 17 of the position record is
used by `scripts/dsn2kicad` to detect 90° rotated reference/value text
(`0x40` flag bit).

**Empirical examples** (one small board):

| Component | Cell | Value offset | Reference offset |
|-----------|------|-------------|-----------------|
| CN1 | BOARD_CONNECTOR | (-5, -14) | (-20, 190) |
| SD1 | CARD_SOCKET | (0, -10) | (40, -10) |
| C1–C3 | C | (20, 0) | (20, 10) |
| R1–R5 | R | (0, 20) | (0, -40) |
| R6 | R | (20, 20) | (30, -50) |

#### Pin placement records

After each component instance, pin placement records follow the
`pre_pin_count` non-pin marker records (ref/val position records and
extra metadata — see `cell_end + 20` above). Each pin record:

```
ff e4 5c 39          record marker
00 00 00 00          4 zero bytes
pin_num(2, LE)       1-based index into Cache pin list for this cell
pin_x(2, LE signed)  pin hotpoint X in page coordinates (10-mil units)
pin_y(2, LE signed)  pin hotpoint Y in page coordinates (10-mil units)
unknown(4)           per-pin metadata; values vary
net_id(4, LE)        optional net-table ID at marker+18
```

The `pin_num` is a 1-based index into the Cache pin list for the cell, NOT a named pin number. For a 153-pin BGA cell, `pin_num=3` refers to the 3rd pin in the Cache list, which may have a signal-style name such as "DAT0".

The `net_id` field is considered present only when it resolves through the
page's net table. This field is important because some OrCAD connections are
stored directly on the pin record without an intervening wire segment — for
example, a power port placed directly on a resistor pin. The PDF export shows
the connection as a power label above the component, but in the binary format
the only evidence is this net_id on the pin record. OrCAD net names are
case-insensitive, so `VDD1G_1p8` in rendered/text contexts and `VDD1G_1P8` in
the net table are the same net.

**Computing component origin from pin records**:

Given a page-stream pin with `pin_num=N` at page position `(px, py)`, and the N-th Cache pin having hotpoint `(hx, hy)`, the Cache hotpoint must first be transformed by the component's orientation (mirror then rotation) before subtracting:

```
(rhx, rhy) = forward_rotate(hx, hy, orient_byte)
component_origin = (px - rhx, py - rhy)
```

All pins from the same component instance yield the same origin (verified: zero spread across all tested components). The component center for KiCad placement is then:

```
(rcx, rcy) = forward_rotate(center_x, center_y, orient_byte)
kicad_center = origin + (rcx, rcy)
```

Where `(center_x, center_y)` is `((min_hx + max_hx)/2, (min_hy + max_hy)/2)` computed from the Cache pin list (also in symbol-local coordinates, so also rotated).

**Empirical verification** (one small board):

| Component | Cell | Raw (x,y) | Origin (computed) | Page pins matched |
|-----------|------|-----------|-------------------|-------------------|
| CN1 | BOARD_CONNECTOR | (279, 483) | (300, 280) | 22/30, origin spread = 0 |
| SD1 | CARD_SOCKET | (1095, 435) | (1130, 310) | 14/14, origin spread = 0 |
| U1 | BGA_153 | (1315, 1483) | (1350, 250) | 33/153, origin spread = 0 |

Note: not all physical pins have page-stream records — only pins participating
in page connectivity. Most of these are wire-connected pins, but direct
power-port-to-pin cases can also appear only as a `net_id` on the pin record.
Even one matched pin suffices to compute the exact origin.

#### Power symbol records

Power symbols (GND, VCC, etc.) share the record marker but are distinguished from component records by structure:

```
ff e4 5c 39          record marker
00 00 00 00          4 zero bytes (distinguishes from wires which have nonzero here)
rec_type(4, LE)      record type ID
header(4, LE)        header value (varies: 0x1a, 0x1c, 0xa6, 0xdab, etc.)
name_len(2, LE)      length of symbol name
name(name_len)       ASCII name (e.g., "GND", "VCC_BAR")
null(1)              null terminator
cell_id(4, LE)       cell/symbol ID
x(2, LE signed)      X position
y(2, LE signed)      Y position
```

The `header` field varies widely between DSN files and is NOT a reliable filter. To identify power symbols, first exclude records containing `.Normal`, `.Convert`, `TitleBlock`, `Border`, or `OFFPAGE` in the name, then apply a positive filter matching known power net name prefixes (GND, VCC, VDD, VSS, AGND, PGND, AVDD, DVDD, VIO, VBUS).

##### Caveat: these are *not* glyph-placement records

Empirical testing on one small-board DSN
showed that **none** of the 12 records identified by the layout above
have coordinates that land on any wire endpoint of the matching net.
The bbox sizes (10×20 OrCAD units for GND records, 22×65/72 for
VCC_BAR records) match the dimensions of the **caption text label**
("GND", "VCC_BAR", a supply net name, …) drawn next to the glyph —
not the glyph anchor itself. OrCAD apparently draws the actual GND /
VCC glyph **implicitly** at the wire endpoint when the net is a
power net, and these records carry the bounding box of the caption
text only.

`scripts/dsn2kicad` therefore **ignores** these records as a source
of glyph positions. Instead it synthesizes power-symbol glyphs at
every wire endpoint that:

1. is on a recognized power net (per `is_power_net` — GND, VCC*,
   VDD*, VSS*, VBUS, VIO, AGND, PGND, AVDD, DVDD, names ending in
   `<digits>V`, etc.),
2. is a "free" wire endpoint (count == 1 in the segment graph), and
3. does **not** coincide with a component pin position.

There is one additional source of synthesized power glyphs: a component pin
record may carry a resolved power `net_id` even when no parsed wire touches the
pin. In that case `scripts/dsn2kicad` emits the power symbol directly at the
pin hotpoint. This covers direct OrCAD power-port connections where the binary
stores the net association on the pin record rather than as a wire segment.

The pin-position filter is essential: without it, a multi-pin
connector with a GND bus running across its left column ends up
with a synthesized GND triangle stacked over every pin number,
because each pin stub presents a "free endpoint" at the pin itself.
The filter is computed by `collect_pin_positions(components)` in
dsn2kicad, which reconstructs each placed component's absolute pin
coordinates from the Cache pin list (`_cell_pin_lists[cell]`), the
cache pin-center (`_cell_centers[cell]`), and the component's
`(x, y, orient)`. This works correctly for large connectors (CN1
with 30 pins) whose `parse_components` page-stream pin-record
scan only captures a partial pin list — the Cache-derived positions
fill in the rest.

##### Power-symbol glyph styles

KiCad's `(symbol ...)` parser (see
`kicad/eeschema/sch_io/kicad_sexpr/sch_io_kicad_sexpr_parser.cpp`
case `T_power`) accepts three forms inside a `(symbol ...)` block:

- `(power)` — defaults to **global** (`SetGlobalPower()`).
- `(power global)` — explicit global.
- `(power local)` — local to this project's symbol library.

The `power:` prefix in the `lib_id` is purely a naming convention;
there is no special handling tied to the literal string in the
parser. So a power-symbol definition embedded in a per-page
`(lib_symbols)` block under any `lib_id` is treated as a power
symbol as long as it contains `(power)` — KiCad's stock `power`
library does not have to be installed system-wide.

`scripts/dsn2kicad` emits two synthesized power-symbol shapes,
modelled after OrCAD/Capsym conventions:

- `power:GND` — KiCad's standard triangle-down glyph (the standard
  KiCad shape; OrCAD's GND triangle is similar enough).
- `power:<rail>` — a T-shape: vertical stem from the pin up to a
  short horizontal cross-bar, with the rail name shown above the
  bar. This matches OrCAD's `VCC_BAR`-style rail symbol.

Both shapes are emitted into both the page's inline `(lib_symbols)`
block and the project-wide `.kicad_sym` so that resolution doesn't
depend on `sym-lib-table` lookups outside the project directory.

#### Free-text records

Free-text annotations (titles, headings, labels, paragraph-style notes,
table cell text) on a page are stored as fixed-size 42-byte records
**followed by** the text payload. The record carries a **type word
`0x2e2e0001`** (which is the same `2e 2e` word the Cache stream uses for
its text annotations, but page-stream texts add a `01 00` discriminator
prefix). Layout from the type-word offset:

```
+0   u32  type_word = 0x2e2e0001  (the bytes are 01 00 2e 2e)
+4   u32  rec_len               total record length from rec_len onward
+8   u32  zeros
+12  u32  p1, p2, p3, p4, p5, p6   six u32 coordinate fields encoding
                                     the text's bounding rectangle in
                                     OrCAD 10-mil units:
                                       (p1, p2) = top-left corner
                                       (p3, p4) = bottom-right corner
                                       (p5, p6) = repeat of (p1, p2)
                                     The "top" is the cap-line and
                                     the "bottom" is the baseline —
                                     descenders of glyphs like g/p/y
                                     extend BELOW the bbox by ~30%
                                     of the font's em height.
+36  u16  style_id               1-based index into the Library
                                   stream's style table. The referenced
                                   record carries the font face,
                                   weight, and italic flag for this text.
+38  u16  unknown                varies widely (0, 67, 2153, 53569, …);
                                   meaning not yet decoded
+40  u16  text_len               length of the ASCII text in bytes
+42  ..   text                   ASCII bytes; may contain `\n` for
                                   multi-line paragraphs
```

**KiCad emission**: `scripts/dsn2kicad` emits one `(text ...)` primitive
per logical line — paragraphs are split on `\n` and each line is
offset vertically by `line_h = bbox_height / line_count`. Each line is
anchored `(justify left bottom)` at `(bbox_left, bbox_top + (j+1) ×
line_h + descender_offset)`, so the line's baseline lands on the
appropriate row of the bbox.

**Text sizing via freetype**: the rendered point size is computed so
that the longest line, measured by [freetype-py] against the same
Arial TTF KiCad will render with, exactly fits the bbox width — or
the per-line bbox height, whichever is smaller. KiCad's outline-font
renderer applies an internal `m_outlineFontSizeCompensation = 1.4`
(in `kicad/include/font/outline_font.h`), so the value written into
the `.kicad_sch` file is divided by 1.4 to compensate. If
`freetype-py` is unavailable the script falls back to a fixed `0.6 ×
size` average glyph width.

**Descender offset**: KiCad's `(justify left bottom)` anchors at the
descender line (below the baseline by ~21% of em height). To match
OrCAD's baseline = bbox-bottom convention, the emitter shifts each
line down by `0.30 × size` (Arial descender ratio 0.21 × KiCad
compensation 1.4) so that the baseline lands on the bbox bottom edge
and descenders (`g`, `p`, `y`, `j`) extend below.

[freetype-py]: https://pypi.org/project/freetype-py/

**Title-block keep-out**: free-text records whose anchor falls inside
the bottom-right corner of the page (a `TB_REGION_W × TB_REGION_H` =
`300 × 250` 10-mil rectangle) are filtered out — OrCAD writes the
company/copyright text per-page
inside the title-block frame, and KiCad redraws the frame from the
`(title_block ...)` header. The filter is in `parse_text_annotations`
and uses the per-page paper size from `ORCAD_PAGE_SIZE`.

**Debug overlay**: pass `--debug-bbox` on the `dsn2kicad` command line
to add a thin magenta `(rectangle ...)` around every text record's
bbox and a thin green `(rectangle ...)` around every page-rectangle
record, which is useful for spotting position/size mismatches in
KiCad.

#### Decorative rectangle, line, and ellipse records

Decorative graphics on schematic pages (table outlines, callout
borders, separator lines, length-matching ovals) are stored as
marker-framed records with **type words**:

```
01 00 28 28 28 00   rectangle          (62 bytes per record)
01 00 29 29 20 00   line / polyline    (54 bytes per record)
01 00 2b 2b 28 00   ellipse / circle   (62 bytes per record)
```

All three records share the same layout from the marker:

```
+0   4B   RECORD_MARKER = FF E4 5C 39
+4   8B   zeros
+12  2B   sub-type = 30 00
+14  2B   zeros
+18  6B   type word (see table above)
+24  6B   zeros / padding
+30  u32  x1                              endpoint or corner 1, 10-mil units
+34  u32  y1
+38  u32  x2                              endpoint or corner 2
+42  u32  y2
+46  4B   zeros / unknown
+50  u16  style index (rectangles only):
            0 = "normal" — rendered black, thin
            1 = "emphasis" — rendered red, thick
+52..   trailer bytes; for rectangles 8 more bytes, for lines 4 more
```

**Style index, color, and stroke width**: OrCAD does **not** store
explicit stroke widths or RGB colors in the page-stream graphics
records. The single `u16` at +50 acts as a style **index** that selects
both color and width together. It is NOT an index into the `Library`
stream's records (those are all font references, no line/fill style
records were observed). It is more likely an index into an **implicit
OrCAD-side rendering palette** hardcoded in Capture itself.

Empirical mapping from the one cover page's PDF render:
- index 0 (INDEX table, all decorative lines): black, 0.36 pt stroke
- index 1 (CAUTION block border): red, 1.08 pt stroke (3× thicker)

`scripts/dsn2kicad` mirrors this by emitting KiCad strokes at 0.15 mm
for index 0 and 0.30 mm for index 1, with explicit `(color R G B A)`
values (`0 0 0 1` for black, `200 0 0 1` for red).

**Line records**: the +50 offset is reliable for the 62-byte rectangle
and ellipse records. For the 54-byte `0x292920` line records, +50
overlaps the next record's marker bytes, so `parse_page_graphics`
currently treats all lines as style 0 (black, thin). Cover-page samples
are consistent with this — only the CAUTION rectangle uses style 1, not
any line.

**Ellipse records**: 62 bytes, same as rectangles. The bounding box at
+30 defines the axis-aligned rectangle circumscribing the ellipse. The
style index at +50 is always 0 in observed data. OrCAD renders these
ellipses in green (e.g., length-matching bus ovals on page 6), but the
green color is not stored in the DSN — it comes from OrCAD's implicit
rendering palette. `scripts/dsn2kicad` emits KiCad `(circle ...)` for
equal-axis ellipses and a 32-segment `(polyline ...)` for true ellipses.

**Title-block keep-out**: rectangle, line, and ellipse records whose
**both** endpoints fall inside the bottom-right title-block region are
filtered out, like free-text records.

**Sample (one cover page, `01_NOTE`)**:

| Record | Coords (10-mil) | Color | Use |
|--------|-----------------|-------|-----|
| rect | (120, 300)→(840, 430) | black | INDEX table outer frame |
| rect | (120, 530)→(760, 780) | red   | CAUTION block border |
| line | (120, 345)→(840, 345) | black | INDEX header / row-1 divider |
| line | (120, 390)→(840, 390) | black | INDEX row-1 / row-2 divider |
| line | (120, 430)→(840, 430) | black | INDEX bottom edge (= rect edge) |
| line | (220, 300)→(220, 430) | black | INDEX `Page` / `Schematics` column divider |
| line | (120, 350)→(840, 350) | black | inner header double-line |

#### Title-block fields per page

The title-block instance (`TitleBlock0`) is referenced by name in every
page stream but its field **values** (Title, Document Number, Rev) are
stored once project-wide in the `Library` stream (see "Library" above).
`scripts/dsn2kicad` extracts them with `parse_title_block(ole)` and
emits them in KiCad's `(title_block ...)` block of every page:

| OrCAD title-block field | KiCad slot |
|---|---|
| Title          | `(title ...)` |
| Rev            | `(rev ...)` |
| Document Number | `(comment 1 ...)` (KiCad has no native Doc# field) |
| Sheet N of M    | `(comment 2 ...)` |
| Date           | empty (not stored in DSN; Capture generates at print time) |

**Renamed-clone caveat**: the board DSN files contain leftover
title-block records from previous clones. `parse_title_block` picks the
**last** doc number before the `SCHEMATIC1` sentinel
in `Library` — that's the live record. The earlier doc-number records
are stale.

#### KiCad R/C vs OrCAD R/C symbol differences

OrCAD and KiCad use different conventions for passive component symbols:

| Property | OrCAD R | OrCAD C | KiCad R | KiCad C |
|----------|---------|---------|---------|---------|
| Default body orientation | Horizontal | Horizontal | Vertical | Vertical |
| Pin-to-pin distance | 40 units (10.16 mm) | 30 units (7.62 mm) | 7.62 mm | 7.62 mm |
| Default orientation | 0° = pins left/right | 0° = pins left/right | 0° = pins top/bottom | 0° = pins top/bottom |

When converting OrCAD orientation to KiCad angle for R and C, the formula is `(90 − orcad_angle) % 360` because KiCad's body is already rotated 90° relative to OrCAD's default. For generic symbols (ICs, connectors), use the OrCAD angle directly.

The pin-to-pin distance mismatch for R (10.16 mm OrCAD vs 7.62 mm KiCad) means that wires will not connect perfectly to KiCad standard R symbol pins when placed at the OrCAD midpoint. C pin-to-pin matches between OrCAD and KiCad (7.62 mm).

### Schematic Stream

Top-level schematic metadata. Contains page ordering and hierarchy information.

---

## BRD File Format (PCB editor)

### Container

**Not** an OLE compound document. Raw binary with a proprietary header.

### Header

First 32 bytes:

```
one larger board:     02 05 14 00 03 00 00 00 01 00 00 00 03 00 00 00 09 00 00 00 ...
smaller boards:      04 15 13 00 03 00 00 00 01 00 00 00 03 00 00 00 09 00 00 00 ...
```

First 4 bytes appear to be a format version. The one larger board and smaller boards use different versions, which affects the internal record format.

### String Table (one larger board, format `02 05 14 00`)

Located at offset `0x1200` in the one larger board file. Contains 5,269 sequential entries (IDs 124–5392).

**Record format**: `[4-byte LE sequential ID] [null-terminated ASCII string] [padding to 4-byte boundary]`

Example:
```
offset 0x4054: 9e 03 00 00 46 45 54 5f 53 52 43 00    → ID 926: "FET_SRC"
offset 0x4060: 9f 03 00 00 47 4e 44 00                → ID 927: "GND"
offset 0x4068: a0 03 00 00 4c 44 4f 33 5f 31 50 32 00 → ID 928: "LDO3_1P2"
```

The table contains a mix of:
- **Net names**: GND (ID 927), LDO3_1P2 (ID 928), DDR0_CAA0, PCIE_TX0_P, etc.
- **Component references**: C7, C572, R1, U1, U46, etc. (623 refs found)
- **BGA ball names**: AA10, AB11, E6, F5, etc.
- **Anonymous nets**: ANON_NET_A, ANON_NET_C, etc. (same format as in the DSN Hierarchy stream)
- **Layer names**: TOP, BOTTOM, LABEL L1–L8, etc.
- **Metadata**: TP_PAD, SILKLINE_TOP, BACK_GROUND, etc.

### String Table (smaller boards, format `04 15 13 00`)

Different format from the one larger board. Strings are **not** preceded by sequential IDs. Instead:

```
[null-terminated string] [padding to 4-byte boundary] [4-byte pointer/reference]
```

Example from one smaller board at offset `0x1348`:
```
SUPPLY_A\0\0\0     b8 3b 78 0c
GND\0              bd 3b 78 0c
SUPPLY_B\0\0       cd 3b 78 0c
```

The 4-byte values after each string share a common base (`0x0C783Bxx`) and differ by amounts that seem related to the string lengths of adjacent entries.

### Component Records (one larger board)

Component reference designators appear as embedded null-terminated strings within larger records. Located well past the string table (e.g., C572 appears at offsets `0x401fcc` and `0x402024`).

**Record structure (partially decoded)**:

```
31 00 0d fd          record type (0x31 = name/text record)
81 5b 01 00          this record's pointer/ID
80 5b 01 00          parent record pointer/ID
80 fc 0a 00          x coordinate (720,000 → 72.0mm in 100nm units?)
c8 fc 08 00          y coordinate (589,000 → 58.9mm)
00 00 05 00          type indicator + string length (5 = "C572\0")
43 35 37 32 00       "C572\0"
00 00 00             padding to 4-byte boundary
```

Following each name record is a child record (type `0x30`) containing what appears to be a footprint or pad reference:

```
30 00 0d f9          record type 0x30
82 5b 01 00          this record's pointer/ID
80 5b 01 00          parent record pointer/ID
b6 23 00 00          unknown reference (0x23B6 = 9142, not in string table)
00 00 00 00          zero
02 00 01 00          attributes (pad count? layer?)
```

**Coordinate units**: The one larger board's coordinates appear to be in units of ~100nm. C572's coordinates (720,000 × 589,000) correspond to (72.0mm × 58.9mm), matching the KiCad import position of C572 at (72, -59.2).

**The net-to-pin mapping has NOT been decoded.** The component records contain coordinate data and reference strings, but the records that associate specific pads with specific net IDs from the string table have not been identified. The string table IDs (4-byte LE values like ID 927 = GND) do appear throughout the file (GND's ID found at 279 locations), but the record format around them varies and no consistent netlist record structure has been identified.

### Embedded Text Sections

Several XML and text sections are embedded near the end of the file (offsets > 0x3580000 in the one larger board):

- **Material library**: XML, `<Vendor_Material_Lib>`
- **SPICE models**: S-expression format, `("sourceLibrary ...")`, for components like FILTER, FILTER_ARRAY
- **DFA constraints**: text table, `DFA_TABLE_NAME=z.dfa`
- **Routing settings**: key-value pairs, `ActiveClass = TOP`, `AlternativeClass = BOTTOM`, `Via = VIA0250-0600`
- **Router configuration**: Large S-expression with settings for routing, fanout, test points, via generation. Contains the layer routing directions (`"TOP" t "horizontal"`, `"L2" t "vertical"`, etc.) and design units (`"saved_dbUnits" "millimeters"`).
- **Color/visibility settings**: XML
- **3D state**: XML, `<Allegro3DSelectState_version_1_0>`

---

## What would be needed to extract a netlist from BRD

1. **Decode the pin-to-net records**: Find the record type that associates a pad (within a component) with a net ID from the string table. The data is there (both net IDs and component refs exist as strings), but the linking records have not been decoded.

2. **Handle format versions**: The one larger board (header `02 05 14 00`) and smaller boards (header `04 15 13 00`) use different internal formats. At minimum, the string table encoding differs.

3. **Cross-validate**: The KiCad PCB import provides ground truth for all 908 nets. Any BRD parser output can be validated against it.

### Alternative: extract netlist from KiCad PCB

A KiCad PCB import file contains the complete netlist in a parseable S-expression format:

- Net definitions: `(net N "net_name")` at the top level (909 entries including net 0 = unconnected)
- Component footprints: `(footprint ...)` blocks with `(property "Reference" "C572")` and pad-to-net assignments `(pad "1" ... (net 241 "LDO3_1P2"))`

This is the same data that a BRD parser would produce, since the KiCad file was imported from the Allegro design.

---

## External references

- **olefile**: Python library for reading OLE compound documents. `pip install olefile`.
- **OpenOrCadParser** (public source repository): C++20 project that partially parses OrCAD Capture `.DSN` files. Uses a "compare binary with known data" approach. Does not have structured export but demonstrates the record format analysis methodology.
- **orlib2ki** (public source repository: `fjullien/orlib2ki`): C project that converts OrCAD `.OLB` symbol library files to KiCad format. Reads an XML intermediate export of the OLB file. Key insights from its source code:
  - `grid_scale = 7.5` (default conversion factor from OrCAD cell units to KiCad units)
  - Y coordinates are negated: `pin->y = hotptY * -grid_scale`
  - Pin format: `hotptX/hotptY` = wire connection end, `startX/startY` = body connection end
  - `PinToPin` attribute in the XML `DefaultPageRec` element specifies the default pin-to-pin distance
- **scripts/dsn2kicad**: Local converter script (this repository) that reads DSN files directly and generates multi-page KiCad schematic projects. See `scripts/` section in the main CLAUDE.md for usage.
- The DSN format is OrCAD Capture 16.x (EDA vendor). The BRD format is PCB editor. They are separate products with separate binary formats connected only by a shared netlist.
