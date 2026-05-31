#!/usr/bin/env python3
"""
Convert OrCAD OLB files to XML format matching OrCAD's own XML export schema.

Usage: olb2xml input.OLB [output.xml]
"""

import sys
import os
import base64
import xml.etree.ElementTree as ET
from xml.dom import minidom

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import olefile
from olb_parser import (
    parse_olb, OlbFile, Library, Package, LibraryPart, LogFont,
    PrimLine, PrimRect, PrimArc, PrimEllipse, PrimBezier, PrimPolyline,
    PrimPolygon, PrimCommentText, PrimBitmap, SymbolDisplayProp
)


def font_for_index(lib: Library, idx: int) -> dict:
    """Map a someData index to font attributes for DefaultFont XML output."""
    if idx > 0 and idx - 1 < len(lib.text_fonts):
        f = lib.text_fonts[idx - 1]
        return {
            "charset": str(f.charset),
            "escapement": str(f.escapement),
            "height": str(f.height),
            "italic": str(f.italic),
            "name": f.face_name,
            "orientation": str(f.orientation),
            "weight": str(f.weight),
            "width": str(f.width),
        }
    return {
        "charset": "0",
        "escapement": "0",
        "height": "8",
        "italic": "0",
        "name": "Arial",
        "orientation": "0",
        "weight": "400",
        "width": "0",
    }


def prop_font_attrs(lib: Library, text_font_idx: int) -> dict:
    """Get font attributes for PropFont in SymbolDisplayProp."""
    if text_font_idx > 0 and text_font_idx - 1 < len(lib.text_fonts):
        f = lib.text_fonts[text_font_idx - 1]
        return {
            "charset": str(f.charset),
            "escapement": str(f.escapement),
            "height": str(f.height),
            "italic": str(f.italic),
            "name": "",
            "orientation": str(f.orientation),
            "weight": str(f.weight),
            "width": str(f.width),
        }
    # textFontIdx=0 maps to the default font style used in SDPs
    return {
        "charset": "0",
        "escapement": "0",
        "height": "-9",
        "italic": "0",
        "name": "",
        "orientation": "0",
        "weight": "400",
        "width": "4",
    }


def comment_text_font_attrs(lib: Library, text_font_idx: int) -> dict:
    """Get font attributes for TextFont in CommentText."""
    # textFontIdx is 1-based: 0=default, 1=textFonts[0], etc.
    idx = text_font_idx - 1
    if 0 <= idx < len(lib.text_fonts):
        f = lib.text_fonts[idx]
        return {
            "charset": str(f.charset),
            "escapement": str(f.escapement),
            "height": str(f.height),
            "italic": str(f.italic),
            "name": f.face_name,
            "orientation": str(f.orientation),
            "weight": str(f.weight),
            "width": str(f.width),
        }
    return {
        "charset": "0",
        "escapement": "0",
        "height": "-9",
        "italic": "0",
        "name": "",
        "orientation": "0",
        "weight": "400",
        "width": "4",
    }


