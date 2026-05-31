"""
Unit tests for the OLB parser and XML exporter.

Tests parse each of the 8 synthetic OLB files (0000-0007) from OpenOrCadParser's
test suite and compare the generated XML against OrCAD's own XML export.
"""

import os
import sys
import pytest
import olefile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

from olb_parser import parse_olb, PrimLine, PrimCommentText, PrimRect, PrimEllipse
from olb_parser import PrimArc, PrimBezier, PrimPolyline, PrimBitmap

import importlib.util
olb2xml_path = os.path.join(os.path.dirname(__file__), '..', 'scripts', 'olb2xml.py')
_spec = importlib.util.spec_from_file_location('olb2xml', olb2xml_path)
olb2xml_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(olb2xml_mod)

TEST_DATA = os.path.join(os.path.dirname(__file__), 'test_data_olb')


def _parse(name: str):
    ole = olefile.OleFileIO(os.path.join(TEST_DATA, f'{name}.OLB'))
    olb = parse_olb(ole)
    ole.close()
    return olb


def _ref_xml(name: str) -> str:
    with open(os.path.join(TEST_DATA, f'{name}.xml'), 'r', encoding='utf-8') as f:
        return f.read()


def _gen_xml(olb, name: str) -> str:
    olb_path = f"z:\\unittests\\olb\\{name}.olb"
    return olb2xml_mod.olb_to_xml(olb, olb_path)


def _get_prim(olb, idx=0):
    return olb.packages[0].part_cells[0].library_parts[0].primitives[idx]


def _get_lp(olb):
    return olb.packages[0].part_cells[0].library_parts[0]


# --- XML comparison tests ---

@pytest.mark.parametrize("name,prim_name", [
    ("0000", "Line"),
    ("0001", "CommentText"),
    ("0002", "Rect"),
    ("0003", "Ellipse"),
    ("0004", "Arc"),
    ("0005", "Bezier"),
    ("0006", "Polyline"),
    ("0007", "Bitmap"),
])
def test_olb_xml_match(name, prim_name):
    olb = _parse(name)
    generated = _gen_xml(olb, name)
    reference = _ref_xml(name)
    assert generated == reference, f"XML mismatch for {name} ({prim_name})"


# --- Primitive-specific structural tests ---

def test_0000_line():
    olb = _parse("0000")
    p = _get_prim(olb)
    assert isinstance(p, PrimLine)
    assert (p.x1, p.y1, p.x2, p.y2) == (10, 20, 20, 40)
    assert p.line_style == 3
    assert p.line_width == 2


def test_0001_commenttext():
    olb = _parse("0001")
    p = _get_prim(olb)
    assert isinstance(p, PrimCommentText)
    assert p.loc_x == 28 and p.loc_y == 20
    assert p.x1 == 28 and p.x2 == 118
    assert "line break" in p.name
    assert "\n" in p.name


def test_0002_rect():
    olb = _parse("0002")
    p = _get_prim(olb)
    assert isinstance(p, PrimRect)
    assert (p.x1, p.y1, p.x2, p.y2) == (20, 12, 30, 62)
    assert p.fill_style == 2
    assert p.hatch_style == 5
    assert p.line_style == 1


def test_0003_ellipse():
    olb = _parse("0003")
    p = _get_prim(olb)
    assert isinstance(p, PrimEllipse)
    assert (p.x1, p.y1, p.x2, p.y2) == (10, 20, 40, 30)
    assert p.fill_style == 0
    assert p.hatch_style == -1
    assert p.line_width == 0


def test_0004_arc():
    olb = _parse("0004")
    p = _get_prim(olb)
    assert isinstance(p, PrimArc)
    assert (p.x1, p.y1, p.x2, p.y2) == (0, 20, 120, 40)
    assert (p.start_x, p.start_y) == (60, 20)
    assert (p.end_x, p.end_y) == (120, 30)
    assert p.line_style == 1


def test_0005_bezier():
    olb = _parse("0005")
    p = _get_prim(olb)
    assert isinstance(p, PrimBezier)
    assert len(p.points) == 13
    assert (p.points[0].x, p.points[0].y) == (10, 10)
    assert (p.points[1].x, p.points[1].y) == (30, 20)
    assert (p.points[-1].x, p.points[-1].y) == (30, 40)


def test_0006_polyline():
    olb = _parse("0006")
    p = _get_prim(olb)
    assert isinstance(p, PrimPolyline)
    assert len(p.points) == 4
    assert (p.points[0].x, p.points[0].y) == (10, 10)
    assert (p.points[3].x, p.points[3].y) == (30, 20)


def test_0007_bitmap():
    olb = _parse("0007")
    p = _get_prim(olb)
    assert isinstance(p, PrimBitmap)
    assert p.loc_x == 20 and p.loc_y == 10
    assert p.bmp_width == 5 and p.bmp_height == 1
    assert len(p.raw_img_data) == 56


# --- Library / structure tests ---

def test_library_fonts():
    olb = _parse("0000")
    lib = olb.library
    assert len(lib.text_fonts) == 2
    assert lib.text_fonts[0].face_name == "Arial"
    assert lib.text_fonts[1].face_name == "Courier New"


def test_library_page_settings():
    olb = _parse("0000")
    ps = olb.library.page_settings
    assert ps.pin_to_pin == 100
    assert ps.horizontal_count == 5
    assert ps.vertical_count == 4


def test_package_metadata():
    olb = _parse("0000")
    pkg = olb.packages[0]
    assert pkg.name == "0000"
    assert pkg.ref_des == "U"
    assert pkg.timestamp == 1641466916
    assert pkg.timezone == 1720


def test_display_props():
    olb = _parse("0000")
    lp = _get_lp(olb)
    assert len(lp.display_props) == 2
    lib = olb.library
    assert lib.str_lst[lp.display_props[0].name_idx] == "Part Reference"
    assert lib.str_lst[lp.display_props[1].name_idx] == "Value"


def test_general_properties():
    olb = _parse("0000")
    gp = _get_lp(olb).general_properties
    assert gp is not None
    assert gp.ref_des == "U"
    assert gp.pin_name_visible is True
    assert gp.pin_name_rotate is True
    assert gp.pin_number_visible is True


def test_symbol_bbox():
    olb = _parse("0000")
    bbox = _get_lp(olb).bbox
    assert bbox is not None
    assert (bbox.x1, bbox.y1, bbox.x2, bbox.y2) == (0, 0, 50, 50)
