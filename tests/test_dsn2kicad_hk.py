# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Smoke tests for the in-progress Haskell dsn2kicad port."""
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
DSN2KICAD = SCRIPTS_DIR / "dsn2kicad"
DSN2KICAD_HK = SCRIPTS_DIR / "dsn2kicad.hs"
DSN2KICAD_PY = SCRIPTS_DIR / "dsn2kicad_py.py"
PAGE = "Views/SCHEMATIC1/Pages/Page1"

HS_DIR = SCRIPTS_DIR / "hs"


def hk_argv(*args):
    """argv for running the Haskell converter under runghc.

    The .hs file is no longer directly executable: with multiple modules GHC
    needs -i, which a shebang cannot provide.  Every test goes through here.
    """
    return ["runghc", f"-i{HS_DIR}", str(DSN2KICAD_HK), *[str(a) for a in args]]


sys.path.insert(0, str(SCRIPTS_DIR))
import kicad_sexpr  # noqa: E402


def _net_pin_groups(netlist_path):
    """Return net membership while ignoring converter-specific net names."""
    tree = kicad_sexpr.parse(netlist_path.read_text(encoding="utf-8"))
    groups = []

    def visit(node):
        if not isinstance(node, list):
            return
        if node and node[0] == "net":
            members = []
            for child in node[1:]:
                if not isinstance(child, list) or not child or child[0] != "node":
                    continue
                ref = kicad_sexpr.find_first(child, "ref")
                pin = kicad_sexpr.find_first(child, "pin")
                if ref and pin:
                    members.append((
                        kicad_sexpr.strip_quotes(ref[1]),
                        kicad_sexpr.strip_quotes(pin[1]),
                    ))
            if members:
                groups.append(tuple(sorted(members)))
        for child in node:
            visit(child)

    visit(tree)
    return sorted(groups)


def _net_ref_groups(netlist_path):
    """Return net membership while ignoring converter-specific pin labels."""
    return sorted(
        tuple(sorted(ref for ref, _pin in group))
        for group in _net_pin_groups(netlist_path)
    )


