# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"

_dsn2kicad_mod = None


def _load_dsn2kicad():
    global _dsn2kicad_mod
    if _dsn2kicad_mod is None:
        path = str(SCRIPTS_DIR / "dsn2kicad_py.py")
        loader = SourceFileLoader("dsn2kicad", path)
        spec = importlib.util.spec_from_loader("dsn2kicad", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        _dsn2kicad_mod = mod
    return _dsn2kicad_mod


@pytest.fixture(scope="session")
def dsn2kicad():
    return _load_dsn2kicad()


_ole_zip_mod = None


def _load_ole_zip():
    global _ole_zip_mod
    if _ole_zip_mod is None:
        path = str(SCRIPTS_DIR / "ole_zip.py")
        loader = SourceFileLoader("ole_zip", path)
        spec = importlib.util.spec_from_loader("ole_zip", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        _ole_zip_mod = mod
    return _ole_zip_mod


@pytest.fixture(scope="session")
def ole_zip():
    return _load_ole_zip()


_dsn_fixtures_mod = None


def _load_dsn_fixtures():
    global _dsn_fixtures_mod
    if _dsn_fixtures_mod is None:
        path = str(Path(__file__).resolve().parent / "dsn_fixtures.py")
        loader = SourceFileLoader("dsn_fixtures", path)
        spec = importlib.util.spec_from_loader("dsn_fixtures", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        _dsn_fixtures_mod = mod
    return _dsn_fixtures_mod


@pytest.fixture(scope="session")
def dsn_fixtures():
    return _load_dsn_fixtures()


@pytest.fixture(autouse=True)
def reset_globals(dsn2kicad):
    dsn2kicad._cell_pin_defs.clear()
    dsn2kicad._cell_body_rects.clear()
    dsn2kicad._cell_body_lines.clear()
    dsn2kicad._cell_body_ellipses.clear()
    dsn2kicad._cell_body_arcs.clear()
    dsn2kicad._cell_body_polygons.clear()
    dsn2kicad._cell_text_annotations.clear()
    dsn2kicad._cell_centers.clear()
    dsn2kicad._cell_pin_lists.clear()
    dsn2kicad._multi_unit_groups.clear()
    dsn2kicad._multi_unit_cell_map.clear()
    dsn2kicad._library_value_strings.clear()
    yield
