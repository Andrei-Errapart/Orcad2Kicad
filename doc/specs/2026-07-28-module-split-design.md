# Splitting `scripts/dsn2kicad.hs` into modules

Status: design, awaiting approval
Date: 2026-07-28

Spec lives under `doc/specs/` rather than the `docs/superpowers/specs/` default, to
match this repository's existing `doc/` convention.

## Problem

`scripts/dsn2kicad.hs` is a single 7,387-line `Main` module. Three concrete
costs:

- **Navigability.** 55% of the file's bytes are two generated tables that
  nobody reads, sitting in the same file as the code people do read.
- **No enforced layering.** `componentAngleFor`, a coordinate function, takes
  the CLI `Options` record. Nothing prevents that today, and nothing makes it
  visible.
- **Implicit interfaces.** Every binding is reachable from every other, so
  there is no statement anywhere of what a given area of the code offers to the
  rest.

Compile time is *not* a motivation. Measured: the generated tables compile in
0.9s of a ~8s build, so isolating them saves roughly 11% of a rebuild.

## Non-goals

- No Cabal package. The wrapper keeps invoking `ghc` directly, preserving the
  "only needs GHC installed" property.
- No behaviour change. This is a pure refactor; see Acceptance.
- No splitting of `Dsn/Page.hs` (~900 lines) in this pass. Its internal seams —
  header/properties, connectivity, placed objects — are much easier to judge
  once it is isolated. Revisit afterwards.

## Module layout

`scripts/dsn2kicad.hs` remains `Main`: docs, `tests/run.py`,
`tests/test_dsn2kicad_hk.py` and the wrapper all reference that path. Every
other module lives under `scripts/hs/`, found through `-i`. This keeps
`Dsn/`, `Emit/` and `Text/` directories out of `scripts/`, which is shared with
the Python tooling.

| Module | Contents | ~lines |
| --- | --- | --- |
| `Main` (`scripts/dsn2kicad.hs`) | CLI parsing, IO, `writeOutput`, `CliOptions` | 140 |
| `Convert` | `convertStreams` orchestration, `ConvertOptions` | 180 |
| `Emit/Page` | `generatePageSch`, page-object UUID keys | 700 |
| `Emit/Symbol` | `lib_symbols`, `generateSymbolLibrary` | 450 |
| `Emit/Project` | root sheet, `.kicad_pro`, `.kicad_wks`, `sym-lib-table` | 150 |
| `Sexpr` | `KExpr`, `renderKicad`, `esc`, `fmt` | 210 |
| `Uuid` | `deterministicUuid`, `formatUuid` | 45 |
| `Sha256` | the hash; no dependencies | 120 |
| `Dsn/Page` | `parsePage` and the page-stream record parsers | 900 |
| `Dsn/Cache` | `parseCacheSymbols`, cache graphics | 450 |
| `Dsn/Library` | raw pool strings, raw style records | 120 |
| `Dsn/Record` | record markers, page tags, cell-name scanning | 60 |
| `Model` | domain types, `RenderConfig`, naming/derivation helpers | 350 |
| `Orcad/Geometry` | coordinates, rotation, wire topology | 465 |
| `Text/Layout` | text measurement and placement | 285 |
| `Text/MetricsTables` | generated | 1785 |
| `Encoding` | codepage detection and decoders | 320 |
| `Codepage/Tables` | generated | 400 |
| `Container` | OLE compound-document and ZIP reading | 305 |
| `Utf8` | `utf8Encode`; leaf | 30 |
| `Binary` | byte accessors, small list/`Maybe` helpers | 240 |

Line counts are estimates from a dependency scan of the current file and sum to
slightly more than its 7,387 lines; treat them as relative sizes, not targets.

`Container` holds both readers deliberately. The ZIP path is `parseStoredZip`
plus `isZipArchive`, about 30 lines; a separate module for that is
fragmentation. The name matches `open_dsn_container()` on the Python side.

### Dependency direction

```
Main → Convert → Emit.{Page,Symbol,Project} → Sexpr
                                            → Uuid → Sha256, Utf8
       Convert → Dsn.{Page,Cache,Library}
       Convert → Encoding → Codepage.Tables
       Convert → Container → Binary
       Dsn.*, Emit.*, Text.Layout, Orcad.Geometry → Model → Binary
       Text.Layout → Orcad.Geometry, Text.MetricsTables
```

`Text.Layout → Orcad.Geometry` is a healthy one-way dependency and the two stay
separate. `Text.Layout` does not depend on `Sexpr` — see the
`componentFieldAt` split below.

