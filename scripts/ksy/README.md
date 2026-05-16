# Kaitai Struct sketches for OrCAD Capture DSN streams

These `.ksy` files are exploratory sketches of the binary layouts inside the
OLE compound streams of an OrCAD Capture 16.x `.DSN` file. The container
itself (OLE Compound Document) is handled by `olefile`; each `.ksy` here
describes one decompressed stream that `olefile` extracts.

Status: **sketches, not validated against the Kaitai Web IDE yet.** They
encode the layouts inferred from `scripts/dsn2kicad` and
`ORCAD_FILE_FORMAT.md`. Several streams use a "find marker, then unpack
fixed offsets" approach in the script because record boundaries are not
strictly length-prefixed — this is modeled below with marker resync where
needed.

| File | Stream(s) | Source in dsn2kicad |
|------|-----------|---------------------|
| `dsn_common.ksy` | shared types (record_marker, length_string) | n/a |
| `dsn_stream.ksy` | `DsnStream` | docs only — JSON blob |
| `dsn_page.ksy` | `Views/SCHEMATIC1/Pages/<page>` | `parse_page_header`, `parse_net_table`, `parse_wires`, `parse_components`, `_parse_pin_records`, `parse_power_symbols`, `parse_text_annotations`, `parse_page_graphics` |
| `dsn_cache.ksy` | `Cache` | `parse_cache_cells`, `_parse_cache_graphics` |
| `dsn_library.ksy` | `Library` | `parse_title_block` (heuristic) and 60-byte style records |
| `dsn_hierarchy.ksy` | `Views/SCHEMATIC1/Hierarchy/Hierarchy` | `parse_hierarchy_nets` |
| `dsn_directory.ksy` | `Cells Directory`, `Parts Directory`, `Packages Directory`, `Symbols Directory`, `Views Directory`, `ExportBlocks Directory`, `Graphics Directory` | reverse-engineered from CPU board sample, all 104 Cells/Parts entries consumed exactly |

Streams not modeled (no parser in `dsn2kicad`, format unknown):
`AdminData`, `NetBundleMapData`, `Packages/*` (per-unit binary, not the
index), `HSObjects`, `Symbols/*`, `Graphics/*`,
`Views/SCHEMATIC1/Schematic`.

## Marker resync caveat

Many record types in DSN page and Cache streams are located by scanning for
the 4-byte marker `FF E4 5C 39` and then unpacking known offsets relative
to the marker. Kaitai prefers strictly described layouts; here we model
records as `repeat-until: _io.eof` with a parametric "skip until marker"
helper. This loses some declarativeness but matches what `dsn2kicad`
actually does — the format has padding/unknown bytes between records that
have not been fully reverse-engineered.

A stricter alternative (record header with explicit length field) may
become possible once more of the format is known. Treat these sketches as
a starting grammar to refine in the Kaitai Web IDE against real samples.

## Coordinate units

- Page streams: int16 or int32 LE, units of 10 mils = 0.254 mm. Y grows downward.
- Cache stream: int32 LE, same 10-mil units.
- The `.ksy` files leave coordinates as raw signed integers; conversion to
  mm and Y-flip is application logic.
