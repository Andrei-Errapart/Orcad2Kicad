# Browser-only web converter on GitHub Pages

Status: approved 2026-10-03
Date: 2026-10-03
Tracking: beads epic `Orcad2Kicad-7tu`

Spec lives under `doc/specs/` rather than the `docs/superpowers/specs/` default, to
match this repository's existing `doc/` convention.

## Goal

A public web page where someone drops, picks, or pastes an OrCAD `.DSN` — or a
ZIP archive containing exactly one `.DSN` — looks at the converted schematic,
and downloads the KiCad project as a ZIP.

Hard constraint from the owner: **no server-side component of any kind.** The
conversion runs in the visitor's browser and the file never leaves it. The site
is static, hosted on GitHub Pages, and redeployed by a GitHub Actions workflow
on every push to `main`.

This is the WebAssembly endgame `README.md` and `AGENTS.md` already name as the
replacement for the Pyodide path.

## Non-goals

- No backend, accounts, analytics, telemetry, or error reporting.
- No JavaScript framework, bundler, or npm build step. The site is plain HTML
  and ES modules; third-party code is vendored as files.
- No new converter features. The only Haskell change is one portability fix
  (see Haskell changes).
- No change to the Python converter, and no retirement of it here: it remains
  the differential netlist oracle.
- No OLB upload, no batch conversion, no PCB support.
- No automated in-browser test in this pass (see Risks).

## Evidence from the spike

Done on 2026-10-03 in a scratch directory; none of it is kept.

- `wasm32-wasi-ghc` 9.14.1 compiles the unmodified tree (`-O1 -iscripts/hs`) in
  about 6 s. Binary: 4.3 MB, 2.1 MB after `wasm-opt -Oz`, 0.87 MB gzipped.
- Under `wasmtime` the unmodified CLI converts `radxa_cm5_io_board_v2200.DSN`
  (1.1 MB, 19 sheets) into 24 files in about 3 s.
- Output is byte-identical to the native build **except** that every page
  loses its title-block `(date …)` line — a 32-bit `Int` bug, below. Same
  result on a second design.
- `@bjorn3/browser_wasi_shim` 0.4.2 runs the same binary under Node with an
  in-memory filesystem: 24 files, byte-identical to the `wasmtime` run. A
  non-DSN input exits 1 with the converter's own message on stderr.
- KiCanvas's project loader parses all 20 converted schematic files (file
  version `20260306`) without error. The owner confirmed in Safari that
  sheets fed from memory render.

## Architecture

```
            main thread                          Web Worker
  ┌────────────────────────────┐         ┌──────────────────────────┐
  │ app.js     state + DOM,    │         │ worker.js  (thin wrapper)│
  │            size gate       │──bytes─▶│ input.js   file/ZIP → DSN│
  │ preview.js sheet list +    │◀─files──│ runner.js  WASI shim +   │
  │            KiCanvas        │         │            dsn2kicad.wasm│
  │ archive.js files → ZIP     │         └──────────────────────────┘
  └────────────────────────────┘
```

Everything that parses the visitor's file — ZIP extraction and conversion —
runs in the worker, so the page stays responsive and one Cancel button stops
either. The main thread only checks the file's size, reads its bytes, and
transfers the buffer.

The converter is the existing `Main`, compiled as a WASI command module and
driven exactly like the CLI: the runner places the input in an in-memory
filesystem, starts the module with CLI arguments, and reads the output
directory back. No JavaScript/Haskell FFI and no second entry point, so the
binary in the browser is the one the test suite exercises.

## Layout

```
web/
  index.html
  style.css
  app.js            page state and DOM wiring; starts the worker
  input.js          bytes + filename -> { projectName, dsnBytes } | error  (no DOM)
  runner.js         wasm module + DSN + options -> files | error           (no DOM)
  worker.js         postMessage wrapper around input.js and runner.js
  archive.js        files -> ZIP bytes
  preview.js        sheet list + one KiCanvas embed
  vendor/           pinned third-party files, see Vendored code
  tests/            node --test suites for input / runner / archive
  dsn2kicad.wasm    build product, git-ignored
scripts/build-wasm  the one build script, used locally and in CI
tests/test_wasm_parity.py
.github/workflows/pages.yml
```

`web/` is the site root as served. `.gitignore` already ignores `lib/`,
`build/` and `dist/` anywhere, so none of those names are used under `web/`.

## Components

### Build — `scripts/build-wasm`

Runs `wasm32-wasi-ghc -O1 -iscripts/hs` on `scripts/dsn2kicad.hs`, then
`wasm-opt -Oz`, and writes `web/dsn2kicad.wasm`. Intermediate objects go to a
cache directory outside the tree. It expects the toolchain on `PATH`
(`source ~/.ghc-wasm/env` locally) and fails with a clear message otherwise.
Local development and CI run this same script.