Every non-`Main` module carries an explicit export list.

An earlier draft of this spec claimed export lists plus `-Wmissing-export-lists`
were what made the layering real. That was wrong, and the final review caught
it: GHC rejects import *cycles*, but a sideways or upward import inside an
acyclic graph compiles perfectly well, and the warning build was never wired
into anything that ships. Export lists narrow what a module can reach; they do
not constrain which modules it may reach for. Enforcement is
`tests/test_haskell_layering.py`, which parses every module's imports and
asserts each one resolves to a strictly lower layer, that the module set matches
the layer table exactly, and that every module has an export list.

## Configuration records

Three records, each layer taking exactly what it needs:

```haskell
-- Model
data RenderConfig = RenderConfig
  { useKicadPower :: Bool, useKicadRc :: Bool, useKicadFonts :: Bool }

-- Convert
data ConvertOptions = ConvertOptions
  { convertProjectName   :: String
  , convertSourceEncoding :: Maybe SourceEncoding
  , convertEmitWorksheet :: Bool
  , convertRender        :: RenderConfig
  }

-- Main
data CliOptions = CliOptions
  { cliDsnPath :: FilePath, cliOutputDir :: FilePath
  , cliConvert :: ConvertOptions }
```

Seven functions below `Convert` currently take `Options` and must take
`RenderConfig` instead:

`componentAngleFor`, `componentFieldAt`, `componentLibName`,
`emitSymbolDefinitions`, `generatePageSch`, `generateSymbolLibrary`,
`powerLibName`.

This is the only signature churn in the plan. It is what breaks
`Orcad.Geometry → Main`, and it matches what `defaultComponentTextStyle`
already does by taking a bare `Bool`.

## Cycle-breaking moves

A naive split has import cycles. Each is fixed by a targeted move:

| Cycle | Cause | Fix |
| --- | --- | --- |
| `Orcad.Geometry → Main` | `componentAngleFor` takes `Options` | `RenderConfig`, above |
| `Encoding → Dsn.Page` | `detectSourceEncoding` calls `libraryRawStrings` | invert: `Dsn.Library` exposes raw pool strings and face-name bytes; `Convert` passes them to the detector, which then depends only on `Codepage.Tables` |
| `Orcad.Geometry → Dsn.Page` | `synthesizeBusEntries` calls `busMemberPrefix` | `busMemberPrefix` is pure string parsing → `Model` |
| `Uuid → Types`, `Uuid → Encoding` | `pageObjectUuid` takes a `Page`; `deterministicUuid` uses `utf8Encode` | page-aware UUID helpers → `Emit.Page`; `utf8Encode` → `Utf8` leaf |
| `Text.Layout → Sexpr` | `componentFieldAt` returns `KExpr` | `Text.Layout` returns a placement result `(x, y, angle)`; `Emit.Page` builds the `kAt` node |
| `Dsn.Cache ↔ Dsn.Page` | `recordMarker` lives with the page parsers; `parseComponents` calls `findCellMatches` | both are shared record-scanning primitives → new `Dsn.Record` |
| `Model → Orcad.Geometry` | `symbolPinsForOutput` calls `symbolOrigin` | it computes pin geometry → `Orcad.Geometry` (which may depend on `Model`, not the reverse) |
| `Convert → Main` | `convertStreams` takes `Options` | `ConvertOptions` lives in `Convert`; `CliOptions` in `Main` wraps it |

The partition was checked mechanically against a reference graph of all 324
top-level bindings. With the moves above applied it is a DAG in eight layers:

```
L0  Binary, Codepage.Tables, Sha256, Text.MetricsTables, Utf8
L1  Dsn.Record, Encoding, Model, Uuid
L2  Container, Dsn.Library, Orcad.Geometry
L3  Dsn.Cache, Dsn.Page, Sexpr, Text.Layout
L4  Emit.Project, Emit.Symbol
L5  Emit.Page
L6  Convert
L7  Main
```

This layering is the extraction order in the migration plan.

## Build and tooling changes

These land **first**, before any module is extracted. Until they do, editing an
extracted module silently runs a stale binary, which would invalidate every
later verification step.

1. **`scripts/dsn2kicad`** — the cache key currently hashes only
   `dsn2kicad.hs`. It must hash a deterministically sorted list of relative
   filenames *and* their contents across all `.hs` files, plus the GHC version
   and the compile flags. Add `-i"$SCRIPT_DIR/hs"`. The existing
   `shasum → sha256sum → md5sum → md5` fallback chain must keep working over a
   file list.
