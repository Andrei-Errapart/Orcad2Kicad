# Orcad2Kicad

Convert OrCAD Capture `.DSN` schematics to multi-page KiCad schematic projects.

Generates KiCad `.kicad_sch` files with wires, buses, net labels, power symbols,
component placements, and a symbol library. The converter is still incomplete, though.

## Requirements

- Python 3.9+
- `olefile` (for reading OLE Compound Documents) — the **only** runtime dependency

```
pip install olefile
```

Text widths are measured from precomputed pure-Python tables
(`scripts/text_metrics.py` + `scripts/text_metrics_data.py`) — no native font
library and no font files are needed at runtime, so the converter runs anywhere
CPython runs, including in a browser via Pyodide. See
[Browser / in-memory use](#browser--in-memory-use-pyodide).

## Usage

### dsn2kicad

Full schematic conversion:

```
scripts/dsn2kicad [--kicad-power] [--kicad-rc] [--no-worksheet] [--debug-bbox] [--debug-ref-val] [--debug-symbol] <file.DSN> [output_dir]
```

Converts all schematic pages, generates a root schematic with hierarchical sheet
references, a symbol library, a KiCad project file, and, by default, a
project-local zero-margin worksheet (`.kicad_wks`). The worksheet keeps KiCad's
standard border, coordinate markers, and title block, but uses page-corner
anchors with zero margins so it follows the original sheet size instead of
applying KiCad's default drawing-sheet inset. Output defaults to a directory
named after the DSN file.

The `scripts/dsn2kicad` wrapper creates a small Python virtualenv on first use
under the user's cache directory, falling back to the temp directory if needed.
Set `ORCAD2KICAD_VENV=/path/to/venv` to force a specific environment.

Options:

- `--kicad-power` — Use KiCad-native power symbol graphics (VCC chevron, GND
  triangle) instead of extracted OrCAD glyphs. Power nets that exist in the
  bundled `power.kicad_sym` library use the native definition directly;
  all others are derived from the VCC/GND template with the OrCAD net name.
  Without this flag, the converter extracts the original OrCAD power symbol
  glyphs (VCC_BAR, VCC_CIRCLE, GND variants) and embeds them in the symbol
  library, preserving the schematic's visual appearance.
- `--kicad-rc` — Use KiCad's standard `Device:R` and `Device:C` symbols for
  OrCAD resistor and capacitor cells. Resistor Reference/Value fields may be
  nudged just enough to avoid overlapping the shorter KiCad resistor body, and
  wires are extended to the native pin hotpoints. Capacitor Reference/Value
  placement remains the OrCAD-derived placement.
- `--no-worksheet` — Do not emit or reference the project-local worksheet; KiCad
  will use its configured/default drawing sheet instead.
- `--debug-bbox` — Draw debug rectangles around component bounding boxes.
- `--debug-ref-val` — Overlay text-placement markers on every component: a red
  circle at the instance origin (`loc`) tagged with the mirror flag (`H`), plus
  smaller light-grey circles at the raw OrCAD Reference/Value display-prop
  corners before rotation/mirror. For power symbols, the light-grey marker is
  the raw Value display-prop corner interpreted relative to the upper-left
  corner of the OrCAD power-port record bbox.
- `--debug-symbol` — Draw each symbol's bounding box (the Cache `SymbolBBox`, the
  pivot for ref/value placement) as a light-blue rectangle. Power-symbol
  records use their page-record bbox for this overlay.

Reference and Value text is placed from OrCAD display-property records. Each
record gives the raw page-space top-left corner of the rendered text box. The
converter measures the field text, moves that corner to the box centre, applies
a perpendicular nudge, and emits centre-justified KiCad fields. This keeps
rotated and mirrored parts aligned with the OrCAD PDF without
orientation-specific KiCad justification tables.
Visible power-symbol Values use the same extracted schematic text style (size,
face, bold, italic) as component Reference/Value fields, so KiCad renders their
net names at the same visual size. For power symbols, OrCAD stores the Value
display-prop offset relative to the upper-left corner of the power-port record
bbox; the converter uses that corner as the raw text-box top-left and then
emits a centre-justified KiCad Value field. Power-symbol instances are placed
from OrCAD power-port records, including analog-ground (`AG`) records and
unmatched stray records; the converter does not synthesize extra power symbols
from wire endpoints. Whether a power symbol's Value (net name) is shown is
taken from the record itself — a port whose value carries a display-prop shows
it, one without (typically a plain `GND` triangle) hides it — rather than from a
net-name match, so a `GND` that OrCAD does label still shows its text.

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

### Browser / in-memory use (Pyodide)

The converter has no native dependencies and reads/writes nothing from disk in
its core path, so it runs unchanged in a browser single-page app under
[Pyodide](https://pyodide.org). Use the in-memory entry point instead of the CLI:

```python
import dsn2kicad

# data: the uploaded .DSN file's bytes; returns {filename: text} for the whole
# KiCad project (page .kicad_sch files, root .kicad_sch, .kicad_sym,
# sym-lib-table, .kicad_wks, .kicad_pro). No filesystem access.
files = dsn2kicad.convert_dsn_bytes(data, project_name="my_board")
# Options forward to the converter, e.g.:
#   convert_dsn_bytes(data, use_kicad_power=True, use_kicad_rc=True)
```

In a page, install the one pure-Python dependency and load the scripts:

```js
const pyodide = await loadPyodide();
await pyodide.loadPackage("micropip");
await pyodide.runPythonAsync(`import micropip; await micropip.install("olefile")`);
// Put dsn2kicad.py, olb_parser.py, kicad_sexpr.py, text_metrics.py,
// text_metrics_data.py (and scripts/kicad_symbols/ for --kicad-power/-rc) on
// Pyodide's filesystem, then call convert_dsn_bytes with the uploaded bytes.
```

`--kicad-power` / `--kicad-rc` work without a KiCad install because the needed
symbols are bundled (`scripts/kicad_symbols/`); the default mode needs no symbols
at all (OrCAD power glyphs come from the DSN itself).

### dsn_dump

Debug tool for inspecting DSN file internals:

```
scripts/dsn_dump <file.DSN>
```

Walks the OLE compound document and prints all parseable records from every stream.

## Documentation

- [ORCAD_FILE_FORMAT.md](ORCAD_FILE_FORMAT.md) — DSN binary format specification
- [ORCAD_PDF_FORMAT.md](ORCAD_PDF_FORMAT.md) — OrCAD PDF format: colors and wire geometry
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

## Regenerating the font tables

`scripts/text_metrics_data.py` is generated and committed; runtime never needs
fonts. To rebuild it (e.g. after changing the character set), install the dev
extras (`pip install -e ".[dev]"`, which adds `freetype-py` + `fonttools`) and run:

```
python3 scripts/gen_text_metrics.py
```

It measures the Arial / Arial Narrow / Courier New families from metric-compatible
fonts and parses KiCad's Newstroke stroke font (downloaded on demand). The
generated advances reproduce the previous freetype measurements exactly.

## License

The converter is [MIT](LICENSE).

Bundled third-party data carries its own license — see
[`scripts/kicad_symbols/NOTICE`](scripts/kicad_symbols/NOTICE): the KiCad symbol
libraries (`power.kicad_sym`, `Device.kicad_sym`) are CC-BY-SA 4.0 with the KiCad
Library Exception, and the Newstroke-derived font metrics originate from KiCad
(GPL-2.0-or-later).