### Runner — `web/runner.js`

`convert(wasmModule, dsnBytes, projectName, options)` returns
`{ ok: true, files: Map<name, Uint8Array> }` or
`{ ok: false, message: string }`.

- A fresh instance per conversion; nothing is reused between runs.
- Filesystem: `/in/<projectName>.DSN` and an empty `/out`.
- Arguments: the option flags, then `/in/<projectName>.DSN`, then `/out`. The
  input path always begins with `/in/`, so it can never be read as a flag;
  `--` is not used (it is currently broken, `Orcad2Kicad-0sz`).
- stdout and stderr are captured line by line. A non-zero exit returns stderr
  as `message`; a trap returns a generic message plus the trap text.

It touches no DOM API, so the same module runs in the worker and under Node.

### Worker — `web/worker.js`

Fetches and compiles `dsn2kicad.wasm` once, then answers each request by
running `input.js` and then the runner. The page keeps a Cancel button that
terminates the worker and starts a new one, which stops extraction as well as
conversion; there is no automatic timeout.

The worker is started from a `blob:` URL whose one-line module body imports
`worker.js` by absolute same-origin URL, rather than from `worker.js`
directly. The reason is in Privacy: a worker loaded from a network URL does
not inherit the page's Content-Security-Policy; one loaded from a `blob:` URL
does.

### Input — `web/input.js`

Three routes produce the same `(file, filename)` pair on the main thread:
drag-and-drop, a file picker, and the `paste` event when the browser exposes a
pasted file. Before reading anything, the page rejects a file whose size
exceeds the input limit (100 MB, compressed size for an archive). It then
reads the bytes and transfers the buffer to the worker, where `input.js` runs.

The container is identified by magic bytes, not by extension:

| Starts with | Treated as |
|---|---|
| OLE magic `D0 CF 11 E0 A1 B1 1A E1` | a `.DSN`; passed through |
| `PK\x03\x04` | a user archive; unwrapped here |
| anything else | error: not an OrCAD DSN or a ZIP |

A user archive is **always** unwrapped in JavaScript and never handed to the
converter: the Haskell reader treats any ZIP as a stored-only streams fixture
(`isZipArchive` in `scripts/hs/Container.hs`). Rules for the archive:

- Members are matched on a case-insensitive `.dsn` suffix; directories,
  `__MACOSX/` entries and dot-files are ignored. Other members are allowed and
  ignored, so a zipped design folder works.
- Exactly one match is required. Zero, or more than one (names listed), is an
  error; so is an encrypted archive.
- **Selection decompresses nothing.** Names and the match count come from the
  archive's directory. Members that are not the chosen DSN are never
  inflated, however large they are.
- **Extraction is bounded while it runs.** Only the chosen member is inflated,
  with the DSN limit (100 MB) on its output. The size the archive declares for
  the member is used only for an early rejection; it is never trusted as the
  bound, since it can be wrong.
- The extracted DSN must itself start with the OLE magic.

How the output bound is enforced follows from how fflate's synchronous
`Inflate` works: each `push` inflates *everything* pushed so far in one call
and only then reports the output. Counting output bytes therefore bounds
nothing on its own — one large push can allocate far past the limit before the
count is seen — and that class has no `terminate()` (only the async variants,
which start workers of their own, do). So:

- The member's compressed bytes are pushed in fixed chunks of 16 KiB.
- After each push the cumulative output is checked; past the limit, pushing
  stops and the inflater is discarded.
- DEFLATE expands at most about 1032:1, so the overshoot past the limit is at
  most about 17 MB, and peak memory is bounded by limit plus overshoot.
- fflate's async classes are not used. Cancellation of a stuck or slow
  extraction is the conversion worker's: Cancel terminates it.

This rules out fflate's `unzipSync` (its filter selects members, but a matched
member is then inflated in one call) and its streaming `Unzip` (which relies on
local headers, and archives written with data descriptors, as macOS produces,
leave sizes out of those). Member selection is instead a small reader of our
own over the archive's central directory — names, flags, compression method,
sizes, local-header offset — with every offset and length checked against the
buffer. It hands the chosen member's compressed slice to fflate's `Inflate`
as above. Stored (uncompressed) members are copied with the same limit check.

The project name is the DSN's base name without extension, with path
separators and control characters removed.

### Options

| Control | Flag |
|---|---|
| Use KiCad power symbols | `--kicad-power` |
| Use KiCad R/C symbols | `--kicad-rc` |
| Use KiCad fonts | `--kicad-fonts` |
| Omit worksheet | `--no-worksheet` |
| Source encoding (auto by default) | `--source-encoding=NAME` |

