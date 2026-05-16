import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"

_dsn2kicad_mod = None


def _load_dsn2kicad():
    global _dsn2kicad_mod
    if _dsn2kicad_mod is None:
        path = str(SCRIPTS_DIR / "dsn2kicad")
        loader = SourceFileLoader("dsn2kicad", path)
        spec = importlib.util.spec_from_loader("dsn2kicad", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        _dsn2kicad_mod = mod
    return _dsn2kicad_mod


@pytest.fixture(scope="session")
def dsn2kicad():
    return _load_dsn2kicad()


@pytest.fixture(autouse=True)
def reset_globals(dsn2kicad):
    dsn2kicad._cell_pin_defs.clear()
    dsn2kicad._cell_body_rects.clear()
    dsn2kicad._cell_text_annotations.clear()
    dsn2kicad._cell_centers.clear()
    dsn2kicad._cell_pin_lists.clear()
    dsn2kicad._multi_unit_groups.clear()
    dsn2kicad._multi_unit_cell_map.clear()
    dsn2kicad._library_value_strings.clear()
    yield
