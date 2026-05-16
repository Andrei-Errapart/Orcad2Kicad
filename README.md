# Orcad2Kicad

Convert OrCAD Capture `.DSN` schematics to multi-page KiCad schematic projects.

Generates KiCad `.kicad_sch` files with wires, net labels, power symbols, component
placements, and a symbol library — preserving electrical connectivity from the
original OrCAD design.

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
directory named after the DSN file.

### dsn_dump

Debug tool for inspecting DSN file internals:

```
scripts/dsn_dump <file.DSN>
```

Walks the OLE compound document and prints all parseable records from every stream.

## Documentation

- [ORCAD_FILE_FORMAT.md](ORCAD_FILE_FORMAT.md) — DSN binary format specification
- [scripts/ksy/](scripts/ksy/) — Kaitai Struct schema sketches for DSN streams

## Tests

```
pip install -e ".[dev]"
pytest
```

## License

[MIT](LICENSE)
