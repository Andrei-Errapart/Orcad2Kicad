# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
import io
import struct


class TestExtractStrings:
    def test_basic(self, dsn2kicad):
        data = b'\x00Hello\x00World!\x00'
        result = dsn2kicad._extract_strings(data, min_len=3)
        names = [s for _, s in result]
        assert "Hello" in names
        assert "World!" in names

    def test_min_len(self, dsn2kicad):
        data = b'\x00AB\x00CDE\x00'
        result_2 = dsn2kicad._extract_strings(data, min_len=2)
        result_3 = dsn2kicad._extract_strings(data, min_len=3)
        names_2 = [s for _, s in result_2]
        names_3 = [s for _, s in result_3]
        assert "AB" in names_2
        assert "AB" not in names_3
        assert "CDE" in names_3

    def test_empty(self, dsn2kicad):
        assert dsn2kicad._extract_strings(b'', min_len=2) == []

    def test_all_binary(self, dsn2kicad):
        assert dsn2kicad._extract_strings(b'\x00\x01\x02\x03', min_len=2) == []


class TestPagePropertyTable:
    """The title-block property table at the tail of a page header."""

    def _table(self, pairs):
        out = struct.pack('<H', len(pairs))
        for name_idx, value_idx in pairs:
            out += struct.pack('<II', name_idx, value_idx)
        return out

    def test_decodes_pairs(self, dsn2kicad):
        values = ['', 'Title', 'Cover', 'RevCode', 'B']
        data = b'\x99' * 16 + self._table([(1, 2), (3, 4)])
        pairs = dsn2kicad.parse_page_property_table(
            data, 0, len(data), values,
        )
        assert pairs == [(1, 2), (3, 4)]

    def test_rejects_blank_property_name(self, dsn2kicad):
        # Index 0 is the empty pool entry, so it can never be a name.
        values = ['', 'Title', 'Cover']
        data = b'\x99' * 16 + self._table([(0, 2)])
        assert dsn2kicad.parse_page_property_table(
            data, 0, len(data), values,
        ) == []

    def test_rejects_out_of_range_index(self, dsn2kicad):
        values = ['', 'Title']
        data = b'\x99' * 16 + self._table([(1, 99)])
        assert dsn2kicad.parse_page_property_table(
            data, 0, len(data), values,
        ) == []

    def test_resolves_title_block(self, dsn2kicad):
        values = ['', 'Title', 'Cover', 'RevCode', 'B', 'Doc', 'D-7']
        block = dsn2kicad.resolve_title_block(
            values, [(1, 2), (3, 4), (5, 6)], 1617261986,
        )
        assert block == {
            'title': 'Cover', 'rev': 'B', 'doc_number': 'D-7',
            'date': '2021-04-01',
        }

    def test_resolves_without_timestamp(self, dsn2kicad):
        values = ['', 'Title', 'Cover']
        block = dsn2kicad.resolve_title_block(values, [(1, 2)], None)
        assert block == {'title': 'Cover'}


class MockOle:
    def __init__(self, streams):
        self._streams = streams

    def openstream(self, path):
        if path in self._streams:
            return io.BytesIO(self._streams[path])
        raise Exception(f"Stream not found: {path}")

    def listdir(self, streams=True, storages=False):
        return [path.split("/") for path in self._streams]


class TestGetPageStreams:
    def test_finds_pages(self, dsn2kicad):
        ole = MockOle({
            "Views/SCHEMATIC1/Pages/Page1": b"data1",
            "Views/SCHEMATIC1/Pages/Page2": b"data2",
            "Library": b"other",
        })
        pages = dsn2kicad.get_page_streams(ole)
        assert len(pages) == 2
        assert "Views/SCHEMATIC1/Pages/Page1" in pages
        assert "Views/SCHEMATIC1/Pages/Page2" in pages

    def test_no_pages(self, dsn2kicad):
        ole = MockOle({"Library": b"data"})
        pages = dsn2kicad.get_page_streams(ole)
        assert pages == []

    def test_sorted_order(self, dsn2kicad):
        ole = MockOle({
            "Views/SCHEMATIC1/Pages/Page3": b"",
            "Views/SCHEMATIC1/Pages/Page1": b"",
            "Views/SCHEMATIC1/Pages/Page2": b"",
        })
        pages = dsn2kicad.get_page_streams(ole)
        names = [p.split("/")[-1] for p in pages]
        assert names == sorted(names)


