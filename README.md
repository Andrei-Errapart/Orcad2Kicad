# Orcad2Kicad

Convert OrCAD Capture `.DSN` schematics to multi-page KiCad schematic projects.

Generates KiCad `.kicad_sch` files with wires, buses, net labels, power symbols,
component placements, and a symbol library. The converter is still incomplete, though.

## Requirements

- Python 3.9+
- `olefile` (for reading OLE Compound Documents)
- Optional: `freetype-py` (for accurate text width measurement)

```
pip install olefile
```

## Usage

### dsn2kicad

Full schematic conversion:

```
scripts/dsn2kicad [--kicad-power] [--debug-bbox] <file.DSN> [output_dir]
```

Converts all schematic pages, generates a root schematic with hierarchical sheet
references, a symbol library, and a KiCad project file. Output defaults to a
directory named after the DSN file.

The `scripts/dsn2kicad` wrapper creates a small Python virtualenv on first use
under the user's cache directory, falling back to the temp directory if needed.
Set `ORCAD2KICAD_VENV=/path/to/venv` to force a specific environment.

Options:

- `--kicad-power` — Use KiCad-native power symbol graphics (VCC chevron, GND
  triangle) instead of extracted OrCAD glyphs. Power nets that exist in
  KiCad's installed `power.kicad_sym` library use the native definition directly;
  all others are derived from the VCC/GND template with the OrCAD net name.
  Without this flag, the converter extracts the original OrCAD power symbol
  glyphs (VCC_BAR, VCC_CIRCLE, GND variants) and embeds them in the symbol
  library, preserving the schematic's visual appearance.
- `--debug-bbox` — Draw debug rectangles around component bounding boxes.

Pin lengths are automatically extended so that pin numbers are readable: each
pin is at least `(max_chars + 1) * 1.27 mm` long, where `max_chars` is the
longest pin number in the symbol. Connecting wires are extended to match.

Output UUIDs are deterministic: each output file is seeded with
`SHA256(DSN content + output filename)`, so changes on one page never
cause UUID diffs on unrelated pages.

Root schematic sheet symbols are placed top-to-bottom, then left-to-right, so
KiCad's hierarchy navigator follows the original DSN page order. Symbol
pin-name and pin-number visibility is derived from the OLB `GeneralProperties`
embedded in the DSN Cache stream via `olb_parser.py`. Component values are
resolved directly from the Library stream's string table (no offset heuristic).

Only OrCAD Capture format version 3.x (files with `FF E4 5C 39` record
markers, typically OrCAD 16.x and later) is supported. Older version 2.0
files use a different binary layout and cannot be parsed.

### dsn_dump

Debug tool for inspecting DSN file internals:

```
scripts/dsn_dump <file.DSN>
```

Walks the OLE compound document and prints all parseable records from every stream.

## Documentation

- [ORCAD_FILE_FORMAT.md](ORCAD_FILE_FORMAT.md) — DSN binary format specification
- [PDF_COLORS.md](PDF_COLORS.md) — OrCAD schematic PDF color map
- [scripts/ksy/](scripts/ksy/) — Kaitai Struct schema sketches for DSN and OLB streams

## Current Limitations

- Connector symbols (CON*) show only a body rectangle; the circle/arc pin
  graphics from the original OLB library are not embedded in the DSN Cache.
- OrCAD format version 2.0 files are not supported (different binary layout).

## Tests

```
pip install -e ".[dev]"
pytest
```

## License

[MIT](LICENSE)