Changing an option re-runs the conversion on the file already loaded.

### Preview — `web/preview.js`

A sheet list supplied by the page, and one `<kicanvas-embed controls="basic">`
showing the selected sheet. Each sheet is given to KiCanvas from memory as an
inline `<kicanvas-source name="…" type="schematic">`; selecting another sheet
replaces the embed. The generated root sheet (only sheet boxes) is not listed.

KiCanvas's own multi-sheet navigation is not used: in embed mode it sits in a
collapsed side bar or behind a double-click on a sheet box, which is too hidden
for a 20-sheet design.

- **Colours:** the KiCad scheme. KiCanvas defaults to a dark theme and reads
  its choice from `localStorage` when its module loads, so the page writes
  `kc:prefs:theme = {"val":"kicad"}` first, inside `try`/`catch`.
- **Isolation:** a preview failure is reported next to the preview and never
  disables the download.
- **Stated limits:** the preview is indicative, not KiCad's own renderer.
  KiCanvas hardcodes the title-block sheet counter as `1/1` and draws its own
  default drawing sheet rather than the generated `.kicad_wks`.

### Download — `web/archive.js`

One ZIP named `<projectName>_kicad.zip` holding a single top-level directory
`<projectName>_kicad/` with every file the converter produced, matching the
CLI's default output directory.

## Privacy

Two separate properties, with different guarantees.

**No upload** is a property of the code, not of a policy: no code path sends
the visitor's file, or anything derived from it, anywhere. The page says so in
one sentence. It is checked by reading the source and by the browser's network
panel, and it is why the converter runs as a WASI module whose only imports
are the in-memory filesystem shim — the binary has no way to reach the
network.

**No third-party origin** is enforced by a Content-Security-Policy `<meta>`:
`default-src 'none'`, with `'self'` for scripts, styles, fonts, images and
`connect-src`, `'wasm-unsafe-eval'` for the module, and `worker-src blob:`.
Exact directives are tuned during implementation. This is defence in depth
against vendored code misbehaving; it restricts *where* a request could go,
and does not by itself prevent a request to the hosting origin.

GitHub Pages cannot send response headers of our choosing, which matters in
two ways:

- The policy can only be delivered by `<meta>`.
- A worker loaded from `worker.js` would get its policy from that script's
  response headers — of which there are none — and would run unrestricted.
  Starting the worker from a `blob:` URL makes it inherit the page's policy
  instead. Engines are expected to agree on this but it is not assumed: the
  manual checklist verifies, from inside the worker, that a request to another
  origin is blocked.

The policy requires one change to the vendored KiCanvas: it injects a
`fonts.googleapis.com` stylesheet (Material Symbols icons and Nunito). The
vendored copy points that at a self-hosted Material Symbols file instead and
lets text fall back to the system font.

## Vendored code

Committed under `web/vendor/` with a `README` recording origin, version or
commit, SHA-256, licence, and every local patch.

| Component | Use | Licence |
|---|---|---|
| KiCanvas | preview | MIT |
| `@bjorn3/browser_wasi_shim` 0.4.2 | WASI in the worker | MIT OR Apache-2.0 |
| fflate 0.8.3 | inflating the DSN member, writing the download | MIT |
| Material Symbols Outlined | KiCanvas icons | Apache-2.0 |

fflate does the decompression, the part of reading an untrusted archive that
is hardest to get right; our own code only walks the central directory (see
Input). The page footer credits these, the bundled KiCad symbols (CC-BY-SA 4.0
with the KiCad Library Exception), and links the converter's source at the
deployed commit (GPL-2.0-or-later).

## Haskell changes

One fix, `Orcad2Kicad-7tu.1`, to how the page timestamp is carried. The field
is a `u32` on disk, and the code narrows it to `Int`, which is 32 bits on
wasm32. Two failures follow:

- `plausibleTime` in `scripts/hs/Dsn/Page.hs` compares against `2208988800`
  as an `Int`. That literal wraps negative, the guard always fails, and every
  date is dropped. This is the difference the spike observed.
- Fixing only the guard is not enough. The accepted window runs to
  2040-01-01, and any stamp from 2038-01-19 on (`>= 2^31`) still wraps
  negative once narrowed — `2177452800` (2039-01-01) becomes `-2117514496` —
  and would print a wrong date.

So the timestamp stays `Word32` until it has been divided down to a day
count: `pageHeaderModified :: Maybe Word32` in `Model.hs`, the range check in
`Word32`, and `isoDateFromUnix :: Word32 -> String` dividing by `86400` before
narrowing to `Int` for `civilFromDays`. A day count is below 50,000 and fits
any `Int`.

This touches `Model.hs` and `Dsn/Page.hs`. No import changes, so the layering
test is unaffected. Nothing else in `scripts/hs/` changes.