class TestParseComponents:
    def test_four_letter_reference_designator(self, dsn2kicad):
        data = bytearray(b"CN-PCIe_64p.Normal\x00" + bytes(16))
        data += bytes([0x18])
        data += struct.pack('<H', 5)
        data += b"PCIE1\x00"
        data += struct.pack('<H', 1641)

        comps = dsn2kicad.parse_components(bytes(data))

        assert comps[0]["ref"] == "PCIE1"
        assert comps[0]["value_idx"] == 1641


class TestCacheGraphics:
    def test_parse_cache_pin_visibility_flag(self, dsn2kicad):
        marker = bytes([0xFF, 0xE4, 0x5C, 0x39])
        record = bytearray()
        record += marker
        record += struct.pack('<I', 0)
        record += struct.pack('<H', 1)
        record += b"1\x00"
        record += struct.pack('<iiii', 0, 10, -10, 10)
        record += bytes([0x20])
        record += bytes(24)
        data = b"PINFLAG.Normal\x00" + bytes(record)

        cells, *_ = dsn2kicad.parse_cache_cells(MockOle({"Cache": data}))

        assert cells["PINFLAG"][0] == ("1", -10, 10, 0, 10, 0x20)

    def test_filled_polygon_record(self, dsn2kicad):
        record = bytearray(28 + 4 * 3)
        struct.pack_into('<H', record, 0, 0x2c2c)
        struct.pack_into('<H', record, 26, 3)
        struct.pack_into('<hhh', record, 28, 0, 0, 10)
        struct.pack_into('<hhh', record, 34, 0, 10, 10)

        rects, lines, ellipses, arcs, polys, _plines, anns = dsn2kicad._parse_cache_graphics(
            bytes(record), 0, len(record))

        assert rects == []
        assert lines == []
        assert ellipses == []
        assert arcs == []
        assert anns == []
        assert polys == [[(0, 0), (0, 10), (10, 10)]]

    def test_filled_polygon_drops_redundant_close_points(self, dsn2kicad):
        record = bytearray(28 + 4 * 5)
        struct.pack_into('<H', record, 0, 0x2c2c)
        struct.pack_into('<H', record, 26, 5)
        for idx, point in enumerate([(2, 32), (2, 32), (0, 36), (4, 34), (2, 32)]):
            struct.pack_into('<hh', record, 28 + idx * 4, *point)

        *_, polys, _plines, _anns = dsn2kicad._parse_cache_graphics(bytes(record), 0, len(record))

        assert polys == [[(32, 2), (36, 0), (34, 4)]]

    def test_filled_polygon_trailing_path_becomes_line(self, dsn2kicad):
        record = bytearray(28 + 4 * 7)
        struct.pack_into('<H', record, 0, 0x2c2c)
        struct.pack_into('<H', record, 26, 7)
        points = [(10, 13), (10, 13), (10, 13), (15, 3), (4, 3), (10, 13), (4, 13)]
        for idx, point in enumerate(points):
            struct.pack_into('<hh', record, 28 + idx * 4, *point)

        _, lines, *_, polys, _plines, _anns = dsn2kicad._parse_cache_graphics(bytes(record), 0, len(record))

        assert lines == [(13, 10, 13, 4)]
        assert polys == [[(13, 10), (3, 15), (3, 4)]]

    def test_filled_polygon_arrowhead_keeps_tip_vertex(self, dsn2kicad):
        record = bytearray(28 + 4 * 6)
        struct.pack_into('<H', record, 0, 0x2c2c)
        struct.pack_into('<H', record, 26, 6)
        points = [(32, 40), (32, 40), (29, 33), (27, 35), (25, 36), (32, 40)]
        for idx, point in enumerate(points):
            struct.pack_into('<hh', record, 28 + idx * 4, *point)

        *_, polys, _plines, _anns = dsn2kicad._parse_cache_graphics(bytes(record), 0, len(record))

        assert polys == [[(40, 32), (33, 29), (35, 27), (36, 25)]]

    def test_emits_filled_polygon_in_symbol_body(self, dsn2kicad):
        symbol = dsn2kicad.lib_symbol_from_pins(
            "POLY",
            [],
            body_polygons=[[(0, 0), (1.27, 0), (1.27, -1.27)]],
        )

        assert '(symbol "POLY_0_1"' in symbol
        assert '(xy 0.00 0.00) (xy 1.27 0.00) (xy 1.27 -1.27)' in symbol
        assert '(fill\n\t\t\t\t\t\t(type outline)' in symbol
