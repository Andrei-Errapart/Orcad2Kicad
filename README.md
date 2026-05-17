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
scripts/dsn2kicad <file.DSN> [output_dir]
```

Converts all schematic pages, generates a root schematic with hierarchical sheet
references, a symbol library, and a KiCad project file. Output defaults to a
directory named after the DSN file. Root schematic sheet symbols are placed
top-to-bottom, then left-to-right, so KiCad's hierarchy navigator follows the
original DSN page order. Symbol pin-name and pin-number visibility is derived
from the DSN Cache symbol records: one-pin symbols hide both labels, redundant
numeric pin names are hidden, and two-terminal symbols whose Cache pin flags hide
numbers emit hidden KiCad pin names and pin numbers.

### dsn_dump

Debug tool for inspecting DSN file internals:

```
scripts/dsn_dump <file.DSN>
```

Walks the OLE compound document and prints all parseable records from every stream.

## Documentation

- [ORCAD_FILE_FORMAT.md](ORCAD_FILE_FORMAT.md) — DSN binary format specification
- [PDF_COLORS.md](PDF_COLORS.md) — OrCAD schematic PDF color map
- [scripts/ksy/](scripts/ksy/) — Kaitai Struct schema sketches for DSN streams

## Current Limitations

- Electrical equivalence is not yet proven automatically; there is no generated
  KiCad-vs-OrCAD netlist diff.
- Parsed hierarchy nets and explicit power-symbol records are not yet used as
  authoritative conversion data.
- Component values/properties are still incomplete for many symbols.
- Output UUIDs are currently random, so repeated conversions produce noisy diffs.
- Vertical text annotations that read top-to-bottom in OrCAD are rendered
  bottom-to-top in KiCad, because KiCad normalizes text to always read
  left-to-right or bottom-to-top.

## Tests

```
pip install -e ".[dev]"
pytest
```

## License

[MIT](LICENSE)
