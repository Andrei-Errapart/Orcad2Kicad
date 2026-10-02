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

# Regenerate the embedded Windows codepage tables (stdlib only, no dev extras)
python3 scripts/gen_codepage_tables.py
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

- **The converter.** Native Haskell, split into 20 modules under `scripts/hs/`
  plus `Main` in `scripts/dsn2kicad.hs`, reached via the `scripts/dsn2kicad`
  wrapper, which compiles and caches the whole tree with GHC (`-i scripts/hs`).
  `scripts/dsn2kicad.hs` is **`Main` only** — CLI parsing, IO, `writeOutput`,
  `CliOptions` — and is **not directly executable** (no shebang, not marked
  executable); a shebang cannot supply the `-i scripts/hs` include path a
  split module tree needs, so `./dsn2kicad.hs` cannot work. For normal use go
  through the `scripts/dsn2kicad` wrapper; `runghc -iscripts/hs
  scripts/dsn2kicad.hs` (what `tests/test_dsn2kicad_hk.py` uses) is a fine ad
  hoc alternative that supplies the include path itself. Reads both
  ZIP-backed synthetic fixtures and regular OLE `.DSN`
  files, and emits complete KiCad projects with sheets, symbols, graphics,
  connectivity, and worksheets. Imports only boot libraries (`base`,
  `bytestring`, `containers`, `array`, `directory`, `filepath`) with no C FFI.
  Its core is pure — conversion returns `Either String [(FilePath, String)]` and
  all file I/O lives in `main` / `writeOutput` — which is what makes the intended
  WASM build tractable.

  Modules form a DAG across eight dependency layers (each module may import
  only from its own layer or lower):

  ```
  L0  Binary, Codepage.Tables, Sha256, Text.MetricsTables, Utf8
  L1  Dsn.Record, Encoding, Model, Uuid
  L2  Container, Dsn.Library, Orcad.Geometry
  L3  Dsn.Cache, Dsn.Page, Sexpr, Text.Layout
  L4  Emit.Project, Emit.Symbol
  L5  Emit.Page
  L6  Convert
  L7  Main  (scripts/dsn2kicad.hs)
  ```

  Roughly: L0 is generated tables and dependency-free leaves (bytes, the SHA-256
  hash, UTF-8 encoding); L1–L2 parse the DSN/OLE container into the domain
  model; L3 turns parsed records into page/cache data plus the S-expression
  and text-layout primitives used to emit them; L4–L5 render the project
  files, symbol library, and per-page schematics; L6 (`Convert`) orchestrates
  the whole pipeline; L7 (`Main`) is CLI and IO only. **New code goes in the
  lowest layer that can hold it.** Before the split nothing enforced this —
  e.g. `componentAngleFor`, a pure coordinate function, quietly took the CLI
  `Options` record. GHC itself does not enforce the layer order (import
  *cycles* are a compile error, but a one-way import against the grain is
  not), so `tests/test_haskell_layering.py` is what catches that mistake now:
  it derives every module's layer from the table above, parses each module's
  `import` lines, and fails with the offending module pair if one imports
  sideways or up, or if a module lacks an explicit export list. Full
  module-by-module contents, the cycle-breaking moves, and the
  `RenderConfig`/`ConvertOptions` split are in
  `doc/specs/2026-07-28-module-split-design.md`.
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
- `gen_codepage_tables.py` — generates the CP932/CP936/CP950/CP1252 tables as
  the whole **`scripts/hs/Codepage/Tables.hs`** module (~185 KB). Same rule as
  the font tables: never hand-edit the generated module, edit the generator.
  They decode the `Library` string pool, which OrCAD writes in the authoring
  machine's Windows ANSI codepage without recording which one —
  `detectSourceEncoding` infers it from the design's font names,
  `--source-encoding` overrides. Read `doc/ORCAD_FILE_FORMAT.md` § String
  encoding before touching any of this; in particular, content sniffing alone
  must never select a double-byte codepage (`0°C` is also valid GBK).
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


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