def olb_to_xml(olb: OlbFile, olb_path: str = "") -> str:
    """Convert parsed OLB to XML string matching OrCAD's export format."""
    lib = olb.library

    root = ET.Element("Lib")
    root.set("xmlns:xsd", "http://www.w3.org/2001/XMLSchema")
    root.set("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
    root.set("xsi:noNamespaceSchemaLocation",
             r"c:\vendor\spb_17.4\tools\capture\tclscripts\capdb\olb.xsd")

    # <Defn name="path.olb"/>
    defn = ET.SubElement(root, "Defn")
    defn.set("name", olb_path)

    # <DefaultValues>
    dv = ET.SubElement(root, "DefaultValues")
    ET.SubElement(dv, "Defn")

    # DefaultFont entries (24)
    if lib:
        for i, sd_idx in enumerate(lib.some_data):
            df = ET.SubElement(dv, "DefaultFont")
            df_defn = ET.SubElement(df, "Defn")
            attrs = font_for_index(lib, sd_idx)
            for k in ["charset", "escapement", "height"]:
                df_defn.set(k, attrs[k])
            df_defn.set("index", str(i))
            for k in ["italic", "name", "orientation", "weight", "width"]:
                df_defn.set(k, attrs[k])

        # DefaultPageRec
        ps = lib.page_settings
        if ps:
            dpr = ET.SubElement(dv, "DefaultPageRec")
            dpr_defn = ET.SubElement(dpr, "Defn")
            dpr_defn.set("ANSIGridRefs", str(ps.ansi_grid_refs))
            dpr_defn.set("BorderDisplayed", str(ps.border_displayed))
            dpr_defn.set("BorderPrinted", str(ps.border_printed))
            dpr_defn.set("GridRefDisplayed", str(ps.grid_ref_displayed))
            dpr_defn.set("GridRefPrinted", str(ps.grid_ref_printed))
            dpr_defn.set("HorizontalLabelCount", str(ps.horizontal_count))
            dpr_defn.set("HorizontalLabelIsAscending", str(ps.horizontal_ascending))
            dpr_defn.set("HorizontalLabelIsChar", str(ps.horizontal_char))
            dpr_defn.set("HorizontalLabelWidth", str(ps.horizontal_width))
            dpr_defn.set("IsMetric", str(ps.is_metric))
            dpr_defn.set("PinToPin", str(ps.pin_to_pin))
            dpr_defn.set("TitleBlockDisplayed", str(ps.titleblock_displayed))
            dpr_defn.set("TitleBlockPrinted", str(ps.titleblock_printed))
            dpr_defn.set("VerticalLabelCount", str(ps.vertical_count))
            dpr_defn.set("VerticalLabelIsAscending", str(ps.vertical_ascending))
            dpr_defn.set("VerticalLabelIsChar", str(ps.vertical_char))
            dpr_defn.set("VerticalLabelWidth", str(ps.vertical_width))

        # DefaultPlacedInstIsPrimitive / DefaultDrawnInstIsPrimitive
        dpip = ET.SubElement(dv, "DefaultPlacedInstIsPrimitive")
        ET.SubElement(dpip, "Defn").set("val", "0")
        ddip = ET.SubElement(dv, "DefaultDrawnInstIsPrimitive")
        ET.SubElement(ddip, "Defn").set("val", "0")

        # DefaultPartFieldMapping (8 entries)
        for i, field_name in enumerate(lib.part_field_mapping):
            dpfm = ET.SubElement(dv, "DefaultPartFieldMapping")
            dpfm_defn = ET.SubElement(dpfm, "Defn")
            dpfm_defn.set("index", str(i + 1))
            dpfm_defn.set("val", field_name)

    # Packages
    for pkg in olb.packages:
        pkg_elem = ET.SubElement(root, "Package")
        pkg_defn = ET.SubElement(pkg_elem, "Defn")
        pkg_defn.set("alphabeticNumbering", str(pkg.alphabetic_numbering))
        pkg_defn.set("isHomogeneous", str(pkg.is_homogeneous))
        pkg_defn.set("name", pkg.name)
        pkg_defn.set("pcbFootprint", pkg.pcb_footprint)
        pkg_defn.set("pcbLib", "")
        pkg_defn.set("refdesPrefix", pkg.ref_des)
        pkg_defn.set("timestamp", str(pkg.timestamp))
        pkg_defn.set("timezone", str(pkg.timezone))

        for pc in pkg.part_cells:
            for lp in pc.library_parts:
                lib_part_elem = ET.SubElement(pkg_elem, "LibPart")
                lp_defn = ET.SubElement(lib_part_elem, "Defn")
                # CellName is the package name (same as pc.ref)
                lp_defn.set("CellName", pkg.name)

                nv = ET.SubElement(lib_part_elem, "NormalView")
                nv_defn = ET.SubElement(nv, "Defn")
                nv_defn.set("suffix", ".Normal")

                # SymbolDisplayProps
                for sdp in lp.display_props:
                    sdp_elem = ET.SubElement(nv, "SymbolDisplayProp")
                    sdp_defn = ET.SubElement(sdp_elem, "Defn")
                    sdp_defn.set("locX", str(sdp.x))
                    sdp_defn.set("locY", str(sdp.y))
                    name = lib.str_lst[sdp.name_idx] if lib and sdp.name_idx < len(lib.str_lst) else ""
                    sdp_defn.set("name", name)
                    sdp_defn.set("rotation", str(sdp.rotation))
                    sdp_defn.set("textJustification", "0")

                    # PropFont
                    pf = ET.SubElement(sdp_elem, "PropFont")
                    pf_defn = ET.SubElement(pf, "Defn")
                    font_attrs = prop_font_attrs(lib, sdp.text_font_idx) if lib else {}
                    for k in ["charset", "escapement", "height", "italic", "name", "orientation", "weight", "width"]:
                        pf_defn.set(k, font_attrs.get(k, "0"))

                    # PropColor
                    pc_elem = ET.SubElement(sdp_elem, "PropColor")
                    ET.SubElement(pc_elem, "Defn").set("val", str(sdp.prop_color))

                    # PropDispType
                    pdt = ET.SubElement(sdp_elem, "PropDispType")
                    pdt_defn = ET.SubElement(pdt, "Defn")
                    pdt_defn.set("ValueIfValueExist", str(sdp.value_if_value_exist))
                    pdt_defn.set("val", str(sdp.disp_type))

                # SymbolColor
                sc = ET.SubElement(nv, "SymbolColor")
                ET.SubElement(sc, "Defn").set("val", "48")

                # SymbolBBox
                if lp.bbox:
                    sb = ET.SubElement(nv, "SymbolBBox")
                    sb_defn = ET.SubElement(sb, "Defn")
                    sb_defn.set("x1", str(lp.bbox.x1))
                    sb_defn.set("x2", str(lp.bbox.x2))
                    sb_defn.set("y1", str(lp.bbox.y1))
                    sb_defn.set("y2", str(lp.bbox.y2))

                # IsPinNumbersVisible, IsPinNamesRotated, IsPinNamesVisible
                gp = lp.general_properties
                ipnv = ET.SubElement(nv, "IsPinNumbersVisible")
                ET.SubElement(ipnv, "Defn").set("val", str(int(gp.pin_number_visible)) if gp else "1")
                ipnr = ET.SubElement(nv, "IsPinNamesRotated")
                ET.SubElement(ipnr, "Defn").set("val", str(int(gp.pin_name_rotate)) if gp else "0")
                ipnvis = ET.SubElement(nv, "IsPinNamesVisible")
                ET.SubElement(ipnvis, "Defn").set("val", str(int(gp.pin_name_visible)) if gp else "1")

                # ContentsLibName, ContentsViewName, ContentsViewType
                cln = ET.SubElement(nv, "ContentsLibName")
                ET.SubElement(cln, "Defn").set("name", "")
                cvn = ET.SubElement(nv, "ContentsViewName")
                ET.SubElement(cvn, "Defn").set("name", "")
                cvt = ET.SubElement(nv, "ContentsViewType")
                ET.SubElement(cvt, "Defn").set("type", "0")

                # PartValue
                pval = ET.SubElement(nv, "PartValue")
                ET.SubElement(pval, "Defn").set("name", gp.part_value if gp else "")

                # Reference
                ref = ET.SubElement(nv, "Reference")
                ET.SubElement(ref, "Defn").set("name", gp.ref_des if gp else pkg.ref_des)

                # Primitives
                for prim in lp.primitives:
                    _emit_primitive(nv, prim, lib)

            # PhysicalPart (one per LibPart)
            pp = ET.SubElement(lib_part_elem, "PhysicalPart")
            ET.SubElement(pp, "Defn")

    return _format_xml(root)


def _emit_primitive(parent, prim, lib):
    """Emit a primitive XML element."""
    if isinstance(prim, PrimLine):
        elem = ET.SubElement(parent, "Line")
        defn = ET.SubElement(elem, "Defn")
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))

    elif isinstance(prim, PrimRect):
        elem = ET.SubElement(parent, "Rect")
        defn = ET.SubElement(elem, "Defn")
        defn.set("fillStyle", str(prim.fill_style))
        defn.set("hatchStyle", str(prim.hatch_style))
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))

    elif isinstance(prim, PrimArc):
        elem = ET.SubElement(parent, "Arc")
        defn = ET.SubElement(elem, "Defn")
        defn.set("endX", str(prim.end_x))
        defn.set("endY", str(prim.end_y))
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        defn.set("startX", str(prim.start_x))
        defn.set("startY", str(prim.start_y))
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))

    elif isinstance(prim, PrimEllipse):
        elem = ET.SubElement(parent, "Ellipse")
        defn = ET.SubElement(elem, "Defn")
        defn.set("fillStyle", str(prim.fill_style))
        defn.set("hatchStyle", str(prim.hatch_style))
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))

    elif isinstance(prim, PrimBezier):
        elem = ET.SubElement(parent, "Bezier")
        defn = ET.SubElement(elem, "Defn")
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        for pt in prim.points:
            bp = ET.SubElement(elem, "BezierPoint")
            bp_defn = ET.SubElement(bp, "Defn")
            bp_defn.set("x", str(pt.x))
            bp_defn.set("y", str(pt.y))

    elif isinstance(prim, PrimPolyline):
        elem = ET.SubElement(parent, "Polyline")
        defn = ET.SubElement(elem, "Defn")
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        for pt in prim.points:
            pp = ET.SubElement(elem, "PolylinePoint")
            pp_defn = ET.SubElement(pp, "Defn")
            pp_defn.set("x", str(pt.x))
            pp_defn.set("y", str(pt.y))

    elif isinstance(prim, PrimPolygon):
        elem = ET.SubElement(parent, "Polygon")
        defn = ET.SubElement(elem, "Defn")
        defn.set("fillStyle", str(prim.fill_style))
        defn.set("hatchStyle", str(prim.hatch_style))
        defn.set("lineStyle", str(prim.line_style))
        defn.set("lineWidth", str(prim.line_width))
        for pt in prim.points:
            pp = ET.SubElement(elem, "PolygonPoint")
            pp_defn = ET.SubElement(pp, "Defn")
            pp_defn.set("x", str(pt.x))
            pp_defn.set("y", str(pt.y))

    elif isinstance(prim, PrimCommentText):
        elem = ET.SubElement(parent, "CommentText")
        defn = ET.SubElement(elem, "Defn")
        defn.set("locX", str(prim.loc_x))
        defn.set("locY", str(prim.loc_y))
        defn.set("name", prim.name)
        defn.set("textJustification", "0")
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))

        # TextFont
        tf = ET.SubElement(elem, "TextFont")
        tf_defn = ET.SubElement(tf, "Defn")
        font_attrs = comment_text_font_attrs(lib, prim.text_font_idx) if lib else {}
        for k in ["charset", "escapement", "height", "italic", "name", "orientation", "weight", "width"]:
            tf_defn.set(k, font_attrs.get(k, "0"))

    elif isinstance(prim, PrimBitmap):
        elem = ET.SubElement(parent, "Bitmap")
        defn = ET.SubElement(elem, "Defn")
        defn.set("locX", str(prim.loc_x))
        defn.set("locY", str(prim.loc_y))
        # Bitmap val is base64-encoded BMP file data (with BMP header prepended)
        bmp_data = _make_bmp(prim.raw_img_data)
        defn.set("val", base64.b64encode(bmp_data).decode('ascii'))
        defn.set("x1", str(prim.x1))
        defn.set("x2", str(prim.x2))
        defn.set("y1", str(prim.y1))
        defn.set("y2", str(prim.y2))


