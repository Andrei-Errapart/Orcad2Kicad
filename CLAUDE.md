# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

The **Orcad2Kicad converter** — a pure-Python toolset that converts OrCAD Capture
`.DSN` schematics into multi-page KiCad schematic projects (wires, buses, net
labels, power symbols, component placements, and a generated symbol library).

This repo is a git submodule. Its real-world `.DSN` fixtures, expected KiCad
output, and the semantic integration-test harness live in the **parent repo**
(`Orcad2Kicad_Test/`, see `../CLAUDE.md`). This repo holds the converter plus its
own fast unit tests. `AGENTS.md` (this directory) covers commit/PR and code-style
conventions — read it before contributing.

## Commands

```bash
# Install (adds pytest + dev-only font tooling) and run the unit tests
pip install -e ".[dev]"
pytest                                   # ~93 unit tests, no external fixtures
pytest tests/test_logic.py -k power      # single file / filtered

# From the PARENT repo instead, the shared venv runs these same tests:
#   .venv/bin/pytest orcad2kicad/tests/

# Convert a schematic (wrapper auto-bootstraps a cache-dir venv on first run)
scripts/dsn2kicad [--kicad-power] [--kicad-rc] [--kicad-fonts] [--no-worksheet] \
                  [--debug-bbox] [--debug-ref-val] [--debug-symbol] <file.DSN> [out_dir]

# Debug / inspection tools
scripts/dsn_dump <file.DSN>              # walk OLE streams, print parsed records
scripts/olb2xml <file.OLB>              # dump OLB library as XML

# Regenerate the committed font metric tables after changing the char/font set
python3 scripts/gen_text_metrics.py     # needs dev extras (freetype-py + fonttools)
```

The only **runtime** dependency is `olefile` (pure Python) — `freetype-py` /
`fonttools` are dev/tooling-only. The converter reads no font files
and has no native deps, so the core path runs unchanged in a browser via Pyodide.

## Architecture

**The Python converter is feature-frozen — put new work in the Haskell one.**
`scripts/dsn2kicad.hs` is the converter that grows; `scripts/dsn2kicad_py.py` is
kept only for the browser/Pyodide path and as the differential netlist oracle in
`tests/test_dsn2kicad_hk.py`. The two are **not** kept at feature parity, so a
gap between them is expected rather than a bug. Do not port Haskell features
into Python, and do not "fix" Python to close a parity gap. See `AGENTS.md`
(Implementation Policy) for the full rule.

**Pipeline:** OLE compound document (`.DSN`) → parse the streams
(`Views/SCHEMATIC1/Pages/*`, `Cache`, `Library`, `Hierarchy`) → emit KiCad files.
Everything happens in memory:

- `convert_dsn(ole, dsn_bytes, *, project_name, ...)` is the core — returns
  `{filename: text}` for the whole project with **no disk I/O**.
- `main()` (CLI) reads the file and writes the dict to `out_dir/`.
- `convert_dsn_bytes(data, ...)` (browser/Pyodide) takes raw bytes, returns the
  same dict. Both go through `open_dsn_container()` which sniffs magic bytes.

**Key modules (all under `scripts/`):**

- `dsn2kicad.hs` (~6700 lines) — **the converter.** Native Haskell, reached via
  the `scripts/dsn2kicad` wrapper, which compiles and caches it with GHC. Reads
  both ZIP-backed synthetic fixtures and regular OLE `.DSN` files through its own
  Compound File reader, and emits complete KiCad projects with sheets, symbols,
  graphics, connectivity, and worksheets. Imports only boot libraries (`base`,
  `bytestring`, `containers`, `array`, `directory`, `filepath`) with no C FFI.
  Its core is pure — conversion returns `Either String [(FilePath, String)]` and
  all file I/O lives in `main` / `writeOutput` — which is what makes the intended
  WASM build tractable.
