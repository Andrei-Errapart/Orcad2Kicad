# Repository Guidelines

## Project Structure & Module Organization

This repository is a Haskell + Python 3.9+ toolset for converting OrCAD Capture
`.DSN` schematics to KiCad projects. Core implementation lives in `scripts/`.
The naming rule is **bare name = wrapper, name + extension = source**:
`scripts/dsn2kicad` (primary) compiles and caches `scripts/dsn2kicad.hs`, while
`scripts/dsn2kicad_py` runs `scripts/dsn2kicad_py.py` in a bootstrapped venv.
Other CLI entry points such as `scripts/dsn_dump` follow the same pattern with
matching importable modules. Bundled KiCad symbol
libraries are in `scripts/kicad_symbols/`. Kaitai schema sketches for DSN and OLB
formats are in `scripts/ksy/`. Project documentation is in `doc/`, while `README.md`
contains user-facing usage and limitations. Tests and fixtures live under `tests/`,
including OLB fixture pairs in `tests/test_data_olb/`.

## Implementation Policy: Haskell Is the Only Growing Converter

`scripts/dsn2kicad.hs` is the converter. `scripts/dsn2kicad_py.py` is
**feature-frozen** and is not kept at parity with it.

- Land all new converter features, format support, and output changes in the
  Haskell implementation. Do not port them to Python.
- A capability the Haskell converter has and the Python one lacks is expected,
  not a bug. Do not file it or fix it as a parity gap.
- Change `dsn2kicad_py.py` only for the two things it still exists to do: serve
  the browser/Pyodide path, and act as the differential netlist oracle in
  `tests/test_dsn2kicad_hk.py`. A Python fix outside those two reasons should
  instead be a Haskell fix.
- The differential tests compare exported **netlist connectivity**
  (`_net_pin_groups`), not output text, so Haskell features that Python lacks do
  not break them. If one does start failing, fix the Haskell side or narrow the
  comparison — do not add the missing feature to Python to make it pass.

The intended endgame is a WebAssembly build of the Haskell converter replacing
the Pyodide path, after which the Python implementation is deleted.

## Build, Test, and Development Commands

- `pip install -e ".[dev]"`: install the project with pytest and development-only
  font tooling.
- `pytest`: run the full test suite.
- `scripts/dsn2kicad <file.DSN> [output_dir]`: convert a schematic to a KiCad
  project (Haskell, primary; needs GHC).
- `scripts/dsn2kicad_py <file.DSN> [output_dir]`: same via the Python converter.
- `scripts/dsn_dump <file.DSN>`: inspect DSN internals for debugging.
- `python3 scripts/gen_text_metrics.py`: regenerate committed text metric tables
  after changing the supported character/font set.

## Coding Style & Naming Conventions

Use idiomatic Python with 4-space indentation, `snake_case` functions, and
clear constants in `UPPER_CASE`. Keep CLI wrappers executable and keep reusable
logic in `.py` modules. Preserve existing GPL SPDX headers on new source files.
Prefer deterministic output and structured parsers over ad hoc binary/string
handling. `scripts/text_metrics_data.py` is generated; edit the generator instead
of hand-editing the table.

The Haskell converter (`scripts/dsn2kicad.hs` plus `scripts/hs/`) follows the
same generated-file rule (`scripts/hs/Codepage/Tables.hs` and
`scripts/hs/Text/MetricsTables.hs` are generated; edit the generator, not the
table) plus two module-boundary rules: every module including `Main` carries
an explicit export list, and imports must respect the layer order in
`doc/specs/2026-07-28-module-split-design.md` — a module may depend only on
its own layer or lower, never sideways or up. Neither rule is a compile
error (GHC only rejects import *cycles*, not sideways/upward imports against
the layer order); both are enforced by `tests/test_haskell_layering.py`,
which discovers every module, checks each has an export list, and checks
every import respects the layer table.

## Testing Guidelines

Tests use `pytest`. Name test files `tests/test_*.py` and test functions
`test_*`. Put shared fixtures in `tests/conftest.py` or small helper modules such
as `tests/dsn_fixtures.py`. When changing binary parsing or conversion output,
add focused fixture coverage and run `pytest` before submitting.

## Commit & Pull Request Guidelines

Include screenshots or generated KiCad/PDF comparisons when visual schematic output changes.

Use commit messages that help reviewers understand the observable effect of the change without inventing unsupported context.

### Subject

Write a concise, imperative subject line that is understandable in `git log --oneline`.

A prefix is optional. Add one, formatted as `prefix: subject`, only when at least one of these applies:

- A ticket ID is available from the user request, branch name, issue, or surrounding commits (for example `SEI-2196:`).
- The commit mostly concerns one project or component (for example `shopup6:` or `RestDbCore:`).
- A topic clearly describes the nature of the change (for example `CI`, `Doku`, `Bereinigung`, `Tippfehler`, `Korrektur`).

Multiple prefixes are permitted when more than one applies; chain them with colons, for example `SEI-2196: CI: ...`. Omit the prefix when none of these reasons applies. Do not invent ticket IDs, scopes, or prefixes.

Examples:

```text
Login-Weiterleitung nach Sitzungsablauf korrigieren
```

```text
ABC-123: Device-Tree-Overlay-Erzeugung aktualisieren
```

```text
CI: MSI-Kopier-Exitcode korrigieren
```

```text
SEI-2196: CI: MSI-Kopier-Exitcode korrigieren
```

### Body decision

After writing the subject, decide whether the subject alone is sufficient to understand the observable effect of the commit.

Use a subject-only commit when the subject is enough.

Add a body after a blank line when the subject would leave important context unclear, such as what behavior changed, what limitation was addressed, or what notable files, flows, or interfaces were affected.

### Body contents

When a body is needed, summarize the relevant context and important changes. Focus on information that helps a reviewer understand the commit.

Prefer explaining the user-visible, reviewer-relevant, or operational effect of the change over restating low-level implementation details that are obvious from the diff.

### Rationale

Include rationale only when it is directly supported by explicit evidence, such as the user request, issue text, failing test, error message, design note, code comment, or reviewed source material.

If the rationale is not clear from the available context, do not infer it.

### Tests, docs, and verification

Mention tests, documentation updates, setup commands, screenshots, manual checks, or other verification only when they were actually performed, reviewed, or explicitly provided.

Do not invent test results, claim verification that was not done, or imply that documentation was updated when it was not.




<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
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
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
