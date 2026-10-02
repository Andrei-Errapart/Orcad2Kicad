# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regenerate the committed fixtures used by the JavaScript tests.

    python3 tests/web/make_fixtures.py

The Node tests cannot import tests/dsn_fixtures.py, so the DSN they need is
built here and committed.  Output is deterministic; rerunning it on an
unchanged tree must leave git clean.
"""
import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "fixtures"


def load_dsn_fixtures():
    path = str(HERE.parent / "dsn_fixtures.py")
    loader = SourceFileLoader("dsn_fixtures", path)
    spec = importlib.util.spec_from_loader("dsn_fixtures", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def minimal_dsn(fx):
    """One page with one wire, in a real OLE container."""
    page = fx.make_page(
        "Page1", modified=1617261986,
        nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
    )
    return fx.make_ole({
        "Views/SCHEMATIC1/Pages/Page1": page,
        "Library": fx.make_library(["unused"]),
    })


def main():
    fx = load_dsn_fixtures()
    OUT.mkdir(exist_ok=True)
    (OUT / "minimal.DSN").write_bytes(minimal_dsn(fx))


if __name__ == "__main__":
    main()
