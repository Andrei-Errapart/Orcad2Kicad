# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the synthetic-fixture builders, validated against the real parsers.

Each builder is exercised by round-tripping its output back through the actual
dsn2kicad parser it targets, so the fixtures stay in lock-step with the format
the converter reads.
"""
import io
import zipfile


class TestMakeZip:
    def test_roundtrips_members(self, dsn_fixtures):
        data = dsn_fixtures.make_zip({"Cache": b"abc", "Library": b"xyz"})
        assert data[:4] == b"PK\x03\x04"
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            assert zf.read("Cache") == b"abc"
            assert zf.read("Library") == b"xyz"


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

    def test_component_roundtrip(self, dsn_fixtures, dsn2kicad):
        page = dsn_fixtures.make_page(
            "01_FOO", components=[("RES", "R1", 1641)])
        comps = dsn2kicad.parse_components(page)
        assert comps[0]["cell"] == "RES"
        assert comps[0]["ref"] == "R1"
        assert comps[0]["value_idx"] == 1641


class TestMakeCache:
    def test_cache_cell_pin_roundtrip(self, dsn_fixtures, dsn2kicad, ole_zip):
        cache = dsn_fixtures.make_cache(
            {"RES": [("1", -10, 10, 0, 10, 0x20)]})
        z = ole_zip.ZipOleFile(io.BytesIO(
            dsn_fixtures.make_zip({"Cache": cache})))
        cells = dsn2kicad.parse_cache_cells(z)[0]
        assert cells["RES"][0] == ("1", -10, 10, 0, 10, 0x20)
