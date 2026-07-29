# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Enforce the Haskell module layer order and explicit export lists.

Nothing GHC checks stops a lower-layer module from importing a higher-layer
one -- only import *cycles* are a compile error, and export lists narrow
visibility but never enforce layering.  This test is what actually enforces
the layer table described in `doc/specs/2026-07-28-module-split-design.md`
and `CLAUDE.md`; see those for the policy this backs.
"""
import re
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
HS_DIR = SCRIPTS_DIR / "hs"
MAIN_FILE = SCRIPTS_DIR / "dsn2kicad.hs"

# Layer 0 is dependency-free leaves; each later layer may import only its own
# layer or lower, never sideways or up.  Keep this in sync with the table in
# doc/specs/2026-07-28-module-split-design.md and CLAUDE.md -- adding a
# module here is how it gets placed in the DAG at all (see
# test_module_set_matches_layer_table below).
LAYERS = {
    "Binary": 0, "Codepage.Tables": 0, "Sha256": 0, "Text.MetricsTables": 0, "Utf8": 0,
    "Dsn.Record": 1, "Encoding": 1, "Model": 1, "Uuid": 1,
    "Container": 2, "Dsn.Library": 2, "Orcad.Geometry": 2,
    "Dsn.Cache": 3, "Dsn.Page": 3, "Sexpr": 3, "Text.Layout": 3,
    "Orcad.PinRelocation": 3,
    "Emit.Project": 4, "Emit.Symbol": 4,
    "Emit.Page": 5,
    "Convert": 6,
    "Main": 7,
}

# Matches "module Name.Space (exports...) where".  The parenthesised export
# list is grammatically optional (a bare "module X where" exports
# everything), so callers must check group(2) is not None to confirm one is
# actually present.  DOTALL + MULTILINE so a multi-line export list is
# captured whole, and the non-greedy ".*?" backtracks past any ")" inside the
# list (e.g. "Page(..)") until it lands on the one immediately before "where".
MODULE_RE = re.compile(
    r"^module\s+([A-Za-z][\w.]*)\s*(\(.*?\))?\s*where\b",
    re.MULTILINE | re.DOTALL,
)
IMPORT_RE = re.compile(r"^import\s+(?:qualified\s+)?([A-Za-z][\w.]*)", re.MULTILINE)


def _discover_hs_files():
    return sorted(HS_DIR.rglob("*.hs")) + [MAIN_FILE]


def _discover_modules():
    """Return {module_name: (path, has_export_list, imported_module_names)}."""
    modules = {}
    for path in _discover_hs_files():
        text = path.read_text()
        match = MODULE_RE.search(text)
        assert match is not None, f"{path}: no `module ... where` header found"
        name = match.group(1)
        has_export_list = match.group(2) is not None
        imported = [imp for imp in IMPORT_RE.findall(text) if imp != name]
        modules[name] = (path, has_export_list, imported)
    return modules


def test_module_set_matches_layer_table():
    modules = _discover_modules()
    discovered = set(modules)
    expected = set(LAYERS)
    missing = expected - discovered
    extra = discovered - expected
    assert not missing, f"modules in LAYERS but not found on disk: {sorted(missing)}"
    assert not extra, (
        f"modules found on disk but not placed in LAYERS: {sorted(extra)} -- "
        "add them to the layer table in this test (and to "
        "doc/specs/2026-07-28-module-split-design.md) before they can be used"
    )


def test_every_module_has_an_explicit_export_list():
    modules = _discover_modules()
    for name, (path, has_export_list, _imports) in sorted(modules.items()):
        assert has_export_list, (
            f"{name} ({path}) has no explicit export list -- "
            "`module X where` with no parenthesised list exports everything; "
            "give it one, including Main"
        )


def test_imports_respect_the_layer_order():
    modules = _discover_modules()
    for name, (path, _has_export_list, imports) in sorted(modules.items()):
        for imported in imports:
            if imported not in LAYERS:
                continue  # not one of ours (base, containers, bytestring, ...)
            assert LAYERS[name] > LAYERS[imported], (
                f"{name} (layer {LAYERS[name]}) imports {imported} "
                f"(layer {LAYERS[imported]}) in {path} -- a module may only "
                "import from a strictly lower layer, never its own layer or "
                "higher"
            )