def _cache_graphics_primitives(dsn_fixtures, cell="RES"):
    rect = bytearray(26)
    struct.pack_into("<H", rect, 0, 0x2828)
    rect[2] = 0x28
    struct.pack_into("<iiii", rect, 10, -20, -10, 120, 10)

    line = bytearray(26)
    struct.pack_into("<H", line, 0, 0x2929)
    struct.pack_into("<iiii", line, 10, -20, 0, 120, 0)

    circle = bytearray(26)
    struct.pack_into("<H", circle, 0, 0x2B2B)
    struct.pack_into("<iiii", circle, 10, 30, -20, 70, 20)

    ellipse = bytearray(26)
    struct.pack_into("<H", ellipse, 0, 0x2B2B)
    struct.pack_into("<iiii", ellipse, 10, 20, -20, 80, 20)

    arc = bytearray(42)
    struct.pack_into("<H", arc, 0, 0x2A2A)
    struct.pack_into("<iiiiiiii", arc, 10, 20, -30, 80, 30, 80, 0, 50, 30)

    elliptical_arc = bytearray(42)
    struct.pack_into("<H", elliptical_arc, 0, 0x2A2A)
    struct.pack_into(
        "<iiiiiiii", elliptical_arc, 10, 10, -20, 90, 20, 90, 0, 50, 20
    )

    polygon_vertices = [(40, -10), (60, 0), (40, 10), (40, -10)]
    polygon = bytearray(28 + len(polygon_vertices) * 4)
    struct.pack_into("<H", polygon, 0, 0x2C2C)
    struct.pack_into("<H", polygon, 26, len(polygon_vertices))
    for idx, (x, y) in enumerate(polygon_vertices):
        struct.pack_into("<hh", polygon, 28 + idx * 4, y, x)

    polyline_points = [(25, -15), (75, -15)]
    byte_length = 18 + len(polyline_points) * 4
    polyline = bytearray(2 + byte_length)
    struct.pack_into("<H", polyline, 0, 0x2D2D)
    struct.pack_into("<I", polyline, 2, byte_length)
    struct.pack_into("<H", polyline, 18, len(polyline_points))
    for idx, (x, y) in enumerate(polyline_points):
        struct.pack_into("<hh", polyline, 20 + idx * 4, y, x)

    text = bytearray(42)
    struct.pack_into("<H", text, 0, 0x2E2E)
    struct.pack_into("<iiii", text, 10, 45, -5, 55, 5)
    struct.pack_into("<ii", text, 26, 50, 0)
    struct.pack_into("<H", text, 38, 1)
    text[40:41] = b"A"

    separator = dsn_fixtures.RECORD_MARKER + bytes(4)
    records = [
        bytes(rect),
        bytes(line),
        bytes(circle),
        bytes(ellipse),
        bytes(arc),
        bytes(elliptical_arc),
        bytes(polygon),
        bytes(polyline),
        bytes(text),
    ]
    return (
        cell.encode("ascii")
        + b".Normal\x00"
        + struct.pack("<H", 0)
        + b"\x00"
        + separator.join(records)
    )


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_native_zip_smoke(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_TEST",
        nets={5: "GND"},
        wires=[(5, -50, 0, 50, 0)],
        components=[("RES", "R1", 0), ("SW", "S1", 0)],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [
            ("ANODE", 0, 0, 50, 0, 0x20),
            ("NC", 100, 0, 50, 0, 0x21),
        ],
        "SW": [
            ("1", 0, -100, 0, -50, 0x21),
            ("2", 0, 100, 0, 50, 0x21),
        ],
    })
    cache += _cache_graphics_primitives(dsn_fixtures)
    cache += dsn_fixtures.make_cache_pin_numbers({
        "RES": ["A1", "K2"],
        "SW": ["1", "2"],
    })
    dsn = tmp_path / "synthetic.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    page_sch = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    assert '"R1"' in page_sch
    assert '"RES"' in page_sch
    assert "(wire" in page_sch
    assert '(pin "A1"' in page_sch
    assert '(pin "K2"' in page_sch
    assert '(reference "R1")' in page_sch
    uuids = re.findall(r'\(uuid "([0-9a-f-]+)"\)', page_sch)
    assert len(uuids) == len(set(uuids))
    sym_text = (out_dir / "synthetic.kicad_sym").read_text(encoding="utf-8")
    assert "(pin passive line" in sym_text
    assert "(pin no_connect line" in sym_text
    assert '(name "ANODE"' in sym_text
    assert '(number "A1"' in sym_text
    assert '(number "K2"' in sym_text
    assert "(pin_numbers hide)" in sym_text
    assert "(pin_names" in sym_text
    assert "(rectangle" in sym_text
    assert "(polyline" in sym_text
    assert "(circle" in sym_text
    assert "(arc" in sym_text
    assert sym_text.count("(polyline") >= 5
    assert sym_text.count("(width 0.254)") >= 5
    assert '(text "A"' in sym_text
    assert "(type outline)" in sym_text

    for path in out_dir.glob("*.kicad_sch"):
        kicad_sexpr.parse(path.read_text(encoding="utf-8"))
    sym_tree = kicad_sexpr.parse(sym_text)
    res_symbol = next(
        symbol
        for symbol in kicad_sexpr.find_all(sym_tree, "symbol")
        if kicad_sexpr.strip_quotes(symbol[1]) == "RES"
    )
    res_body = next(
        unit
        for unit in kicad_sexpr.find_all(res_symbol, "symbol")
        if kicad_sexpr.strip_quotes(unit[1]) == "RES_1_0"
    )
    body_rect = kicad_sexpr.find_first(res_body, "rectangle")
    assert tuple(map(kicad_sexpr.to_float, body_rect[1][1:3])) == (-17.78, 2.54)
    assert tuple(map(kicad_sexpr.to_float, body_rect[2][1:3])) == (17.78, -2.54)
    assert len(kicad_sexpr.find_all(res_body, "polyline")) >= 5

    sw_symbol = next(
        symbol
        for symbol in kicad_sexpr.find_all(sym_tree, "symbol")
        if kicad_sexpr.strip_quotes(symbol[1]) == "SW"
    )
    assert kicad_sexpr.find_first(sw_symbol, "pin_numbers") is None
    assert kicad_sexpr.find_first(sw_symbol, "pin_names") is not None

    repeat_out = tmp_path / "repeat-out"
    repeat_result = subprocess.run(
        hk_argv(dsn, repeat_out),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert repeat_result.returncode == 0, repeat_result.stderr
    assert page_sch == (repeat_out / "Page1.kicad_sch").read_text(encoding="utf-8")

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        python_out = tmp_path / "python-out"
        python_result = subprocess.run(
            [sys.executable, str(DSN2KICAD_PY), str(dsn), str(python_out)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert python_result.returncode == 0, python_result.stderr

        hk_netlist = tmp_path / "haskell.net"
        py_netlist = tmp_path / "python.net"
        for schematic, netlist in [
            (out_dir / "Page1.kicad_sch", hk_netlist),
            (python_out / "Page1.kicad_sch", py_netlist),
        ]:
            export_result = subprocess.run(
                [
                    kicad_cli,
                    "sch",
                    "export",
                    "netlist",
                    "--output",
                    str(netlist),
                    str(schematic),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert export_result.returncode == 0, export_result.stderr

        assert _net_pin_groups(hk_netlist) == _net_pin_groups(py_netlist)


@pytest.mark.skipif(shutil.which("ghc") is None, reason="GHC not installed")
def test_dsn2kicad_wrapper_concurrent_first_launch(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page("01_CONCURRENT")
    dsn = tmp_path / "concurrent.DSN"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page}))
    cache_dir = tmp_path / "haskell-cache"
    env = os.environ.copy()
    env["ORCAD2KICAD_HS_CACHE"] = str(cache_dir)

    processes = [
        subprocess.Popen(
            [str(DSN2KICAD), str(dsn), str(tmp_path / f"out-{index}")],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        for index in range(2)
    ]
    results = [process.communicate(timeout=60) for process in processes]

    for process, (_stdout, stderr) in zip(processes, results):
        assert process.returncode == 0, stderr
    assert len(list(cache_dir.glob("dsn2kicad-*"))) == 1
    assert not list(cache_dir.glob(".build-*"))


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_rejects_python_only_debug_flags():
    result = subprocess.run(
        hk_argv("--debug-bbox"),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 1
    assert "--debug-bbox is not implemented by scripts/dsn2kicad" in result.stderr
    assert "scripts/dsn2kicad_py" in result.stderr


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_preserves_title_block(dsn_fixtures, tmp_path):
    pool = ["filler"]
    entries, properties = dsn_fixtures.title_block_properties(
        {
            "Title": "Evaluation Board",
            "Doc": "ACME-XX-24-0001-02",
            "RevCode": "1.2",
            "OrgName": "Example Corp",
        },
        base=len(pool),
    )
    page = dsn_fixtures.make_page(
        "01_METADATA", properties=properties, modified=1617261986,
        nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
    )
    library = dsn_fixtures.make_library(pool + entries)
    dsn = tmp_path / "metadata.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Library": library}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    title_block = kicad_sexpr.find_first(tree, "title_block")
    assert kicad_sexpr.find_first(title_block, "title") == [
        "title", '"Evaluation Board"',
    ]
    assert kicad_sexpr.find_first(title_block, "rev") == ["rev", '"1.2"']
    assert kicad_sexpr.find_first(title_block, "date") == ["date", '"2021-04-01"']
    assert kicad_sexpr.find_first(title_block, "company") == [
        "company", '"Example Corp"',
    ]
    assert kicad_sexpr.find_all(title_block, "comment") == [
        ["comment", "1", '"ACME-XX-24-0001-02"'],
        ["comment", "2", '"Sheet 1 of 1"'],
    ]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_title_block_is_per_page(dsn_fixtures, tmp_path):
    """Title and date come from each page's own property table."""
    pool = ["Title", "Cover Sheet", "Power Tree", "Doc", "DOC-7", "RevCode", "B"]
    shared = [(pool.index("Doc"), pool.index("DOC-7")),
              (pool.index("RevCode"), pool.index("B"))]
    pages = {
        "Views/SCHEMATIC1/Pages/01_COVER": dsn_fixtures.make_page(
            "01_COVER", modified=1617261986,
            properties=[(0, pool.index("Cover Sheet"))] + shared,
            nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
        ),
        "Views/SCHEMATIC1/Pages/02_POWER": dsn_fixtures.make_page(
            "02_POWER", modified=1608508800,
            properties=[(0, pool.index("Power Tree"))] + shared,
            nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
        ),
    }
    dsn = tmp_path / "perpage.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip(
        dict(pages, Library=dsn_fixtures.make_library(pool))
    ))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    def title_block_of(filename):
        tree = kicad_sexpr.parse(
            (out_dir / filename).read_text(encoding="utf-8")
        )
        return kicad_sexpr.find_first(tree, "title_block")

    cover = title_block_of("01_COVER.kicad_sch")
    power = title_block_of("02_POWER.kicad_sch")
    assert kicad_sexpr.find_first(cover, "title") == ["title", '"Cover Sheet"']
    assert kicad_sexpr.find_first(power, "title") == ["title", '"Power Tree"']
    assert kicad_sexpr.find_first(cover, "date") == ["date", '"2021-04-01"']
    assert kicad_sexpr.find_first(power, "date") == ["date", '"2020-12-21"']
    # Document number and revision are shared, and both pages carry them.
    for block in (cover, power):
        assert kicad_sexpr.find_first(block, "rev") == ["rev", '"B"']
        assert kicad_sexpr.find_all(block, "comment")[0] == [
            "comment", "1", '"DOC-7"',
        ]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_pool_neighbours_may_be_stale_ancestors(dsn_fixtures, tmp_path):
    """Pool adjacency is meaningless; only the property indices are load-bearing.

    The Library pool is a deduplicated heap, so a live title-block value can be
    interned right beside a stale run left by an ancestor design, far from the
    live sheet title. Resolution must follow the page-header property indices.
    Any implementation that reads a value's neighbours fails here.
    """
    # A stale ancestor run, with the live document number interned in the
    # middle of it -- exactly the trap a neighbour scan falls into.
    pool = [
        "filler",
        "DOC-1000-001",             # ancestor document number
        "Cover Page (rev A)",       # ancestor sheet title
        "DOC-2000-001",             # live document number, stale neighbours
        "Power Management (rev A)",  # ancestor sheet title
    ]
    live_doc_index = pool.index("DOC-2000-001")
    # ...and the live title interned much later, nowhere near its document.
    pool += [f"pad{n}" for n in range(40)]
    entries, properties = dsn_fixtures.title_block_properties(
        {"Title": "Live Cover Page", "RevCode": "C"}, base=len(pool),
    )
    pool += entries
    # Point Doc at the live value by index, across the whole pool.
    doc_name_index = len(pool)
    pool += ["Doc"]
    properties = list(properties) + [(doc_name_index, live_doc_index)]

    page = dsn_fixtures.make_page(
        "01_COVER", properties=properties, modified=1617261986,
        nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
    )
    dsn = tmp_path / "ancestors.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page, "Library": dsn_fixtures.make_library(pool),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr

    tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    title_block = kicad_sexpr.find_first(tree, "title_block")
    assert kicad_sexpr.find_first(title_block, "title") == [
        "title", '"Live Cover Page"',
    ]
    # The live document number, not either stale ancestor beside it.
    assert kicad_sexpr.find_all(title_block, "comment")[0] == [
        "comment", "1", '"DOC-2000-001"',
    ]
    schematic = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    assert "DOC-1000-001" not in schematic
    assert "Cover Page (rev A)" not in schematic


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_pool_count_is_u32(dsn_fixtures, tmp_path):
    """The pool entry count is u32; a u16 read shifts every index by one.

    `make_library` writes the count with `<I`. Reading only its low half leaves
    the two high (zero) bytes unconsumed, which the parser then takes as a
    zero-length first string -- shifting every subsequent index and making
    component values fall back to cell names.
    """
    pool = ["unused", "Part Reference", "Value", "22k", "100n"]
    page = dsn_fixtures.make_page(
        "01_VALUES", nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
        components=[
            ("RES", "R1", pool.index("22k"), 20, 20, 0),
            ("RES", "R2", pool.index("100n"), 60, 20, 0),
        ],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [("1", 0, 0, 10, 0, 0x21), ("2", 20, 0, 10, 0, 0x21)],
    })
    dsn = tmp_path / "u32pool.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page, "Cache": cache,
        "Library": dsn_fixtures.make_library(pool),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr

    tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    values = {}
    for symbol in kicad_sexpr.find_all(tree, "symbol"):
        if not kicad_sexpr.find_first(symbol, "lib_id"):
            continue
        properties = {
            kicad_sexpr.strip_quotes(prop[1]): kicad_sexpr.strip_quotes(prop[2])
            for prop in kicad_sexpr.find_all(symbol, "property")
        }
        values[properties["Reference"]] = properties["Value"]
    # Off-by-one from a u16 read would yield "Value"/"22k"; a discarded pool
    # would fall back to the cell name "RES".
    assert values == {"R1": "22k", "R2": "100n"}


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_part_number_is_not_mistaken_for_doc_number(dsn_fixtures, tmp_path):
    """`Doc` comes from the property table, never from a pool string search.

    Part numbers share the letters-letters-digits-digits shape of document
    numbers, so any matcher scanning the pool promotes an unrelated component
    string into the title block.
    """
    # A part-number-shaped string sits in the pool ahead of the real document
    # number, so a pool scan reaches it first.
    pool = ["filler", "CONN-AF-01-001", "CONN-AF-04-002"]
    entries, properties = dsn_fixtures.title_block_properties(
        {"Title": "Evaluation Board", "Doc": "ACME-XX-24-0001-02"},
        base=len(pool),
    )
    page = dsn_fixtures.make_page(
        "01_TITLE", properties=properties, modified=1617261986,
        nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
    )
    dsn = tmp_path / "partnum.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page, "Library": dsn_fixtures.make_library(pool + entries),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr

    schematic = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    tree = kicad_sexpr.parse(schematic)
    title_block = kicad_sexpr.find_first(tree, "title_block")
    assert kicad_sexpr.find_all(title_block, "comment")[0] == [
        "comment", "1", '"ACME-XX-24-0001-02"',
    ]
    assert "CONN-AF-01-001" not in schematic
    assert "CONN-AF-04-002" not in schematic


def _expected_haskell_uuid(dsn_bytes, category, object_index):
    dsn_digest = hashlib.sha256(dsn_bytes).digest()
    object_key = f"{category}:{object_index}".encode("utf-8")
    raw = bytearray(hashlib.sha256(dsn_digest + b"\0" + object_key).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x40
    raw[8] = (raw[8] & 0x3F) | 0x80
    return (
        f"{raw[0:4].hex()}-{raw[4:6].hex()}-{raw[6:8].hex()}-"
        f"{raw[8:10].hex()}-{raw[10:16].hex()}"
    )


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_uuids_are_content_seeded(dsn_fixtures, tmp_path):
    root_uuids = []
    for variant in ("FIRST", "SECOND"):
        project_dir = tmp_path / variant.lower()
        project_dir.mkdir()
        dsn = project_dir / "identity.DSN"
        dsn_bytes = dsn_fixtures.make_zip({
            PAGE: dsn_fixtures.make_page(f"01_{variant}"),
        })
        dsn.write_bytes(dsn_bytes)
        out_dir = project_dir / "out"

        result = subprocess.run(
            hk_argv(dsn, out_dir),
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr

        root_text = (out_dir / "identity.kicad_sch").read_text(encoding="utf-8")
        root_uuid = re.search(r'\(uuid "([0-9a-f-]+)"\)', root_text).group(1)
        assert root_uuid == _expected_haskell_uuid(dsn_bytes, 0, 1)
        assert re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
            r"[89ab][0-9a-f]{3}-[0-9a-f]{12}",
            root_uuid,
        )
        root_uuids.append(root_uuid)

    assert root_uuids[0] != root_uuids[1]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_uuids_do_not_depend_on_source_filename(
    dsn_fixtures, tmp_path
):
    dsn_bytes = dsn_fixtures.make_zip({
        PAGE: dsn_fixtures.make_page("01_RENAMED"),
    })
    root_uuids = []

    for source_name in ("original.DSN", "renamed.DSN"):
        project_dir = tmp_path / Path(source_name).stem
        project_dir.mkdir()
        dsn = project_dir / source_name
        dsn.write_bytes(dsn_bytes)
        out_dir = project_dir / "out"

        result = subprocess.run(
            hk_argv(dsn, out_dir),
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr

        root_text = (out_dir / f"{dsn.stem}.kicad_sch").read_text(encoding="utf-8")
        root_uuids.append(
            re.search(r'\(uuid "([0-9a-f-]+)"\)', root_text).group(1)
        )

    assert root_uuids[0] == root_uuids[1]


@pytest.mark.parametrize("sector_size", [512, 4096])
@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_native_ole_smoke(dsn_fixtures, tmp_path, sector_size):
    note_page = dsn_fixtures.make_page("01_NOTE")
    main_page = dsn_fixtures.make_page(
        "02_MAIN",
        nets={1: "LINK"},
        wires=[(1, 0, 0, 100, 0)],
        components=[("TP", "J1", 0, 0, 0, 0), ("TP", "J2", 0, 100, 0, 0)],
    )
    cache = dsn_fixtures.make_cache({
        "TP": [("P", 0, 0, 10, 0, 0x21)],
    })
    dsn = tmp_path / "synthetic-ole.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(
        dsn_fixtures.make_ole(
            {
                "Views/SYNTHETIC/Pages/Page Note": note_page,
                "Views/SYNTHETIC/Pages/Page Main": main_page,
                "Cache": cache,
            },
            sector_size=sector_size,
        )
    )

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert dsn.read_bytes().startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")
    root_path = out_dir / "synthetic-ole.kicad_sch"
    symbol_path = out_dir / "synthetic-ole.kicad_sym"
    note_path = out_dir / "Page_Note.kicad_sch"
    main_path = out_dir / "Page_Main.kicad_sch"
    assert note_path.exists()
    assert main_path.exists()
    root_text = root_path.read_text(encoding="utf-8")
    assert '"Page_Note.kicad_sch"' in root_text
    assert '"Page_Main.kicad_sch"' in root_text
    assert "(pin passive line" in symbol_path.read_text(encoding="utf-8")

    for path in [root_path, note_path, main_path, symbol_path]:
        kicad_sexpr.parse(path.read_text(encoding="utf-8"))

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "ole.net"
        export_result = subprocess.run(
            [
                kicad_cli, "sch", "export", "netlist",
                "--output", str(netlist), str(main_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        assert (("J1", "1"), ("J2", "1")) in _net_pin_groups(netlist)


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_discovers_pages_in_named_views(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_NAMED_VIEW",
        nets={1: "SIGNAL"},
        wires=[(1, 0, 0, 100, 0)],
        components=[("TP", "TP1", 0, 100, 0, 0)],
    )
    dsn = tmp_path / "named-view.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        "Views/GenericBoard/Pages/P01_Title Page": page,
        "Cache": dsn_fixtures.make_cache({
            "TP": [("P", 0, 0, 10, 0, 0x21)],
        }),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert (out_dir / "P01_Title_Page.kicad_sch").exists()
    root = (out_dir / "named-view.kicad_sch").read_text(encoding="utf-8")
    assert '"P01_Title_Page.kicad_sch"' in root
    page_text = (out_dir / "P01_Title_Page.kicad_sch").read_text(
        encoding="utf-8"
    )
    assert "(symbol" in page_text
    assert "(wire" in page_text


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_legacy_cache_and_page_records(dsn_fixtures, tmp_path):
    opamp_pins = [
        ("+", -20, -20, -10, -20, 0x21),
        ("-", -20, 0, -10, 0, 0x21),
        ("V+", 0, -20, 0, -10, 0x21),
        ("V-", 0, 20, 0, 10, 0x21),
        ("OUT", 20, 0, 10, 0, 0x21),
        ("OS1", 20, -20, 10, -20, 0x21),
        ("OS2", 20, 20, 10, 20, 0x21),
    ]
    pin_numbers = [3, 2, 7, 4, 6, 1, 5]
    hotpoints = [
        (310, 350), (310, 370), (330, 350), (330, 390),
        (350, 370), (350, 350), (350, 390),
    ]
    endpoints = [
        (290, 350), (290, 370), (330, 330), (330, 410),
        (370, 370), (370, 350), (370, 390),
    ]

    nets = {index: f"NET{index}" for index in range(1, 8)}
    nets[8] = "FILLER"
    nets.update({index: "0" for index in range(9, 13)})
    wires = [
        (net_id, *hotpoint, *endpoint)
        for net_id, hotpoint, endpoint in zip(range(1, 8), hotpoints, endpoints)
    ]
    wires.extend(
        (8, 600, 100 + index * 10, 620, 100 + index * 10)
        for index in range(17)
    )
    power_hotpoints = [(900, 100 + index * 50) for index in range(4)]
    wires.extend(
        (net_id, *hotpoint, hotpoint[0] + 20, hotpoint[1])
        for net_id, hotpoint in zip(range(9, 13), power_hotpoints)
    )
    assert len(wires) == 28

    components = [(
        "OPAMP", "U1", 0, 330, 370, 0,
        [
            (number, x, y, net_id)
            for number, (x, y), net_id in zip(pin_numbers, hotpoints, range(1, 8))
        ],
    )]
    components.extend(
        ("TP", f"P{number}", 0, x, y, 0)
        for number, (x, y) in zip(pin_numbers, endpoints)
    )
    page = dsn_fixtures.make_page(
        "PAGE1",
        paper="A",
        nets=nets,
        wires=wires,
        components=components,
        power_symbols=[("GND", *point) for point in power_hotpoints],
        legacy=True,
    )
    cache = dsn_fixtures.make_legacy_cache(
        {
            "OPAMP": opamp_pins,
            "TP": [("P", 0, 0, 10, 0, 0x21)],
        },
        compact_cells={"TP"},
    )
    cache += dsn_fixtures.make_cache_pin_numbers({
        "OPAMP": [str(number) for number in pin_numbers],
        "TP": ["1", "2"],
    })
    dsn = tmp_path / "legacy.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        "Views/SCHEMATIC1/Pages/PAGE1": page,
        "Cache": cache,
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    symbol_tree = kicad_sexpr.parse(
        (out_dir / "legacy.kicad_sym").read_text(encoding="utf-8")
    )
    opamp = next(
        symbol
        for symbol in symbol_tree[1:]
        if isinstance(symbol, list)
        and symbol
        and symbol[0] == "symbol"
        and kicad_sexpr.strip_quotes(symbol[1]) == "OPAMP"
    )
    opamp_pin_unit = next(
        unit
        for unit in kicad_sexpr.find_all(opamp, "symbol")
        if kicad_sexpr.strip_quotes(unit[1]) == "OPAMP_1_1"
    )
    emitted_pins = {
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(pin, "name")[1]):
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(pin, "number")[1])
        for pin in kicad_sexpr.find_all(opamp_pin_unit, "pin")
    }
    assert emitted_pins == {
        "+": "3", "-": "2", "V+": "7", "V-": "4",
        "OUT": "6", "OS1": "1", "OS2": "5",
    }

    page_path = out_dir / "PAGE1.kicad_sch"
    page_text = page_path.read_text(encoding="utf-8")
    page_tree = kicad_sexpr.parse(page_text)
    assert page_text.count("\n\t(wire\n") == 28
    placed = [
        symbol
        for symbol in kicad_sexpr.find_all(page_tree, "symbol")
        if kicad_sexpr.find_first(symbol, "lib_id")
    ]
    u1 = next(
        symbol
        for symbol in placed
        if kicad_sexpr.strip_quotes(
            kicad_sexpr.find_first(symbol, "property")[2]
        ) == "U1"
    )
    assert tuple(map(
        kicad_sexpr.to_float,
        kicad_sexpr.find_first(u1, "at")[1:4],
    )) == (83.82, 93.98, 0.0)
    assert sum(
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(symbol, "lib_id")[1])
        == "power:0"
        for symbol in placed
    ) == 4

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "legacy.net"
        export_result = subprocess.run(
            [
                kicad_cli, "sch", "export", "netlist",
                "--output", str(netlist), str(page_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        groups = _net_pin_groups(netlist)
        for number in pin_numbers:
            assert ((f"P{number}", "1"), ("U1", str(number))) in groups


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_rejects_dsn_without_page_streams(dsn_fixtures, tmp_path):
    dsn = tmp_path / "no-pages.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({"Cache": b"not a page"}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode != 0
    assert "no schematic page streams found" in result.stderr
    assert not out_dir.exists()


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_rejects_duplicate_page_output_names(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page("01_DUPLICATE")
    dsn = tmp_path / "duplicate-pages.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        "Views/First/Pages/Page1": page,
        "Views/Second/Pages/Page1": page,
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode != 0
    assert "same KiCad output filename" in result.stderr
    assert not out_dir.exists()


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_disambiguates_page_named_after_project(
    dsn_fixtures, tmp_path,
):
    dsn = tmp_path / "same-name.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        "Views/SCHEMATIC1/Pages/same-name":
            dsn_fixtures.make_page("same-name"),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    root = out_dir / "same-name.kicad_sch"
    page = out_dir / "same-name_sheet.kicad_sch"
    assert root.exists()
    assert page.exists()
    root_tree = kicad_sexpr.parse(root.read_text(encoding="utf-8"))
    sheet = kicad_sexpr.find_first(root_tree, "sheet")
    sheetfile = next(
        prop for prop in kicad_sexpr.find_all(sheet, "property")
        if kicad_sexpr.strip_quotes(prop[1]) == "Sheetfile"
    )
    assert kicad_sexpr.strip_quotes(sheetfile[2]) == "same-name_sheet.kicad_sch"


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_rejects_cyclic_ole_directory(
    dsn_fixtures, tmp_path,
):
    dsn_bytes = bytearray(dsn_fixtures.make_ole({
        PAGE: dsn_fixtures.make_page("01_CYCLE"),
    }))
    # The synthetic OLE lays out Root Entry as SID 0 and Views as SID 1.
    # Point Views' right sibling back to itself.
    views_sid = 1
    directory_offset = 512
    entry_size = 128
    right_sibling_offset = 72
    struct.pack_into(
        "<I",
        dsn_bytes,
        directory_offset + views_sid * entry_size + right_sibling_offset,
        views_sid,
    )
    dsn = tmp_path / "cycle.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_bytes)

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode != 0
    assert "OLE directory entry cycle at SID 1" in result.stderr
    assert not out_dir.exists()


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_extends_pin_hotpoints_and_wires(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_EXTEND",
        nets={1: "LEFT", 2: "RIGHT"},
        wires=[(1, 50, 100, 80, 100), (2, 120, 100, 150, 100)],
        components=[(
            "EXT", "U1", 0, 100, 100, 0,
            [(1, 80, 100, 1), (2, 120, 100, 2)],
        )],
    )
    cache = dsn_fixtures.make_cache({
        "EXT": [
            ("LEFT", -20, 0, -10, 0, 0x21),
            ("RIGHT", 20, 0, 10, 0, 0x21),
        ],
    })
    cache += dsn_fixtures.make_cache_pin_numbers({"EXT": ["1", "123"]})
    dsn = tmp_path / "extend.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    symbol_tree = kicad_sexpr.parse(
        (out_dir / "extend.kicad_sym").read_text(encoding="utf-8")
    )
    symbol = next(
        node
        for node in kicad_sexpr.find_all(symbol_tree, "symbol")
        if kicad_sexpr.strip_quotes(node[1]) == "EXT"
    )
    pin_unit = next(
        node
        for node in kicad_sexpr.find_all(symbol, "symbol")
        if kicad_sexpr.strip_quotes(node[1]) == "EXT_1_1"
    )
    pins = {
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(pin, "number")[1]): pin
        for pin in kicad_sexpr.find_all(pin_unit, "pin")
    }
    assert [kicad_sexpr.to_float(kicad_sexpr.find_first(pins[n], "length")[1])
            for n in ["1", "123"]] == [5.08, 5.08]
    assert kicad_sexpr.to_float(kicad_sexpr.find_first(pins["1"], "at")[1]) == -7.62
    assert kicad_sexpr.to_float(kicad_sexpr.find_first(pins["123"], "at")[1]) == 7.62

    page_tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    wire_points = []
    for wire in kicad_sexpr.find_all(page_tree, "wire"):
        points = kicad_sexpr.find_all(kicad_sexpr.find_first(wire, "pts"), "xy")
        wire_points.append(tuple(
            tuple(kicad_sexpr.to_float(value) for value in point[1:3])
            for point in points
        ))
    assert wire_points == [
        ((12.7, 25.4), (17.78, 25.4)),
        ((33.02, 25.4), (38.1, 25.4)),
    ]


def _placed_pin_points(out_dir, project, page, lib_id):
    """Absolute mm positions of a placed symbol's pins on the page.

    KiCad resolves a pin by adding the symbol-local pin coordinate to the
    placement anchor, negating Y because symbol space points up.  Only
    unrotated, unmirrored placements are handled -- enough to check that the two
    emitted numbers still sum to the pin's true page position.
    """
    symbol_tree = kicad_sexpr.parse(
        (out_dir / f"{project}.kicad_sym").read_text(encoding="utf-8")
    )
    definition = next(
        node
        for node in kicad_sexpr.find_all(symbol_tree, "symbol")
        if kicad_sexpr.strip_quotes(node[1]) == lib_id
    )
    local = [
        tuple(kicad_sexpr.to_float(v) for v in kicad_sexpr.find_first(pin, "at")[1:3])
        for unit in kicad_sexpr.find_all(definition, "symbol")
        for pin in kicad_sexpr.find_all(unit, "pin")
    ]

    page_tree = kicad_sexpr.parse(
        (out_dir / f"{page}.kicad_sch").read_text(encoding="utf-8")
    )
    placement = next(
        node
        for node in kicad_sexpr.find_all(page_tree, "symbol")
        if (kicad_sexpr.find_first(node, "lib_id")
            and kicad_sexpr.strip_quotes(
                kicad_sexpr.find_first(node, "lib_id")[1]) == lib_id)
    )
    at = kicad_sexpr.find_first(placement, "at")
    anchor_x, anchor_y = (kicad_sexpr.to_float(v) for v in at[1:3])
    assert kicad_sexpr.to_float(at[3]) == 0
    assert kicad_sexpr.find_first(placement, "mirror") is None
    return {
        (round(anchor_x + lx, 6), round(anchor_y - ly, 6)) for lx, ly in local
    }


def _wire_endpoints(out_dir, page):
    points = set()
    tree = kicad_sexpr.parse(
        (out_dir / f"{page}.kicad_sch").read_text(encoding="utf-8")
    )
    for wire in kicad_sexpr.find_all(tree, "wire"):
        for point in kicad_sexpr.find_all(kicad_sexpr.find_first(wire, "pts"), "xy"):
            points.add(tuple(
                round(kicad_sexpr.to_float(value), 6) for value in point[1:3]
            ))
    return points


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_pins_land_exactly_on_their_wires(dsn_fixtures, tmp_path):
    """Symbol pins must coincide *exactly* with the wires that reach them.

    KiCad connects a pin to a wire only when the two points are identical, so a
    sub-grid discrepancy silently drops the pin off its net.  Two roundings used
    to introduce one:

    ODDY spans an odd number of units between its hot points, so the symbol
    origin -- the point every symbol-local coordinate is measured from -- landed
    on a half unit while the placement anchor stayed whole, shifting every pin
    0.127 mm.

    WIDE places a pin where the anchor (826 units -> 209.804 mm) and the local
    offset (178 units -> 45.212 mm) each round down at two decimals, so their sum
    came out 255.01 instead of the wire's 255.02.
    """
    page = dsn_fixtures.make_page(
        "01_GRID",
        nets={1: "ODD_A", 2: "ODD_B", 3: "WIDE_L", 4: "WIDE_R"},
        wires=[
            (1, 100, 200, 150, 200),
            (2, 100, 225, 150, 225),
            (3, 648, 300, 600, 300),
            (4, 1004, 300, 1050, 300),
        ],
        components=[
            (
                "ODDY", "U1", 0, 100, 200, 0,
                [(1, 100, 200, 1), (2, 100, 225, 2)],
            ),
            (
                "WIDE", "U2", 0, 826, 300, 0,
                [(1, 648, 300, 3), (2, 1004, 300, 4)],
            ),
        ],
    )
    cache = dsn_fixtures.make_cache({
        # Hot Y extent 0..25 sums to an odd number of units.
        "ODDY": [
            ("A", -30, 0, -10, 0, 0x21),
            ("B", -30, 25, -10, 25, 0x21),
        ],
        "WIDE": [
            ("L", -178, 0, -158, 0, 0x21),
            ("R", 178, 0, 158, 0, 0x21),
        ],
    })
    dsn = tmp_path / "grid.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr

    wires = _wire_endpoints(out_dir, "Page1")
    odd = _placed_pin_points(out_dir, "grid", "Page1", "ODDY")
    wide = _placed_pin_points(out_dir, "grid", "Page1", "WIDE")

    # The OrCAD page coordinates the pins were parsed at, in millimetres.
    assert odd == {(100 * 0.254, 200 * 0.254), (100 * 0.254, 225 * 0.254)}
    assert wide == {(648 * 0.254, 300 * 0.254), (1004 * 0.254, 300 * 0.254)}
    assert odd <= wires
    assert wide <= wires


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_multi_unit_symbols(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_MULTI",
        components=[("AMP_A", "U1", 0), ("AMP_B", "U1", 0)],
    )
    cache = dsn_fixtures.make_cache({
        "AMP_A": [
            ("A_IN", -20, 0, 0, 0, 0x21),
            ("A_OUT", 20, 0, 0, 0, 0x21),
        ],
        "AMP_B": [
            ("B_IN", -20, 0, 0, 0, 0x21),
            ("B_OUT", 20, 0, 0, 0, 0x21),
        ],
    })
    cache += dsn_fixtures.make_cache_pin_numbers({
        "AMP_A": ["1", "2"],
        "AMP_B": ["3", "4"],
    })
    dsn = tmp_path / "multi.DSN"
    out_dir = tmp_path / "haskell-out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    sym_tree = kicad_sexpr.parse(
        (out_dir / "multi.kicad_sym").read_text(encoding="utf-8")
    )
    top_symbols = kicad_sexpr.find_all(sym_tree, "symbol")
    assert [kicad_sexpr.strip_quotes(symbol[1]) for symbol in top_symbols] == [
        "AMP"
    ]
    unit_symbols = kicad_sexpr.find_all(top_symbols[0], "symbol")
    assert [kicad_sexpr.strip_quotes(symbol[1]) for symbol in unit_symbols] == [
        "AMP_1_0",
        "AMP_1_1",
        "AMP_2_0",
        "AMP_2_1",
    ]

    page_path = out_dir / "Page1.kicad_sch"
    page_tree = kicad_sexpr.parse(page_path.read_text(encoding="utf-8"))
    placements = kicad_sexpr.find_all(page_tree, "symbol")
    assert [kicad_sexpr.strip_quotes(
        kicad_sexpr.find_first(symbol, "lib_id")[1]
    ) for symbol in placements] == ["AMP", "AMP"]
    assert [int(kicad_sexpr.find_first(symbol, "unit")[1])
            for symbol in placements] == [1, 2]
    assert [[kicad_sexpr.strip_quotes(pin[1])
             for pin in kicad_sexpr.find_all(symbol, "pin")]
            for symbol in placements] == [["1", "2"], ["3", "4"]]

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        python_out = tmp_path / "python-out"
        python_result = subprocess.run(
            [sys.executable, str(DSN2KICAD_PY), str(dsn), str(python_out)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert python_result.returncode == 0, python_result.stderr

        hk_netlist = tmp_path / "haskell.net"
        py_netlist = tmp_path / "python.net"
        for schematic, netlist in [
            (page_path, hk_netlist),
            (python_out / "Page1.kicad_sch", py_netlist),
        ]:
            export_result = subprocess.run(
                [
                    kicad_cli,
                    "sch",
                    "export",
                    "netlist",
                    "--output",
                    str(netlist),
                    str(schematic),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert export_result.returncode == 0, export_result.stderr
        assert _net_pin_groups(hk_netlist) == _net_pin_groups(py_netlist)


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_sheet_connectivity(dsn_fixtures, tmp_path):
    page1 = dsn_fixtures.make_page(
        "01_CONNECT",
        nets={
            1: "LOCAL",
            2: "SHARED",
            3: "T_NET",
            4: "CROSS_A",
            5: "CROSS_B",
        },
        wires=[
            (1, 0, 0, 20, 0),
            (1, 100, 0, 120, 0),
            (2, 0, 150, 20, 150),
            (3, 0, 50, 20, 50),
            (3, 10, 50, 10, 70),
            (4, 0, 100, 20, 100),
            (5, 10, 90, 10, 110),
        ],
        components=[
            ("TP", "L1", 0, 0, 0, 0),
            ("TP", "L2", 0, 100, 0, 0),
            ("TP", "G1", 0, 0, 150, 0),
            ("TP", "CA1", 0, 0, 100, 0),
            ("TP", "CA2", 0, 20, 100, 0),
            ("TP", "CB1", 0, 10, 90, 0),
            ("TP", "CB2", 0, 10, 110, 0),
        ],
        off_page_connectors=[
            ("OFFPAGELEFT-L", (20, 140, 120, 160), 0),
        ],
    )
    page2 = dsn_fixtures.make_page(
        "02_CONNECT",
        nets={2: "SHARED"},
        wires=[(2, 0, 0, 20, 0)],
        components=[("TP", "G2", 0, 0, 0, 0)],
        off_page_connectors=[
            ("OFFPAGELEFT-L", (20, -10, 120, 10), 0),
        ],
    )
    cache = dsn_fixtures.make_cache({
        "TP": [("P", 0, 0, 10, 0, 0x21)],
    })
    dsn = tmp_path / "connectivity.DSN"
    out_dir = tmp_path / "haskell-out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page1,
        "Views/SCHEMATIC1/Pages/Page2": page2,
        "Cache": cache,
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    page1_tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    local_names = [
        kicad_sexpr.strip_quotes(label[1])
        for label in kicad_sexpr.find_all(page1_tree, "label")
    ]
    assert local_names.count("LOCAL") == 2
    assert local_names.count("T_NET") == 4
    assert local_names.count("CROSS_A") == 0
    assert local_names.count("CROSS_B") == 0
    global_names = [
        kicad_sexpr.strip_quotes(label[1])
        for label in kicad_sexpr.find_all(page1_tree, "global_label")
    ]
    assert global_names == ["SHARED"]
    junctions = kicad_sexpr.find_all(page1_tree, "junction")
    assert len(junctions) == 1
    junction_at = kicad_sexpr.find_first(junctions[0], "at")
    assert tuple(map(kicad_sexpr.to_float, junction_at[1:3])) == (2.54, 12.7)

    page2_tree = kicad_sexpr.parse(
        (out_dir / "Page2.kicad_sch").read_text(encoding="utf-8")
    )
    assert [
        kicad_sexpr.strip_quotes(label[1])
        for label in kicad_sexpr.find_all(page2_tree, "global_label")
    ] == ["SHARED"]

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        python_out = tmp_path / "python-out"
        python_result = subprocess.run(
            [sys.executable, str(DSN2KICAD_PY), str(dsn), str(python_out)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert python_result.returncode == 0, python_result.stderr

        hk_netlist = tmp_path / "haskell.net"
        py_netlist = tmp_path / "python.net"
        for schematic, netlist in [
            (out_dir / "connectivity.kicad_sch", hk_netlist),
            (python_out / "connectivity.kicad_sch", py_netlist),
        ]:
            export_result = subprocess.run(
                [
                    kicad_cli,
                    "sch",
                    "export",
                    "netlist",
                    "--output",
                    str(netlist),
                    str(schematic),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert export_result.returncode == 0, export_result.stderr

        hk_groups = _net_pin_groups(hk_netlist)
        assert (("G1", "1"), ("G2", "1")) in hk_groups
        assert (("L1", "1"), ("L2", "1")) in hk_groups
        assert (("CA1", "1"), ("CA2", "1")) in hk_groups
        assert (("CB1", "1"), ("CB2", "1")) in hk_groups
        assert hk_groups == _net_pin_groups(py_netlist)


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_buses_aliases_page_names_and_symbol_details(
    dsn_fixtures, tmp_path,
):
    main_page = dsn_fixtures.make_page(
        "05_LPDDR4",
        nets={
            1: "DATA[3..0]",
            2: "DATA0",
            3: "DATA1",
            4: "ALIAS_NET",
        },
        wires=[
            (1, 100, 100, 200, 100),
            (2, 50, 90, 90, 90),
            (3, 210, 90, 250, 90),
            (4, 300, 100, 360, 100),
        ],
        aliases=[("alias_net", 330, 100)],
        components=[
            ("TP", "D0", 0, 50, 90, 0),
            ("TP", "D1", 0, 250, 90, 0),
            ("TP", "A1", 0, 300, 100, 0),
            ("TP", "A2", 0, 360, 100, 0),
            ("R", "R1", 0, 500, 100, 0),
            ("C", "C1", 0, 550, 100, 0),
            ("CON16W", "J1", 0, 600, 100, 0),
            ("UART_BRIDGE", "U1", 0, 650, 100, 0),
        ],
    )
    cache = dsn_fixtures.make_cache(
        {
            "TP": [("P", 0, 0, 10, 0, 0x21)],
            "R": [
                ("1", -10, 0, -5, 0, 0x21),
                ("2", 10, 0, 5, 0, 0x21),
            ],
            "C": [
                ("1", -10, 0, -5, 0, 0x21),
                ("2", 10, 0, 5, 0, 0x21),
            ],
            "CON16W": [
                ("LEFT", -20, -10, -10, -10, 0x21),
                ("MID", -20, 0, -10, 0, 0x21),
                ("RIGHT", -20, 10, -10, 10, 0x21),
            ],
            "UART_BRIDGE": [
                ("R\\T\\S\\", -20, -10, -10, -10, 0x21),
                ("C\\T\\S\\", -20, 0, -10, 0, 0x21),
                ("R\\E\\S\\E\\T\\", -20, 10, -10, 10, 0x21),
            ],
        },
        visibility={
            "R": (False, False),
            "CON16W": (True, False),
        },
    )
    cache += dsn_fixtures.make_cache_pin_numbers({
        "R": ["1", "2"],
        "C": ["1", "2"],
        "CON16W": ["1", "2", "3"],
        "UART_BRIDGE": ["2", "6", "11"],
    })
    members = {
        "Views/SYNTHETIC/Pages/05 LPDDR4": main_page,
        "Cache": cache,
    }
    page_files = [
        "03_Clock_Sys_Config_PWR_on_cnt.kicad_sch",
        "06_QSPIFlash_microSD.kicad_sch",
        "12_MIPI_CSI-2_MIPI-DSI.kicad_sch",
        "18_UART_USB_Ext_GPIO.kicad_sch",
    ]
    for page_file in page_files:
        stream_name = page_file.removesuffix(".kicad_sch").replace("_", " ")
        members[f"Views/SYNTHETIC/Pages/{stream_name}"] = (
            dsn_fixtures.make_page(stream_name)
        )

    dsn = tmp_path / "large-features.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip(members))
    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    assert (out_dir / "05_LPDDR4.kicad_sch").exists()
    for page_file in page_files:
        assert (out_dir / page_file).exists()

    page_tree = kicad_sexpr.parse(
        (out_dir / "05_LPDDR4.kicad_sch").read_text(encoding="utf-8")
    )
    assert len(kicad_sexpr.find_all(page_tree, "bus")) == 1
    assert len(kicad_sexpr.find_all(page_tree, "bus_entry")) == 2
    aliases = [
        label
        for label in kicad_sexpr.find_all(page_tree, "label")
        if kicad_sexpr.strip_quotes(label[1]) == "ALIAS_NET"
    ]
    assert len(aliases) == 1
    assert tuple(map(
        kicad_sexpr.to_float,
        kicad_sexpr.find_first(aliases[0], "at")[1:3],
    )) == (83.82, 25.4)

    wire_signatures = []
    for wire in kicad_sexpr.find_all(page_tree, "wire"):
        points = kicad_sexpr.find_first(wire, "pts")
        wire_signatures.append(tuple(
            tuple(kicad_sexpr.to_float(value) for value in point[1:3])
            for point in kicad_sexpr.find_all(points, "xy")
        ))
    assert sorted(wire_signatures) == sorted([
        ((12.7, 22.86), (22.86, 22.86)),
        ((53.34, 22.86), (63.5, 22.86)),
        ((76.2, 25.4), (91.44, 25.4)),
    ])

    symbol_tree = kicad_sexpr.parse(
        (out_dir / "large-features.kicad_sym").read_text(encoding="utf-8")
    )
    top_symbols = {
        kicad_sexpr.strip_quotes(symbol[1]): symbol
        for symbol in symbol_tree[1:]
        if isinstance(symbol, list) and symbol and symbol[0] == "symbol"
    }
    for cell_name in ["R", "C"]:
        assert kicad_sexpr.find_first(top_symbols[cell_name], "pin_numbers") == [
            "pin_numbers", "hide",
        ]
        assert kicad_sexpr.find_first(top_symbols[cell_name], "pin_names")[-1] == (
            "hide"
        )

    connector = top_symbols["CON16W"]
    assert kicad_sexpr.find_first(connector, "pin_numbers") == [
        "pin_numbers", "hide",
    ]
    assert kicad_sexpr.find_first(connector, "pin_names") is None

    uart_bridge_pin_unit = next(
        unit
        for unit in kicad_sexpr.find_all(top_symbols["UART_BRIDGE"], "symbol")
        if kicad_sexpr.strip_quotes(unit[1]) == "UART_BRIDGE_1_1"
    )
    uart_bridge_pin_names = {
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(pin, "number")[1]):
        kicad_sexpr.strip_quotes(kicad_sexpr.find_first(pin, "name")[1])
        for pin in kicad_sexpr.find_all(uart_bridge_pin_unit, "pin")
    }
    assert uart_bridge_pin_names == {
        "2": "~{RTS}", "6": "~{CTS}", "11": "~{RESET}",
    }

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        rc_out = tmp_path / "rc-out"
        rc_result = subprocess.run(
            hk_argv("--kicad-rc", dsn, rc_out),
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rc_result.returncode == 0, rc_result.stderr
        groups = []
        for directory in [out_dir, rc_out]:
            netlist = tmp_path / f"{directory.name}.net"
            export_result = subprocess.run(
                [
                    kicad_cli, "sch", "export", "netlist",
                    "--output", str(netlist),
                    str(directory / "large-features.kicad_sch"),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert export_result.returncode == 0, export_result.stderr
            groups.append(_net_ref_groups(netlist))
        assert groups[0] == groups[1]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_uses_explicit_off_page_connectors(
    dsn_fixtures, tmp_path,
):
    page1 = dsn_fixtures.make_page(
        "01_EXPLICIT",
        nets={
            1: "SHARED",
            2: "SAME_NAME_ONLY",
            3: "ROTATED",
            4: "MIRRORED_INPUT",
            5: "SLASH_RIGHT",
        },
        wires=[
            (1, 0, 0, 20, 0),
            (2, 0, 50, 20, 50),
            (3, 50, 50, 50, 80),
            (4, 80, 100, 100, 100),
            (5, 300, 150, 320, 150),
        ],
        components=[
            ("TP", "S1", 0, 20, 0, 0, [(1, 20, 0, 1)]),
            ("TP", "A1", 0, 20, 50, 0, [(1, 20, 50, 2)]),
            ("TP", "R1", 0, 50, 80, 0, [(1, 50, 80, 3)]),
            ("TP", "M1", 0, 80, 100, 0, [(1, 80, 100, 4)]),
            ("TP", "V1", 0, 320, 150, 0, [(1, 320, 150, 5)]),
        ],
        off_page_connectors=[
            ("OFFPAGELEFT-L", (0, -10, 100, 10), 0),
            ("OFFPAGELEFT-B", (40, 50, 60, 100), 3),
            ("OFFPAGE_LEFT-IN", (100, 90, 200, 110), 4),
            ("OFFPAGELEFT/R", (200, 140, 300, 160), 6),
            ("OFFPAGELEFT-L", (200, 190, 300, 210), 0),
        ],
    )
    page2 = dsn_fixtures.make_page(
        "02_EXPLICIT",
        nets={1: "SHARED", 2: "SAME_NAME_ONLY"},
        wires=[(1, 0, 0, 20, 0), (2, 0, 50, 20, 50)],
        components=[
            ("TP", "S2", 0, 20, 0, 0, [(1, 20, 0, 1)]),
            ("TP", "A2", 0, 20, 50, 0, [(1, 20, 50, 2)]),
        ],
        off_page_connectors=[
            ("OFFPAGELEFT-R", (-100, -10, 0, 10), 0),
        ],
    )
    dsn = tmp_path / "explicit-offpage.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page1,
        "Views/SCHEMATIC1/Pages/Page2": page2,
        "Cache": dsn_fixtures.make_cache({
            "TP": [("P", 0, 0, 0, 0, 0x21)],
        }),
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    page1_tree = kicad_sexpr.parse(
        (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    )
    page1_labels = []
    for label in kicad_sexpr.find_all(page1_tree, "global_label"):
        at = kicad_sexpr.find_first(label, "at")
        page1_labels.append((
            kicad_sexpr.strip_quotes(label[1]),
            tuple(kicad_sexpr.to_float(value) for value in at[1:4]),
        ))
    assert page1_labels == [
        ("SHARED", (0.0, 0.0, 0.0)),
        ("ROTATED", (12.7, 12.7, 270.0)),
        ("MIRRORED_INPUT", (25.4, 25.4, 0.0)),
        ("SLASH_RIGHT", (76.2, 38.1, 180.0)),
    ]

    page2_tree = kicad_sexpr.parse(
        (out_dir / "Page2.kicad_sch").read_text(encoding="utf-8")
    )
    assert [
        kicad_sexpr.strip_quotes(label[1])
        for label in kicad_sexpr.find_all(page2_tree, "global_label")
    ] == ["SHARED"]

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "explicit-offpage.net"
        export_result = subprocess.run(
            [
                kicad_cli, "sch", "export", "netlist",
                "--output", str(netlist),
                str(out_dir / "explicit-offpage.kicad_sch"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        groups = _net_pin_groups(netlist)
        assert (("S1", "1"), ("S2", "1")) in groups
        assert not any({("A1", "1"), ("A2", "1")} <= set(group)
                       for group in groups)


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_repeated_net_names_stay_local(
    dsn_fixtures, tmp_path,
):
    page_names = ["RailName", "RAILNAME", "RailName"]
    members = {"Cache": dsn_fixtures.make_cache({
        "TP": [("P", 0, 0, 10, 0, 0x21)],
    })}
    for page_number, net_name in enumerate(page_names, start=1):
        members[f"Views/SCHEMATIC1/Pages/Page{page_number}"] = (
            dsn_fixtures.make_page(
                f"0{page_number}_CASE",
                nets={1: net_name},
                wires=[(1, 0, 0, 20, 0)],
                components=[("TP", f"TP{page_number}", 0, 0, 0, 0)],
            )
        )

    dsn = tmp_path / "case-nets.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip(members))
    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    for page_number in range(1, 4):
        tree = kicad_sexpr.parse(
            (out_dir / f"Page{page_number}.kicad_sch").read_text(encoding="utf-8")
        )
        assert not kicad_sexpr.find_all(tree, "global_label")
        assert [
            kicad_sexpr.strip_quotes(label[1])
            for label in kicad_sexpr.find_all(tree, "label")
        ] == ["RailName"]

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "case-nets.net"
        export_result = subprocess.run(
            [
                kicad_cli, "sch", "export", "netlist",
                "--output", str(netlist), str(out_dir / "case-nets.kicad_sch"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        assert (("TP1", "1"), ("TP2", "1"), ("TP3", "1")) not in (
            _net_pin_groups(netlist)
        )


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_root_matrix_and_worksheet(dsn_fixtures, tmp_path):
    members = {
        f"Views/SCHEMATIC1/Pages/Page{page_number}": dsn_fixtures.make_page(
            f"0{page_number}_PAGE"
        )
        for page_number in range(1, 7)
    }
    dsn = tmp_path / "layout.DSN"
    dsn.write_bytes(dsn_fixtures.make_zip(members))

    out_dir = tmp_path / "with-worksheet"
    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    root = kicad_sexpr.parse(
        (out_dir / "layout.kicad_sch").read_text(encoding="utf-8")
    )
    sheets = kicad_sexpr.find_all(root, "sheet")
    assert [
        tuple(map(kicad_sexpr.to_float, kicad_sexpr.find_first(sheet, "at")[1:3]))
        for sheet in sheets
    ] == [
        (15.0, 25.0), (15.0, 42.0), (15.0, 59.0), (15.0, 76.0),
        (83.0, 25.0), (83.0, 42.0),
    ]

    worksheet = (out_dir / "layout.kicad_wks").read_text(encoding="utf-8")
    assert 'Title: %T' in worksheet
    assert '(repeat 100)' in worksheet
    project = json.loads((out_dir / "layout.kicad_pro").read_text(encoding="utf-8"))
    assert project["schematic"]["page_layout_descr_file"] == "layout.kicad_wks"

    no_worksheet_dir = tmp_path / "without-worksheet"
    result = subprocess.run(
        hk_argv("--no-worksheet", dsn, no_worksheet_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert not (no_worksheet_dir / "layout.kicad_wks").exists()
    project = json.loads(
        (no_worksheet_dir / "layout.kicad_pro").read_text(encoding="utf-8")
    )
    assert "page_layout_descr_file" not in project["schematic"]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_kicad_symbol_and_font_options(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_OPTIONS",
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
            (
                "R", "R1", 1, 100, 100, 0,
                [(1, 90, 100, 4), (2, 110, 100, 5)],
            ),
            (
                "C", "C1", 1, 100, 200, 0,
                [(1, 90, 200, 6), (2, 110, 200, 7)],
            ),
            ("TOUCH", "X1", 0, 110, 100, 0, [(1, 110, 100, 5)]),
        ],
        power_symbols=[
            ("GND", 0, 0),
            ("VCC_BAR", 100, 0),
            ("VCC_BAR", 200, 0),
        ],
        texts=[("Arial text", (20, 140, 120, 160), 1, 48)],
    )
    cache = dsn_fixtures.make_cache({
        "R": [
            ("1", -10, 0, -5, 0, 0x21),
            ("2", 10, 0, 5, 0, 0x21),
        ],
        "C": [
            ("1", -10, 0, -5, 0, 0x21),
            ("2", 10, 0, 5, 0, 0x21),
        ],
        "TP": [("P", 0, 0, 10, 0, 0x21)],
        "TOUCH": [("P", 0, 0, 10, 0, 0x21)],
    })
    cache += dsn_fixtures.make_cache_pin_numbers({
        "R": ["1", "2"],
        "C": ["1", "2"],
    })
    library = dsn_fixtures.make_library(
        ["unused", "10k"], styles=[(6, 400, False, 0, "Arial")]
    )
    dsn = tmp_path / "options.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page,
        "Cache": cache,
        "Library": library,
    }))

    default_out = tmp_path / "default-out"
    default_result = subprocess.run(
        hk_argv(dsn, default_out),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert default_result.returncode == 0, default_result.stderr
    default_schematic = (default_out / "Page1.kicad_sch").read_text(
        encoding="utf-8"
    )
    assert '(face "Arial")' in default_schematic
    assert '(lib_id "R")' in default_schematic
    assert '(lib_id "C")' in default_schematic
    assert '(symbol "power:CUSTOM_RAIL"' in default_schematic

    result = subprocess.run(
        hk_argv("--kicad-power", "--kicad-rc", "--kicad-fonts", dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    schematic = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    assert '(symbol "power:GND"' in schematic
    assert '(symbol "power:+3V3"' in schematic
    assert '(symbol "power:VCC"' in schematic
    assert '(symbol "power:CUSTOM_RAIL"' not in schematic
    assert '(lib_id "power:VCC")' in schematic
    assert '(property "Value" "CUSTOM_RAIL"' in schematic
    assert '(symbol "Device:R"' in schematic
    assert '(symbol "Device:C"' in schematic
    assert '(lib_id "Device:R")' in schematic
    assert '(lib_id "Device:C")' in schematic
    assert '(at 25.4 25.4 90)' in schematic
    assert '(face "Arial")' not in schematic

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "options.net"
        export_result = subprocess.run(
            [
                kicad_cli, "sch", "export", "netlist",
                "--output", str(netlist), str(out_dir / "Page1.kicad_sch"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        assert "CUSTOM_RAIL" in netlist.read_text(encoding="utf-8")
        assert _net_pin_groups(netlist) == [
            (("C1", "1"),), (("C1", "2"),),
            (("P1", "1"),), (("P2", "1"),), (("P3", "1"),),
            (("R1", "1"),), (("R1", "2"), ("X1", "1")),
        ]


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_kicad_rc_uses_cache_hotpoints(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_RC_CACHE",
        nets={1: "LEFT", 2: "RIGHT"},
        wires=[(1, 50, 100, 90, 100), (2, 110, 100, 150, 100)],
        components=[
            ("TP", "L1", 0, 50, 100, 0, [(1, 50, 100, 1)]),
            # Some real format variants yield unrelated page-pin coordinates.
            # R/C geometry still has authoritative hotpoints in Cache.
            ("R", "R1", 0, 100, 100, 0,
             [(1, 500, 500, 1), (2, 600, 500, 2)]),
            ("TP", "R2", 0, 150, 100, 0, [(1, 150, 100, 2)]),
        ],
    )
    cache = dsn_fixtures.make_cache({
        "R": [
            ("1", -10, 0, -5, 0, 0x21),
            ("2", 10, 0, 5, 0, 0x21),
        ],
        "TP": [("P", 0, 0, 10, 0, 0x21)],
    })
    cache += dsn_fixtures.make_cache_pin_numbers({"R": ["1", "2"]})
    dsn = tmp_path / "rc-cache.DSN"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    default_out = tmp_path / "default"
    rc_out = tmp_path / "rc"
    for args in ([str(dsn), str(default_out)],
                 ["--kicad-rc", str(dsn), str(rc_out)]):
        result = subprocess.run(
            hk_argv(*args), capture_output=True, text=True, timeout=30,
        )
        assert result.returncode == 0, result.stderr

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlists = []
        for output in (default_out, rc_out):
            netlist = tmp_path / f"{output.name}.net"
            result = subprocess.run(
                [kicad_cli, "sch", "export", "netlist", "--output", str(netlist),
                 str(output / "Page1.kicad_sch")],
                capture_output=True, text=True, timeout=30,
            )
            assert result.returncode == 0, result.stderr
            netlists.append(netlist)
        assert _net_ref_groups(netlists[0]) == _net_ref_groups(netlists[1])


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_native_power_symbols(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_POWER",
        nets={1: "GND", 2: "+3V3", 3: "PIN_RAIL", 4: "PLAIN"},
        wires=[
            (1, 0, 0, 20, 0),
            (2, 100, 20, 140, 20),
            (4, 0, 100, 20, 100),
        ],
        components=[
            ("TP", "G1", 0, 20, 0, 0),
            ("TP", "V1", 0, 100, 20, 0),
            ("TP", "V2", 0, 140, 20, 0),
            ("TP", "P1", 0, 200, 50, 0, [(1, 200, 50, 3)]),
            ("TP", "N1", 0, 0, 100, 0),
        ],
        power_symbols=[
            ("GND", 0, 0),
            ("VCC_BAR", 120, 20, 1, (-12, -8, 0)),
            ("VCC_CIRCLE", 200, 50, 2),
            ("AG", 300, 50, 3),
            ("USB20_VBUSEN", 350, 50),
        ],
    )
    cache = dsn_fixtures.make_cache({
        "TP": [("P", 0, 0, 10, 0, 0x21)],
    })
    dsn = tmp_path / "power.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    schematic = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    tree = kicad_sexpr.parse(schematic)
    assert '(symbol "power:GND"' in schematic
    assert '(symbol "power:+3V3"' in schematic
    assert '(symbol "power:PIN_RAIL"' in schematic
    assert '(symbol "power:AG"' in schematic
    assert "USB20_VBUSEN" not in schematic
    assert "(circle" in schematic
    assert '(reference "#PWR01")' in schematic
    assert '(reference "#PWR04")' in schematic

    labels = [
        kicad_sexpr.strip_quotes(label[1])
        for label in kicad_sexpr.find_all(tree, "label")
    ]
    assert labels == ["PLAIN", "PLAIN"]
    assert not kicad_sexpr.find_all(tree, "global_label")

    placed_power = []
    for symbol in kicad_sexpr.find_all(tree, "symbol"):
        lib_id = kicad_sexpr.find_first(symbol, "lib_id")
        at = kicad_sexpr.find_first(symbol, "at")
        if lib_id and at:
            name = kicad_sexpr.strip_quotes(lib_id[1])
            if name.startswith("power:"):
                placed_power.append((name, tuple(map(kicad_sexpr.to_float, at[1:4]))))
                if name == "power:+3V3":
                    value = next(
                        prop for prop in kicad_sexpr.find_all(symbol, "property")
                        if kicad_sexpr.strip_quotes(prop[1]) == "Value"
                    )
                    value_at = kicad_sexpr.find_first(value, "at")
                    # Centre anchor derived from real per-glyph metrics. The
                    # earlier (27.43, 1.27) came from a char-count estimate
                    # (len * 5.0 wide, 6.0 tall, no cap-height nudge) that put
                    # power labels ~0.75 mm / ~0.95 mm off their OrCAD position.
                    # Coordinates carry four decimals: rounding each emitted
                    # number to two let a symbol-local offset and its placement
                    # anchor round apart, leaving pins off their wires.
                    assert tuple(map(kicad_sexpr.to_float, value_at[1:4])) == (
                        26.993,
                        1.6657,
                        90.0,
                    )
                    assert kicad_sexpr.find_first(value, "hide") is None
    assert placed_power == [
        ("power:GND", (0.0, 0.0, 0.0)),
        ("power:+3V3", (30.48, 5.08, 90.0)),
        ("power:PIN_RAIL", (50.8, 12.7, 180.0)),
        ("power:AG", (76.2, 12.7, 270.0)),
    ]

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "power.net"
        export_result = subprocess.run(
            [
                kicad_cli,
                "sch",
                "export",
                "netlist",
                "--output",
                str(netlist),
                str(out_dir / "Page1.kicad_sch"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr
        groups = _net_pin_groups(netlist)
        assert any({("V1", "1"), ("V2", "1")} <= set(group) for group in groups)
        assert any(("P1", "1") in group for group in groups)


@pytest.mark.skipif(shutil.which("runghc") is None, reason="runghc not installed")
def test_dsn2kicad_hk_component_fields_and_page_artwork(dsn_fixtures, tmp_path):
    page = dsn_fixtures.make_page(
        "01_ARTWORK",
        components=[(
            "RES", "R1", 3, 100, 120, 5,
            [(1, 100, 90, 0), (2, 100, 110, 0)],
            [(2, -20, 10, 1), (1, -20, -10, 0)],
        )],
        texts=[("Heading\nDetail", (40, 50, 160, 90), 1, 8)],
        graphics=[
            {
                "kind": "rectangle", "coords": (20, 30, 180, 100),
                "color_idx": 8, "line_style": 1, "line_width": 2,
                "fill_style": 2,
            },
            {
                "kind": "line", "coords": (20, 110, 180, 110),
                "color_idx": 28,
            },
            {
                "kind": "ellipse", "coords": (200, 30, 240, 70),
                "color_idx": 18, "fill_style": 0,
            },
            {
                "kind": "polygon", "coords": (0, 0, 0, 0),
                "color_idx": 9, "fill_style": 0,
                "points": [(260, 30), (280, 50), (260, 70), (260, 30)],
            },
        ],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [
            ("1", 0, 0, 10, 0, 0x21),
            ("2", 20, 0, 10, 0, 0x21),
        ],
    })
    library = dsn_fixtures.make_library(
        ["unused", "Part Reference", "Value", "10k *DNP"],
        styles=[(6, 700, True, 900, "Arial")],
    )
    dsn = tmp_path / "artwork.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({
        PAGE: page,
        "Cache": cache,
        "Library": library,
    }))

    result = subprocess.run(
        hk_argv(dsn, out_dir),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    schematic = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    tree = kicad_sexpr.parse(schematic)
    placed = next(
        symbol for symbol in kicad_sexpr.find_all(tree, "symbol")
        if kicad_sexpr.find_first(symbol, "lib_id")
    )
    placed_at = kicad_sexpr.find_first(placed, "at")
    assert tuple(map(kicad_sexpr.to_float, placed_at[1:4])) == (
        25.4,
        25.4,
        270.0,
    )
    mirror = kicad_sexpr.find_first(placed, "mirror")
    assert mirror[1] == "y"
    properties = {
        kicad_sexpr.strip_quotes(prop[1]): prop
        for prop in kicad_sexpr.find_all(placed, "property")
    }
    assert kicad_sexpr.to_float(
        kicad_sexpr.find_first(properties["Reference"], "at")[3]
    ) == 90.0
    assert kicad_sexpr.to_float(
        kicad_sexpr.find_first(properties["Value"], "at")[3]
    ) == 0.0
    assert kicad_sexpr.strip_quotes(properties["Value"][2]) == "10k"
    assert kicad_sexpr.find_first(placed, "dnp") == ["dnp", "yes"]
    assert kicad_sexpr.find_first(placed, "in_bom") == ["in_bom", "no"]
    ref_effects = kicad_sexpr.find_first(properties["Reference"], "effects")
    ref_font = kicad_sexpr.find_first(ref_effects, "font")
    assert kicad_sexpr.find_first(ref_font, "face")[1] == '"Arial"'

    page_texts = [
        kicad_sexpr.strip_quotes(text[1])
        for text in kicad_sexpr.find_all(tree, "text")
    ]
    assert page_texts == ["Heading", "Detail"]
    for text in kicad_sexpr.find_all(tree, "text"):
        assert kicad_sexpr.to_float(kicad_sexpr.find_first(text, "at")[3]) == 90.0
        effects = kicad_sexpr.find_first(text, "effects")
        font = kicad_sexpr.find_first(effects, "font")
        assert kicad_sexpr.find_first(font, "bold") == ["bold", "yes"]
        assert kicad_sexpr.find_first(font, "italic") == ["italic", "yes"]
        assert kicad_sexpr.find_first(font, "color") == [
            "color", "255", "0", "0", "1",
        ]

    assert "(type dash)" in schematic
    assert "(type hatch)" in schematic
    assert "(radius 5.08)" in schematic
    assert "(color 0 0 255 1)" in schematic
    uuids = re.findall(r'\(uuid "([0-9a-f-]+)"\)', schematic)
    assert len(uuids) == len(set(uuids))

    kicad_cli = shutil.which("kicad-cli")
    if kicad_cli:
        netlist = tmp_path / "artwork.net"
        export_result = subprocess.run(
            [
                kicad_cli,
                "sch",
                "export",
                "netlist",
                "--output",
                str(netlist),
                str(out_dir / "Page1.kicad_sch"),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert export_result.returncode == 0, export_result.stderr


# ---------------------------------------------------------------------------
# Reference/Value text placement — real font metrics vs char-count width
# ---------------------------------------------------------------------------

def _property_at(page_sch, prop, value):
    """Return (x, y, angle) of a component property's placement anchor."""
    m = re.search(
        r'\(property\s+"%s"\s+"%s".*?\(at\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\)'
        % (re.escape(prop), re.escape(value)),
        page_sch, re.DOTALL)
    assert m, f'no {prop} property "{value}" in generated page'
    return float(m.group(1)), float(m.group(2)), float(m.group(3))


@pytest.mark.parametrize("kicad_fonts", [False, True])
def test_dsn2kicad_hk_reference_placement_uses_font_metrics(
        dsn_fixtures, tmp_path, kicad_fonts):
    """Reference text is centred with real per-glyph widths, not a char count.

    Two references of equal length but very different rendered width ("MMMMMM1"
    vs "iiiiii1") share one display-field offset. A char-count width model
    (len * size * k) centres both at the same X; real metrics place the wide
    'M' run measurably to the right (>2.5 mm here). Mirrors _text_box_dims /
    measure_text_width in dsn2kicad_py.py, in both outline (Arial) and
    --kicad-fonts (Newstroke) measurement modes. (The trailing digit only makes
    both strings valid OrCAD reference designators; it is identical, so it
    cancels out of the X difference.)
    """
    fields = [(0, 200, 0, 0)]  # (property_index=Reference, x_off, y_off, turns)
    page = dsn_fixtures.make_page(
        "01_TEST",
        components=[
            ("RES", "MMMMMM1", 0, 0, 0, 0, None, fields),
            ("RES", "iiiiii1", 0, 0, 0, 0, None, fields),
        ],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [("A", 0, 0, 50, 0, 0x20), ("K", 100, 0, 50, 0, 0x21)],
    })
    dsn = tmp_path / "metrics.DSN"
    out_dir = tmp_path / "out"
    dsn.write_bytes(dsn_fixtures.make_zip({PAGE: page, "Cache": cache}))

    flags = ["--kicad-fonts"] if kicad_fonts else []
    argv = hk_argv(*flags, dsn, out_dir)
    result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr

    page_sch = (out_dir / "Page1.kicad_sch").read_text(encoding="utf-8")
    wide_x = _property_at(page_sch, "Reference", "MMMMMM1")[0]
    narrow_x = _property_at(page_sch, "Reference", "iiiiii1")[0]
    # Char-count width would make these identical (both 6 glyphs); real metrics
    # separate them by the difference in rendered width of 'M'*6 vs 'i'*6.
    assert wide_x - narrow_x > 1.0, (wide_x, narrow_x)