## Testing

- **Parity — `tests/test_wasm_parity.py`.** Converts the fixtures with the
  wasm build under `wasmtime` and with the native build and requires
  byte-identical files. Skipped when the wasm toolchain is absent;
  `ORCAD2KICAD_REQUIRE_WASM=1` (set in CI) turns the skip into a failure.
- **Timestamps.** The fixture builder already takes `modified=`. Cases, run
  natively for the expected date and through the parity test for wasm: an
  ordinary stamp; `2147483647` and `2147483648` (either side of the 32-bit
  boundary, both 2038-01-19); one in 2039; and the window's two edges, just
  inside and just outside, where outside means no date line. The ordinary
  case fails on today's code under wasm; the 2038 and 2039 cases fail on a
  guard-only fix.
- **JavaScript — `node --test web/tests/`.**
  - Runner: a fixture converts to the same files as the native CLI; a corrupt
    input yields the converter's message.
  - Input, selection: DSN pass-through; archives with zero, one and several
    DSNs; nested directories; junk members; non-ZIP bytes; an encrypted
    archive; an archive written with data descriptors.
  - Input, bounds: a large non-DSN member beside the DSN is not inflated; a
    highly compressible member that inflates past the limit is stopped at the
    limit; a member whose real size exceeds its declared size is stopped at
    the limit.
  - Archive: the output ZIP reads back to the same files.
- **Manual browser checklist**, run before the first deploy and after any
  vendored update: each input route; each option; a failing file; Cancel
  during a large extraction; preview of a multi-sheet design in the KiCad
  colours; the download opens in KiCad; the network panel shows no request to
  another origin; from the worker's console, a `fetch` to another origin is
  refused with a policy violation; phone width.

## Deployment — `.github/workflows/pages.yml`

The first workflow in this repository.

- **Triggers:** push to `main`, pull requests, manual dispatch.
- **Build job:** install a pinned `ghc-wasm-meta` (the 9.14 flavour used
  locally) with caching, a native GHC, Python dev dependencies and Node; run
  `scripts/build-wasm`; run `pytest` with `ORCAD2KICAD_REQUIRE_WASM=1`; run
  the Node tests; write the commit hash into `web/version.json`, which the
  page shows in its footer and uses as a cache-busting query on the `.wasm`
  URL; upload `web/` as the Pages artifact.
- **Deploy job:** only on `main`, only after the build job passes, using the
  official Pages actions with `pages: write` and `id-token: write`.

One manual step by the owner, once: repository Settings → Pages → Source =
"GitHub Actions". The repository is public and Pages is not yet enabled.

## Implementation order

Each step maps to a child of the epic.

1. `plausibleTime` fix and its unit test (`.1`).
2. `scripts/build-wasm` (`.4`), then the parity test (`.5`).
3. Vendor the shim; `runner.js`, `worker.js` and their Node tests (`.6`).
4. `input.js`, `archive.js`, the page and options (`.7`).
5. Vendor and patch KiCanvas; `preview.js` (`.8`).
6. Workflow and first deploy (`.9`); attributions in the footer (`.10`).
7. README / `CLAUDE.md` / `AGENTS.md`, mirrored (`.11`).

## Acceptance

- A visitor converts a real `.DSN`, and a ZIP containing one, entirely in the
  browser; the browser's network panel shows no request to another origin and
  none carrying file content.
- The sheets can be browsed in the KiCad colour scheme before downloading, and
  the downloaded ZIP opens as a project in KiCad.
- wasm output is byte-identical to native output on the test fixtures, enforced
  in CI.
- A push to `main` redeploys the site with no manual step; a failing test
  blocks the deploy.

## Risks

- **KiCanvas is alpha and unversioned.** It is pinned by hash, patched in one
  place, and isolated so that its failure never blocks a download. The theme
  selection relies on an internal `localStorage` key; if a future copy changes
  it, the preview falls back to the dark theme rather than breaking.
- **Preview fidelity.** KiCanvas may draw some constructs differently from
  KiCad. The page says the preview is indicative.
- **32-bit `Int`.** The date bug shows the class exists; the parity test is the
  guard, and is only as good as the fixtures' coverage.
- **Worker policy inheritance.** The `blob:` worker inheriting the page's
  policy is specified behaviour but has not been observed here in any browser.
  If an engine does not honour it, the worker runs without a policy in that
  engine; the no-upload property is unaffected, the third-party-origin
  restriction is weakened to the page only, and the checklist will show it.
- **No automated browser test.** UI and preview regressions are caught by the
  manual checklist only. A headless browser test can be added later if that
  proves insufficient.
- **Pasting files** depends on what each browser exposes to the `paste` event;
  drag-and-drop and the file picker are the dependable routes.
