# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Smoke tests for the in-progress Haskell dsn2kicad port."""
import json
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
DSN2KICAD_HK = SCRIPTS_DIR / "dsn2kicad-hk"
DSN2KICAD_PY = SCRIPTS_DIR / "dsn2kicad.py"
PAGE = "Views/SCHEMATIC1/Pages/Page1"

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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
    sw_symbol = next(
        symbol
        for symbol in kicad_sexpr.find_all(sym_tree, "symbol")
        if kicad_sexpr.strip_quotes(symbol[1]) == "SW"
    )
    assert kicad_sexpr.find_first(sw_symbol, "pin_numbers") is None
    assert kicad_sexpr.find_first(sw_symbol, "pin_names") is not None

    repeat_out = tmp_path / "repeat-out"
    repeat_result = subprocess.run(
        [str(DSN2KICAD_HK), str(dsn), str(repeat_out)],
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
    )
    page2 = dsn_fixtures.make_page(
        "02_CONNECT",
        nets={2: "SHARED"},
        wires=[(2, 0, 0, 20, 0)],
        components=[("TP", "G2", 0, 0, 0, 0)],
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
def test_dsn2kicad_hk_net_names_are_case_insensitive(dsn_fixtures, tmp_path):
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr

    for page_number in range(1, 4):
        tree = kicad_sexpr.parse(
            (out_dir / f"Page{page_number}.kicad_sch").read_text(encoding="utf-8")
        )
        assert [
            kicad_sexpr.strip_quotes(label[1])
            for label in kicad_sexpr.find_all(tree, "global_label")
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
        assert (("TP1", "1"), ("TP2", "1"), ("TP3", "1")) in (
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
        [str(DSN2KICAD_HK), "--no-worksheet", str(dsn), str(no_worksheet_dir)],
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
        [str(DSN2KICAD_HK), str(dsn), str(default_out)],
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
        [
            str(DSN2KICAD_HK),
            "--kicad-power",
            "--kicad-rc",
            "--kicad-fonts",
            str(dsn),
            str(out_dir),
        ],
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
    assert '(at 25.40 25.40 90)' in schematic
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
                    assert tuple(map(kicad_sexpr.to_float, value_at[1:4])) == (
                        27.43,
                        1.27,
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
        [str(DSN2KICAD_HK), str(dsn), str(out_dir)],
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
