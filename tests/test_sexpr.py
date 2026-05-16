import json


def test_sch_header_default(dsn2kicad):
    h = dsn2kicad.sch_header()
    assert h.startswith("(kicad_sch")
    assert '(paper "A3")' in h


def test_sch_header_paper(dsn2kicad):
    h = dsn2kicad.sch_header(paper="A4")
    assert '(paper "A4")' in h


def test_sch_header_title(dsn2kicad):
    h = dsn2kicad.sch_header(title="Test Board")
    assert '(title "Test Board")' in h


def test_sch_wire_format(dsn2kicad):
    w = dsn2kicad.sch_wire(0, 0, 10, 20)
    assert "(wire" in w
    assert "(pts" in w
    assert "(xy 0.00 0.00)" in w
    assert "(xy 10.00 20.00)" in w


def test_sch_wire_has_uuid(dsn2kicad):
    w = dsn2kicad.sch_wire(0, 0, 10, 0)
    assert "(uuid" in w


def test_sch_label_basic(dsn2kicad):
    lbl = dsn2kicad.sch_label("NET1", 5.0, 10.0)
    assert "(label" in lbl
    assert '"NET1"' in lbl


def test_sch_label_escaping(dsn2kicad):
    lbl = dsn2kicad.sch_label('A"B', 0, 0)
    assert 'A\\"B' in lbl


def test_sch_global_label_shape(dsn2kicad):
    gl = dsn2kicad.sch_global_label("NET", 0, 0, shape="input")
    assert "(shape input)" in gl


def test_sch_junction(dsn2kicad):
    j = dsn2kicad.sch_junction(5.0, 10.0)
    assert "(junction" in j
    assert "(at 5.00 10.00)" in j


def test_sch_polyline(dsn2kicad):
    pl = dsn2kicad.sch_polyline([(0, 0), (5, 5)])
    assert "(polyline" in pl
    assert "(xy 0.00 0.00)" in pl
    assert "(xy 5.00 5.00)" in pl


def test_sch_rectangle(dsn2kicad):
    r = dsn2kicad.sch_rectangle(0, 0, 10, 10)
    assert "(rectangle" in r
    assert "(start 0.00 0.00)" in r
    assert "(end 10.00 10.00)" in r


def test_sch_text_plain(dsn2kicad):
    t = dsn2kicad.sch_text("Hello", 0, 0)
    assert "(text" in t
    assert '"Hello"' in t


def test_sch_text_bold_italic(dsn2kicad):
    t = dsn2kicad.sch_text("X", 0, 0, bold=True, italic=True)
    assert "(bold yes)" in t
    assert "(italic yes)" in t


def test_sch_power_symbol_gnd(dsn2kicad):
    ps = dsn2kicad.sch_power_symbol("GND", 0, 0, True)
    assert "power:GND" in ps
    assert '(pin "1"' in ps


def test_sch_power_symbol_vcc(dsn2kicad):
    ps = dsn2kicad.sch_power_symbol("VCC", 10, 20, False)
    assert "power:VCC" in ps


def test_sch_component_basic(dsn2kicad):
    c = dsn2kicad.sch_component("R1", "R", 10.0, 20.0)
    assert "(symbol" in c
    assert '"R1"' in c
    assert '(lib_id "R")' in c
    assert "(at 10.00 20.00" in c


def test_sch_component_with_angle(dsn2kicad):
    c = dsn2kicad.sch_component("C1", "C", 0, 0, angle=90)
    assert "(at 0.00 0.00 90)" in c


def test_sch_component_with_value(dsn2kicad):
    c = dsn2kicad.sch_component("R1", "R", 0, 0, value="10k")
    assert '"10k"' in c


def test_sch_footer(dsn2kicad):
    f = dsn2kicad.sch_footer()
    assert "(embedded_fonts no)" in f
    assert f.endswith(")\n")


def test_lib_symbol_R(dsn2kicad):
    r = dsn2kicad.lib_symbol_R()
    assert '"R"' in r
    assert 'passive' in r
    assert '(number "1"' in r
    assert '(number "2"' in r


def test_lib_symbol_C(dsn2kicad):
    c = dsn2kicad.lib_symbol_C()
    assert '"C"' in c
    assert '(number "1"' in c
    assert '(number "2"' in c


def test_lib_symbol_power_gnd(dsn2kicad):
    g = dsn2kicad.lib_symbol_power_gnd()
    assert "power:GND" in g
    assert "(power)" in g


def test_lib_symbol_power_rail(dsn2kicad):
    v = dsn2kicad.lib_symbol_power_rail("VCC_3V3")
    assert "power:VCC_3V3" in v
    assert "(power)" in v


def test_generate_project_valid_json(dsn2kicad):
    proj = dsn2kicad.generate_project("test")
    data = json.loads(proj)
    assert data["meta"]["filename"] == "test.kicad_pro"
    assert "schematic" in data


def test_generate_root_sch(dsn2kicad):
    content = dsn2kicad.generate_root_sch(
        ["page1.kicad_sch", "page2.kicad_sch"],
        ["Page 1", "Page 2"],
        "test_project",
    )
    assert "(kicad_sch" in content
    assert "(sheet" in content
    assert '"page1.kicad_sch"' in content
    assert '"Page 1"' in content