def _make_bmp(raw_img_data: bytes) -> bytes:
    """Prepend BMP file header to raw image data, converting 24bpp to 32bpp."""
    import struct

    dib_size = struct.unpack_from('<I', raw_img_data, 0)[0]
    width = struct.unpack_from('<i', raw_img_data, 4)[0]
    height = abs(struct.unpack_from('<i', raw_img_data, 8)[0])
    bpp = struct.unpack_from('<H', raw_img_data, 14)[0]

    if bpp == 24 and dib_size >= 40:
        # Convert 24bpp → 32bpp to match OrCAD XML export
        row_size_24 = ((width * 3 + 3) & ~3)
        pixel_data = raw_img_data[40:]
        new_pixels = bytearray()
        for row in range(height):
            offset = row * row_size_24
            for col in range(width):
                px = offset + col * 3
                b, g, r = pixel_data[px], pixel_data[px + 1], pixel_data[px + 2]
                new_pixels.extend([b, g, r, 0])
        # Build new DIB header (32bpp, with OrCAD's resolution values)
        new_dib = struct.pack('<IiiHHIIiiII',
                              40, width, height, 1, 32, 0, 0,
                              3780, 3780, 0, 0)
        body = new_dib + bytes(new_pixels)
    else:
        body = raw_img_data

    bmp_header = struct.pack('<2sIHHI', b'BM', 14 + len(body), 0, 0, 54)
    return bmp_header + body