2. **`tests/run.py`** (parent repo, `compile_haskell_converter`, line ~135) —
   add `-i`. This builds the binary for the whole 31-design suite.
3. **`tests/test_dsn2kicad_hk.py`** (submodule) — this is the load-bearing one.
   It invokes the converter as `[str(DSN2KICAD_HK), ...]` in **32 places**,
   i.e. by *executing the `.hs` through its `#!/usr/bin/env runghc` shebang*.
   There are zero explicit `runghc` argv invocations; the 28 other `runghc`
   mentions are `shutil.which("runghc")` skip guards. A shebang cannot portably
   supply a script-relative `-i`, so all 32 must move to one argv helper:
   `[runghc, f"-i{SCRIPTS_DIR / 'hs'}", str(DSN2KICAD_HK), ...]`.
4. **Generators** — `gen_codepage_tables.py` and `gen_text_metrics.py` retarget
   their splice path from `dsn2kicad.hs` to
   `scripts/hs/Codepage/Tables.hs` and `scripts/hs/Text/MetricsTables.hs`.
   Both must emit a `module … where` header and export list.
5. **Direct execution** — following from item 3, running
   `./scripts/dsn2kicad.hs` stops working once there are multiple modules.
   Decision: **the wrapper becomes the only supported entrypoint.** Drop the
   shebang, drop the executable bit, and say so in `README.md`.

## Migration order

Bottom-up. Each step compiles, passes the full acceptance check, and is a
separate commit that can be reverted alone.

Following the layering above:

1. Tooling (items 1–5 above). The cache-key regression test cannot be written
   yet — there is nothing to import — so step 1 lands the `-i` flag, the
   multi-file hashing and the argv helper against the still-single module,
   proving only that nothing broke.
2. **L0** — `Codepage/Tables`, `Text/MetricsTables`, `Binary`, `Sha256`,
   `Utf8`. **This step adds the cache-key regression test**: touch
   `Text/MetricsTables.hs`, assert the wrapper's key changes and a new binary
   is produced. It is the first step where a stale cache could hide a bug, so
   it is the first step where the test can exist.
3. **L1** — `Dsn/Record`, `Encoding` (with the detector inversion), `Uuid`,
   and `Model` **including the `RenderConfig` rewiring as its own commit**,
   since it is the only change that touches signatures broadly.
4. **L2** — `Container`, `Dsn/Library`, `Orcad/Geometry`.
5. **L3** — `Dsn/Cache`, `Dsn/Page`, `Sexpr`, `Text/Layout` (with the
   `componentFieldAt` split).
6. **L4–L5** — `Emit/Project`, `Emit/Symbol`, then `Emit/Page`.
7. **L6–L7** — `Convert`, leaving `Main` as CLI and IO only.

## Acceptance

Every step must satisfy all four. A failure means revert the step, not
rationalise the difference.

1. **Byte-identical corpus output.** All 31 designs under `tests/`, compared
   file-by-file against a reference tree captured before the refactor begins.
2. **Byte-identical option-mode output.** Default output alone does not
   exercise the `RenderConfig` rewiring at all. For a representative subset —
   at minimum 0002 (small), 0100 (large), 0120 (GBK) — also compare
   `--kicad-power`, `--kicad-rc`, `--kicad-fonts`, `--no-worksheet`, and
   `--source-encoding=cp936` on 0120.
3. **Suite parity.** `tests/run --all` compared per *check outcome*, not per
   design and not by totals: comparing counts alone lets one regression mask
   another. Baseline is 27 fail / 4 pass with the known PDF-alignment failures.
4. **Warnings.** `-Wall -Wcompat -Wincomplete-uni-patterns
   -Wmissing-export-lists` clean on every module. The monolith is currently
   clean under the first three. Note this is a developer-run build, not
   something the wrapper or CI performs — see the enforcement note above.

## Risks

- **`Model` becomes a dumping ground.** It holds types plus naming and
  derivation helpers. If it grows past ~400 lines or acquires anything with a
  dependency beyond `Binary`, split it into `Model.Types` and `Model.Naming`.
- **Interface churn cascades.** GHC recompiles dependents when an interface
  changes, so a wide `Model` change rebuilds nearly everything. Acceptable at
  ~8s.
- **Reference tree drift.** The corpus reference tree must be captured once,
  before step 1, and reused for every step. Re-capturing mid-migration would
  launder a regression into the baseline.
