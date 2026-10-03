# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""The wasm32 build must produce byte-identical output to the native build.

The web page runs the converter compiled for wasm32-wasi, where Haskell's
`Int` is 32 bits.  Code that is correct on a 64-bit host can silently differ
there -- the page timestamp was the first case found -- so every fixture here
is converted natively, under wasmtime, and through web/runner.js -- the
code the page runs in its worker, with the browser WASI shim -- under Node.
All three output directories must match file for file and byte for byte.

The toolchain is found on PATH or in $GHC_WASM_DIR (default ~/.ghc-wasm),
the same way scripts/build-wasm finds it.  Skipped when it is absent so a
plain `pytest` still passes; set ORCAD2KICAD_REQUIRE_WASM=1 (CI does) to make
that a failure instead.  Set ORCAD2KICAD_PARITY_DSN_DIR to a directory of
real .DSN files to compare those as well.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_DIR / "scripts"
BUILD_WASM = SCRIPTS_DIR / "build-wasm"
DSN2KICAD = SCRIPTS_DIR / "dsn2kicad"
WEB_RUNNER = REPO_DIR / "tests" / "web" / "run_converter.mjs"

sys.path.insert(0, str(SCRIPTS_DIR))
import kicad_sexpr  # noqa: E402

GHC_WASM_DIR = Path(os.environ.get("GHC_WASM_DIR", Path.home() / ".ghc-wasm"))
# Tool -> its directory inside a ghc-wasm-meta installation.
WASM_TOOLS = {
    "wasm32-wasi-ghc": "wasm32-wasi-ghc/bin",
    "wasm-opt": "binaryen/bin",
    "wasmtime": "wasmtime/bin",
    "node": "nodejs/bin",
}


def find_wasm_tool(tool):
    return shutil.which(tool) or shutil.which(
        tool, path=str(GHC_WASM_DIR / WASM_TOOLS[tool])
    )


def _unavailable(reason):
    if os.environ.get("ORCAD2KICAD_REQUIRE_WASM") == "1":
        pytest.fail(f"ORCAD2KICAD_REQUIRE_WASM=1 but {reason}")
    pytest.skip(reason)


@pytest.fixture(scope="session")
def wasm_binary(tmp_path_factory):
    missing = [tool for tool in WASM_TOOLS if find_wasm_tool(tool) is None]
    if missing:
        _unavailable(
            f"wasm toolchain not on PATH or in {GHC_WASM_DIR}: " + ", ".join(missing)
        )
    if shutil.which("ghc") is None:
        _unavailable("native ghc not on PATH")
    output = tmp_path_factory.mktemp("wasm") / "dsn2kicad.wasm"
    result = subprocess.run(
        [str(BUILD_WASM), str(output)],
        capture_output=True, text=True, timeout=900,
    )
    assert result.returncode == 0, result.stderr
    return output


