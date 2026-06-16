# Kaitai Struct sketches for OrCAD Capture binary streams

These `.ksy` files are exploratory sketches of the binary layouts inside the
OLE compound streams of OrCAD Capture 16.x `.DSN` and `.OLB` files. The
container (OLE Compound Document) is handled by `olefile`; each `.ksy` here
describes one decompressed stream that `olefile` extracts.

Status: **sketches, not validated against the Kaitai Web IDE yet.** They
encode the layouts inferred from `scripts/dsn2kicad.py`, `scripts/olb_parser.py`,
and `doc/ORCAD_FILE_FORMAT.md` (line numbers in some `.ksy` `doc:` blocks are
stale — find converter functions by name).

Note: `scripts/dsn2kicad` is a venv-bootstrap shell wrapper; the actual parser
is `scripts/dsn2kicad.py`. The function-name references below are accurate, but
line numbers that used to appear in the per-record `doc:` blocks have not been
kept in sync as the parser grew — locate functions by name, not by line.

## DSN files

| File | Stream(s) | Source |
|------|-----------|--------|
| `dsn_common.ksy` | shared types (record_marker, length_string) | n/a |
| `dsn_stream.ksy` | `DsnStream` | **docs only** — JSON blob; not read by `dsn2kicad.py` |
| `dsn_page.ksy` | `Views/SCHEMATIC1/Pages/<page>` | `dsn2kicad.py`: `parse_page_header`, `parse_net_table`, `parse_wires`, `parse_net_aliases`, `parse_components`, `_parse_pin_records`, `parse_power_symbols`, `parse_text_annotations`, `parse_page_graphics`, `_parse_page_polygon` |
| `dsn_cache.ksy` | `Cache` | `dsn2kicad.py`: `parse_cache_cells`, `_parse_cache_graphics`, `_parse_cache_pin_numbers`, `parse_cache_pin_visibility`, `parse_cache_bboxes`, `extract_orcad_power_glyphs` |
| `dsn_library.ksy` | `Library` | `dsn2kicad.py`: `parse_library_styles` (60-byte style records); `parse_title_block` and `parse_library_value_strings` (the latter via `olb_parser.parse_library_stream`) |
| `dsn_hierarchy.ksy` | `Views/SCHEMATIC1/Hierarchy/Hierarchy` | `dsn2kicad.py`: `parse_hierarchy_nets` |
| `dsn_directory.ksy` | `Cells Directory`, `Parts Directory`, etc. | **docs only** — from external stream inspection; not parsed by `dsn2kicad.py` |

`dsn2kicad.py` opens only these DSN streams: each `Views/SCHEMATIC1/Pages/<page>`,
`Cache`, `Library`, and `Views/SCHEMATIC1/Hierarchy/Hierarchy`. Everything else
(`AdminData`, `NetBundleMapData`, `Packages/*`, `HSObjects`, `Symbols/*`,
`Graphics/*`, `Views/SCHEMATIC1/Schematic`, and the `*Directory` index streams)
is unmodeled by the converter; `dsn_directory.ksy` and `dsn_stream.ksy` are
docs-only sketches, not backed by converter code.

## OLB files

| File | Stream(s) | Source |
|------|-----------|--------|
| `olb_common.ksy` | shared types (preamble, prefix, logfont, len_string) | `olb_parser.py` |
| `olb_library.ksy` | `Library` | `olb_parser.py`: `parse_library_stream` |
| `olb_primitives.ksy` | graphic primitives (line, rect, arc, ellipse, polyline, polygon, bezier, comment_text, bitmap) | `olb_parser.py`: `read_prim_*` |
| `olb_package.ksy` | `Packages/<name>` | `olb_parser.py`: `parse_package_stream`, `read_part_cell`, `read_library_part`, `read_symbol_pin`, `read_package_struct`, `read_device` |

The `Packages Directory` stream shares the same format as DSN directory
streams; use `dsn_directory.ksy`.

### Can the OLB format be fully described with Kaitai Struct?

Approximately 85–90% of the format is declaratively expressible.  The
remaining issues are:

1. **Prefix count backtracking** — the number of prefix entries per
   structure is fixed per type but must be determined empirically.
   Known counts are hardcoded; `LibraryPart` varies across files.
2. **u16/u32 ambiguity** — the Library stream's string-list length
   field is u16 in some files and u32 in others, detected by a
   value-range heuristic.  The ksy uses u16 as default.
3. **Optional preamble** — preambles before `GeneralProperties` may
   be absent; Kaitai cannot peek without consuming bytes.
4. **Checkpoint jumps** — `LibraryPart` uses prefix offsets to seek
   past unknown gaps between primitives and pins.  Modeled as
   sequential reading, which may fail if unknown gaps exist.
5. **OLE container** — Kaitai does not parse OLE Compound Documents;
   `olefile` (or equivalent) is needed to extract streams first.

## Marker resync caveat (DSN only)

Many record types in DSN page and Cache streams are located by scanning for
the 4-byte marker `FF E4 5C 39` and then unpacking known offsets relative
to the marker. Kaitai prefers strictly described layouts; here we model
records as `repeat-until: _io.eof` with a parametric "skip until marker"
helper. This loses some declarativeness but matches what `dsn2kicad`
actually does — the format has padding/unknown bytes between records that
have not been fully determined.

A stricter alternative (record header with explicit length field) may
become possible once more of the format is known. Treat these sketches as
a starting grammar to refine in the Kaitai Web IDE against real samples.

## Coordinate units

- DSN page streams: int16 or int32 LE, units of 10 mils = 0.254 mm. Y grows downward.
- DSN Cache stream: int32 LE, same 10-mil units.
- **Polygon/polyline vertex pairs are stored swapped as (y, x), not (x, y)** —
  this applies to both the page-stream `0x2c2c` filled-polygon record and the
  Cache `0x2c2c`/`0x2d2d` polygon/polyline records. Line/rectangle/ellipse
  records store coordinates in normal (x, y) order. Vertex coordinates use
  int16 LE even though the same streams use int32 for box corners.
- OLB package streams: int32 LE for pin coordinates; int16 LE for point
  lists (polyline/polygon/bezier). Same 10-mil units.
- The `.ksy` files leave coordinates as raw signed integers; conversion to
  mm and Y-flip is application logic.