- `dsn2kicad_py.py` (~6400 lines) — the **feature-frozen** Python converter
  monolith, reached via the `scripts/dsn2kicad_py` wrapper. Roughly ordered as:
  `parse_*` (binary stream decoders) → `sch_*` / `lib_symbol_*` (KiCad
  S-expression emitters) → geometry/placement helpers → `generate_page_sch` /
  `generate_root_sch` / `generate_project` → `convert_dsn`. Find things by
  function name, not line number. Still the reference for the browser/Pyodide
  path, and the netlist-level comparison target in the Haskell regression suite.
- `olb_parser.py` — binary reader for OLB / DSN `Package` & `Library` streams
  (a Python port of OpenOrCadParser's prefix/checkpoint framework). Source of
  component values and pin-name/number visibility.
- `ole_zip.py` — lets the converter ALSO accept a **ZIP archive** whose members
  are the OLE streams. `olefile` is read-only, so synthetic `.DSN` test fixtures
  are authored as ZIPs instead. `ZipOleFile` duck-types the `olefile` subset used.
- `kicad_sexpr.py` — S-expression `parse()` / `find_first()` / `find_all()` /
  `strip_quotes()` / `to_float()`. Reuse for any KiCad-file manipulation.
- `text_metrics.py` + `text_metrics_data.py` — pure-Python text-width/height
  measurement from precomputed tables (Liberation Sans/Narrow/Mono ≡ Arial /
  Arial Narrow / Courier New advance widths, plus KiCad Newstroke).
  **`text_metrics_data.py` is generated** by `gen_text_metrics.py` — never
  hand-edit it; edit the generator and regenerate.
- `scripts/kicad_symbols/` — bundled `power.kicad_sym` / `Device.kicad_sym`
  (CC-BY-SA 4.0 + KiCad Library Exception, see `NOTICE`), used only for
  `--kicad-power` / `--kicad-rc` so no KiCad install is required.
- `scripts/ksy/` — Kaitai Struct sketches documenting the DSN/OLB binary layouts
  (exploratory, not validated; `doc:` line numbers are stale — trust names).

## Key Details

- **Module-level global state is the main gotcha.** `dsn2kicad_py.py` accumulates
  per-cell data in module-level dicts (`_cell_pin_defs`, `_cell_body_rects`,
  `_cell_centers`, `_multi_unit_groups`, `_library_value_strings`, …) and sets
  option flags (`_use_kicad_power`, `_use_kicad_rc`, `_use_kicad_fonts`) inside
  `convert_dsn`. Consequences: a single process must NOT run conversions with
  different options concurrently, and tests reset this state via the `reset_globals`
  autouse fixture in `tests/conftest.py`. **If you add a new module-level registry,
  add it to `reset_globals` too**, or tests will bleed state between cases.
- Tests import the converter with `SourceFileLoader` (the CLI file is named
  `dsn2kicad` with no `.py`, so the module is loaded explicitly). Session fixtures
  in `conftest.py`: `dsn2kicad`, `ole_zip`, `dsn_fixtures`.
- Only OrCAD Capture format **v3.x** (records marked `FF E4 5C 39`, OrCAD 16.x+)
  is supported. v2.0 files use a different layout and are rejected.
- Output UUIDs are **deterministic**: seeded with `SHA256(dsn_bytes + filename)`,
  so an edit on one page never churns UUIDs on unrelated pages.
- Coordinate unit: `UNIT_TO_MM = 0.254` (OrCAD's 10-mil unit).
- The `scripts/dsn2kicad_py` wrapper builds a private venv
  under the user cache dir (`ORCAD2KICAD_VENV` overrides); `scripts/olb2xml`
  instead uses the parent repo's `.venv`. None of these are `pip install -e`.
- Reference/Value text placement is derived from OrCAD display-property records
  and verified against the original OrCAD PDF (the harness for that lives in the
  parent repo). Before touching font placement/measurement read
  `doc/KICAD_FONTS.md`; for power-net classification read `doc/POWER_NET_DETECTION.md`;
  for the binary format read `doc/ORCAD_FILE_FORMAT.md`.