def convert_native(dsn, out_dir, flags=()):
    result = subprocess.run(
        [str(DSN2KICAD), *flags, str(dsn), str(out_dir)],
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr
    return out_dir


def convert_wasm(wasm, dsn, out_dir, flags=()):
    out_dir.mkdir(parents=True)
    result = subprocess.run(
        [
            find_wasm_tool("wasmtime"), "run",
            "--dir", f"{dsn.parent}::/in",
            "--dir", f"{out_dir}::/out",
            str(wasm), *flags, f"/in/{dsn.name}", "/out",
        ],
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr
    return out_dir


def convert_web_runner(wasm, dsn, out_dir, flags=()):
    result = subprocess.run(
        [
            find_wasm_tool("node"), str(WEB_RUNNER),
            str(wasm), str(dsn), str(out_dir), *flags,
        ],
        capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr
    return out_dir


def assert_identical_trees(expected_dir, actual_dir):
    expected = sorted(p.name for p in expected_dir.iterdir())
    actual = sorted(p.name for p in actual_dir.iterdir())
    assert actual == expected
    differing = [
        name for name in expected
        if (expected_dir / name).read_bytes() != (actual_dir / name).read_bytes()
    ]
    assert not differing, f"wasm output differs from native in {differing}"


def assert_parity(wasm, dsn, tmp_path, flags=()):
    native = convert_native(dsn, tmp_path / "native", flags)
    converted = convert_wasm(wasm, dsn, tmp_path / "wasm", flags)
    assert_identical_trees(native, converted)
    web = convert_web_runner(wasm, dsn, tmp_path / "web", flags)
    assert_identical_trees(native, web)


# --- Fixtures --------------------------------------------------------------

PAGE = "Views/SCHEMATIC1/Pages/Page1"

# (page timestamp, title-block date or None when the stamp is rejected).
# The accepted window is 1990-01-01 < stamp < 2040-01-01.  Stamps from
# 2038-01-19 on are >= 2^31 and wrap negative in a 32-bit Int.
TIMESTAMP_CASES = [
    (1617261986, "2021-04-01"),
    (2147483647, "2038-01-19"),
    (2147483648, "2038-01-19"),
    (2177452800, "2039-01-01"),
    (631152001, "1990-01-01"),
    (2208988799, "2039-12-31"),
    (631152000, None),
    (2208988800, None),
]


def timestamp_dsn(dsn_fixtures, path):
    pages = {
        f"Views/SCHEMATIC1/Pages/P{index:02d}": dsn_fixtures.make_page(
            f"P{index:02d}", modified=stamp,
            nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
        )
        for index, (stamp, _date) in enumerate(TIMESTAMP_CASES)
    }
    path.write_bytes(dsn_fixtures.make_zip(
        dict(pages, Library=dsn_fixtures.make_library(["unused"]))
    ))
    return path


def options_dsn(dsn_fixtures, path):
    """Components, power symbols, text and both KiCad-substitution targets."""
    page = dsn_fixtures.make_page(
        "01_OPTIONS", modified=1617261986,
        nets={
            1: "GND", 2: "+3V3", 3: "CUSTOM_RAIL",
            4: "R1", 5: "R2", 6: "C1", 7: "C2",
        },
        wires=[
            (1, 0, 0, 20, 0),
            (2, 100, 0, 120, 0),
            (3, 200, 0, 220, 0),
            (4, 60, 100, 90, 100),
            (5, 110, 100, 140, 100),
            (6, 60, 200, 90, 200),
            (7, 110, 200, 140, 200),
        ],
        components=[
            ("TP", "P1", 0, 20, 0, 0),
            ("TP", "P2", 0, 120, 0, 0),
            ("TP", "P3", 0, 220, 0, 0),
            ("R", "R1", 1, 100, 100, 0, [(1, 90, 100, 4), (2, 110, 100, 5)]),
            ("C", "C1", 1, 100, 200, 0, [(1, 90, 200, 6), (2, 110, 200, 7)]),
            ("TOUCH", "X1", 0, 110, 100, 0, [(1, 110, 100, 5)]),
        ],
        power_symbols=[("GND", 0, 0), ("VCC_BAR", 100, 0), ("VCC_BAR", 200, 0)],
        texts=[("Arial text", (20, 140, 120, 160), 1, 48)],
    )
    cache = dsn_fixtures.make_cache({
        "R": [("1", -10, 0, -5, 0, 0x21), ("2", 10, 0, 5, 0, 0x21)],
        "C": [("1", -10, 0, -5, 0, 0x21), ("2", 10, 0, 5, 0, 0x21)],
        "TP": [("P", 0, 0, 10, 0, 0x21)],
        "TOUCH": [("P", 0, 0, 10, 0, 0x21)],
    })
    cache += dsn_fixtures.make_cache_pin_numbers({"R": ["1", "2"], "C": ["1", "2"]})
    library = dsn_fixtures.make_library(
        ["unused", "10k"], styles=[(6, 400, False, 0, "Arial")]
    )
    # A real OLE container, as the web page will hand the converter.
    path.write_bytes(dsn_fixtures.make_ole(
        {PAGE: page, "Cache": cache, "Library": library}
    ))
    return path


def artwork_dsn(dsn_fixtures, path):
    """Rotated component with display fields, multi-line text, page graphics."""
    page = dsn_fixtures.make_page(
        "01_ARTWORK",
        components=[(
            "RES", "R1", 3, 100, 120, 5,
            [(1, 100, 90, 0), (2, 100, 110, 0)],
            [(2, -20, 10, 1), (1, -20, -10, 0)],
        )],
        texts=[("Heading\nDetail", (40, 50, 160, 90), 1, 8)],
        graphics=[
            {"kind": "rectangle", "coords": (20, 30, 180, 100), "color_idx": 8,
             "line_style": 1, "line_width": 2, "fill_style": 2},
            {"kind": "line", "coords": (20, 110, 180, 110), "color_idx": 28},
            {"kind": "ellipse", "coords": (200, 30, 240, 70), "color_idx": 18,
             "fill_style": 0},
            {"kind": "polygon", "coords": (0, 0, 0, 0), "color_idx": 9,
             "fill_style": 0,
             "points": [(260, 30), (280, 50), (260, 70), (260, 30)]},
        ],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [("1", 0, 0, 10, 0, 0x21), ("2", 20, 0, 10, 0, 0x21)],
    })
    library = dsn_fixtures.make_library(
        ["unused", "Part Reference", "Value", "10k *DNP"],
        styles=[(6, 700, True, 900, "Arial")],
    )
    path.write_bytes(dsn_fixtures.make_zip(
        {PAGE: page, "Cache": cache, "Library": library}
    ))
    return path


def title_block_date(schematic_path):
    tree = kicad_sexpr.parse(schematic_path.read_text(encoding="utf-8"))
    date = kicad_sexpr.find_first(kicad_sexpr.find_first(tree, "title_block"), "date")
    return kicad_sexpr.strip_quotes(date[1]) if date else None


# --- Tests -----------------------------------------------------------------

def test_page_timestamps_survive_32_bit_int(wasm_binary, dsn_fixtures, tmp_path):
    (tmp_path / "in").mkdir()
    dsn = timestamp_dsn(dsn_fixtures, tmp_path / "in" / "stamps.DSN")
    native = convert_native(dsn, tmp_path / "native")
    converted = convert_wasm(wasm_binary, dsn, tmp_path / "wasm")
    web = convert_web_runner(wasm_binary, dsn, tmp_path / "web")

    for index, (stamp, expected) in enumerate(TIMESTAMP_CASES):
        name = f"P{index:02d}.kicad_sch"
        assert title_block_date(native / name) == expected, f"native, stamp {stamp}"
        assert title_block_date(converted / name) == expected, f"wasm, stamp {stamp}"
    assert_identical_trees(native, converted)
    assert_identical_trees(native, web)


@pytest.mark.parametrize("flags", [
    (),
    ("--kicad-power", "--kicad-rc", "--kicad-fonts", "--no-worksheet",
     "--source-encoding=cp1252"),
], ids=["defaults", "all-options"])
def test_options_fixture_parity(wasm_binary, dsn_fixtures, tmp_path, flags):
    (tmp_path / "in").mkdir()
    dsn = options_dsn(dsn_fixtures, tmp_path / "in" / "options.DSN")
    assert_parity(wasm_binary, dsn, tmp_path, flags)


def test_artwork_fixture_parity(wasm_binary, dsn_fixtures, tmp_path):
    (tmp_path / "in").mkdir()
    dsn = artwork_dsn(dsn_fixtures, tmp_path / "in" / "artwork.DSN")
    assert_parity(wasm_binary, dsn, tmp_path)


def test_page_order_parity(wasm_binary, dsn_fixtures, tmp_path):
    """Numbers in page names order by value on wasm32 too.

    The 20- and 21-digit runs exceed even a 64-bit Int; the sort key holds
    them as Integer, and an Int would wrap differently on each target.
    """
    names = [
        "Page10", "Page2", "Page1",
        "N100000000000000000000", "N99999999999999999999",
    ]
    (tmp_path / "in").mkdir()
    dsn = tmp_path / "in" / "order.DSN"
    dsn.write_bytes(dsn_fixtures.make_zip({
        f"Views/SCHEMATIC1/Pages/{name}": dsn_fixtures.make_page(name)
        for name in names
    }))
    assert_parity(wasm_binary, dsn, tmp_path)


def _corpus():
    root = os.environ.get("ORCAD2KICAD_PARITY_DSN_DIR")
    if not root:
        return []
    return sorted(p for p in Path(root).rglob("*") if p.suffix.lower() == ".dsn")


@pytest.mark.skipif(not _corpus(), reason="ORCAD2KICAD_PARITY_DSN_DIR not set")
@pytest.mark.parametrize("dsn", _corpus(), ids=lambda p: p.name)
def test_real_design_parity(wasm_binary, dsn, tmp_path):
    # wasmtime maps a directory, not a file, so give each design its own.
    (tmp_path / "in").mkdir()
    local = tmp_path / "in" / dsn.name
    shutil.copyfile(dsn, local)
    assert_parity(wasm_binary, local, tmp_path)