def _format_xml(root) -> str:
    """Format XML with proper indentation matching OrCAD style."""
    rough = ET.tostring(root, encoding='unicode', xml_declaration=False)
    parsed = minidom.parseString(rough)
    pretty = parsed.toprettyxml(indent="  ", encoding=None)
    lines = pretty.split('\n')
    if lines[0].startswith('<?xml'):
        lines = lines[1:]
    cleaned = [line for line in lines if line.strip()]
    # Insert blank lines to match OrCAD format:
    # After <Lib...>, after top-level <Defn/>, after </DefaultValues>, after </Package>
    result = []
    for line in cleaned:
        result.append(line)
        stripped = line.strip()
        if stripped.startswith('<Lib ') and stripped.endswith('>'):
            result.append('')
        elif stripped.startswith('<Defn name=') and stripped.endswith('/>') and line.startswith('  <'):
            result.append('')
        elif stripped == '</DefaultValues>':
            result.append('')
        elif stripped == '</Package>':
            result.append('')
    body = '\n'.join(result)
    # Use &#xA; instead of &#10; for newlines in attributes (OrCAD convention)
    body = body.replace('&#10;', '&#xA;')
    return '<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n' + body + '\n'


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} input.OLB [output.xml]", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    ole = olefile.OleFileIO(input_path)
    olb = parse_olb(ole)
    ole.close()

    olb_name = os.path.basename(input_path).lower()
    olb_path = f"z:\\unittests\\olb\\{olb_name}"

    xml_str = olb_to_xml(olb, olb_path)

    if output_path:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(xml_str)
    else:
        sys.stdout.write(xml_str)


if __name__ == '__main__':
    main()
