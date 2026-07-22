# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the synthetic-fixture builders, validated against the real parsers.

Each builder is exercised by round-tripping its output back through the actual
dsn2kicad parser it targets, so the fixtures stay in lock-step with the format
the converter reads.
"""
import io
import zipfile

import olefile


class TestMakeZip:
    def test_roundtrips_members(self, dsn_fixtures):
        data = dsn_fixtures.make_zip({"Cache": b"abc", "Library": b"xyz"})
        assert data[:4] == b"PK\x03\x04"
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            assert zf.read("Cache") == b"abc"
            assert zf.read("Library") == b"xyz"


class TestMakeOle:
    def test_roundtrips_nested_streams(self, dsn_fixtures):
        members = {
            "Cache": b"cache-data",
            "Views/NAMED/Pages/Page 1": b"page-data" * 600,
        }
        data = dsn_fixtures.make_ole(members)
        assert data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
        with olefile.OleFileIO(io.BytesIO(data)) as ole:
            assert sorted("/".join(path) for path in ole.listdir()) == sorted(members)
            for name, expected in members.items():
                actual = ole.openstream(name).read()
                assert actual[:len(expected)] == expected
                assert not actual[len(expected):].strip(b"\x00")


class TestMakePage:
    def test_header_name_and_paper(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page("01_FOO", paper="A4")
        assert dsn2kicad.parse_page_header(page) == ("01_FOO", "A4")

    def test_net_table_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page("01_FOO", nets={5: "GND", 7: "VCC"})
        assert dsn2kicad.parse_net_table(page) == {5: "GND", 7: "VCC"}

    def test_wire_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO", nets={5: "GND"}, wires=[(5, 0, 0, 100, 0)])
        nets = dsn2kicad.parse_net_table(page)
        wires = dsn2kicad.parse_wires(page, nets)
        assert len(wires) == 1
        w = wires[0]
        assert (w["x1"], w["y1"], w["x2"], w["y2"]) == (0, 0, 100, 0)
        assert w["net"] == "GND"

    def test_net_alias_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO", nets={5: "SIGNAL"}, aliases=[("signal", 40, 50)]
        )
        nets = dsn2kicad.parse_net_table(page)
        assert dsn2kicad.parse_net_aliases(page, nets) == [{
            "name": "SIGNAL",
            "x": 40,
            "y": 50,
        }]

    def test_component_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO", components=[("RES", "R1", 1641, 120, -30, 2)])
        comps = dsn2kicad.parse_components(page)
        assert comps[0]["cell"] == "RES"
        assert comps[0]["ref"] == "R1"
        assert comps[0]["value_idx"] == 1641
        assert (comps[0]["x"], comps[0]["y"], comps[0]["orient"]) == (
            120,
            -30,
            2,
        )

    def test_component_pin_net_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO",
            nets={5: "VDD"},
            components=[("TP", "TP1", 0, 40, 50, 0, [(1, 40, 50, 5)])],
        )
        nets = dsn2kicad.parse_net_table(page)
        comp = dsn2kicad.parse_components(page, nets)[0]
        assert comp["pin_nets"][(1, 40, 50)] == {
            "net_id": 5,
            "net": "VDD",
        }

    def test_component_display_fields_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO",
            components=[(
                "RES", "R1", 0, 100, 120, 5, None,
                [(1, -20, -10, 0), (2, -20, 10, 1)],
            )],
        )
        comp = dsn2kicad.parse_components(page)[0]
        assert comp["ref_off"] == (-20, -10)
        assert comp["val_off"] == (-20, 10)
        assert comp["ref_text_angle"] == 0
        assert comp["val_text_angle"] == 90

    def test_power_symbol_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO",
            power_symbols=[
                ("GND", 40, 50),
                ("VCC_BAR", 80, 90, 1, (-12, -8, 0)),
            ],
        )
        symbols = dsn2kicad.parse_power_symbols(page, {})
        assert [symbol["record_name"] for symbol in symbols] == [
            "GND",
            "VCC_BAR",
        ]
        assert dsn2kicad._power_symbol_hotpoint_candidates(symbols[0]) == [
            (40, 50),
        ]
        assert dsn2kicad._power_symbol_hotpoint_candidates(symbols[1]) == [
            (80, 90),
        ]
        assert symbols[1]["value_off"] == (-12, -8)
        assert symbols[1]["value_text_angle"] == 0

    def test_page_text_and_graphics_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO",
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
        texts = dsn2kicad.parse_text_annotations(page, "A3")
        assert texts[0]["text"] == "Heading\nDetail"
        assert texts[0]["bbox"] == (40, 50, 160, 90)
        assert texts[0]["style_id"] == 1
        rects, lines, ellipses, polygons = dsn2kicad.parse_page_graphics(
            page, "A3"
        )
        assert len(rects) == len(lines) == len(ellipses) == len(polygons) == 1
        assert rects[0]["stroke_type"] == "dash"
        assert rects[0]["width"] == 0.50
        assert rects[0]["fill"] == "hatch"
        assert polygons[0]["points"] == [(260, 30), (280, 50), (260, 70)]


class TestMakeCache:
    def test_cache_cell_pin_roundtrip(self, dsn_fixtures, dsn2kicad, ole_zip):
        cache = dsn_fixtures.make_cache(
            {"RES": [("1", -10, 10, 0, 10, 0x20)]})
        z = ole_zip.ZipOleFile(io.BytesIO(
            dsn_fixtures.make_zip({"Cache": cache})))
        cells = dsn2kicad.parse_cache_cells(z)[0]
        assert cells["RES"][0] == ("1", -10, 10, 0, 10, 0x20)

    def test_cache_pin_numbers_roundtrip(
        self, dsn_fixtures, dsn2kicad, ole_zip
    ):
        cache = dsn_fixtures.make_cache_pin_numbers(
            {"RES": ["A1", "K2"]}
        )
        z = ole_zip.ZipOleFile(io.BytesIO(
            dsn_fixtures.make_zip({"Cache": cache})))
        pin_numbers = dsn2kicad.parse_cache_cells(z)[3]
        assert pin_numbers["RES"] == ["A1", "K2"]


class TestMakeLibrary:
    def test_text_styles_roundtrip(self, dsn_fixtures, dsn2kicad, ole_zip):
        library = dsn_fixtures.make_library_styles([
            (6, 700, True, 900, "Arial"),
        ])
        z = ole_zip.ZipOleFile(io.BytesIO(
            dsn_fixtures.make_zip({"Library": library})
        ))
        assert dsn2kicad.parse_library_styles(z) == [{
            "tag": -6,
            "weight": 700,
            "italic": True,
            "escapement": 900,
            "face": "Arial",
            "ext_word": 0,
            "flag_byte": 0,
        }]

    def test_value_strings_roundtrip(self, dsn_fixtures, dsn2kicad, ole_zip):
        library = dsn_fixtures.make_library([
            "unused",
            "Part Reference",
            "Value",
            "10k *DNP",
        ])
        z = ole_zip.ZipOleFile(io.BytesIO(
            dsn_fixtures.make_zip({"Library": library})
        ))
        assert dsn2kicad.parse_library_value_strings(z) == [
            "unused",
            "Part Reference",
            "Value",
            "10k *DNP",
        ]
