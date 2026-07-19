# Repository Guidelines

## Project Structure & Module Organization

This repository is a Python 3.9+ toolset for converting OrCAD Capture `.DSN`
schematics to KiCad projects. Core implementation lives in `scripts/`, with
CLI entry points such as `scripts/dsn2kicad`, `scripts/dsn_dump`,
and matching importable modules like `scripts/dsn2kicad.py`. Bundled KiCad symbol
libraries are in `scripts/kicad_symbols/`. Kaitai schema sketches for DSN and OLB
formats are in `scripts/ksy/`. Project documentation is in `doc/`, while `README.md`
contains user-facing usage and limitations. Tests and fixtures live under `tests/`,
including OLB fixture pairs in `tests/test_data_olb/`.

## Build, Test, and Development Commands

- `pip install -e ".[dev]"`: install the project with pytest and development-only
  font tooling.
- `pytest`: run the full test suite.
- `scripts/dsn2kicad <file.DSN> [output_dir]`: convert a schematic to a KiCad
  project.
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



