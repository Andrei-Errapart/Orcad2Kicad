# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""End-to-end tests: drive the converter from a synthetic ZIP fixture.

These exercise the real convert_dsn_bytes -> open_dsn_container -> convert_dsn
path with a ZIP built by dsn_fixtures, with zero OLE/disk dependency. Assertions
are on structure (the reference, a wire), never on UUIDs (the ZIP's bytes seed
different UUIDs than an OLE equivalent would).
"""
PAGE = "Views/SCHEMATIC1/Pages/Page1"


def _schematics(out):
    """Concatenated text of every .kicad_sch file in the converter output."""
    return "\n".join(t for n, t in out.items() if n.endswith(".kicad_sch"))


def test_convert_dsn_bytes_accepts_zip(dsn2kicad, dsn_fixtures):
    dsn = dsn_fixtures.make_zip({PAGE: dsn_fixtures.make_page("01_TEST")})
    out = dsn2kicad.convert_dsn_bytes(dsn, project_name="t")
    assert isinstance(out, dict)
    assert any(name.endswith(".kicad_sch") for name in out)


def test_convert_zip_emits_component_and_wire(dsn2kicad, dsn_fixtures):
    page = dsn_fixtures.make_page(
        "01_TEST",
        nets={5: "GND"},
        wires=[(5, 0, 0, 100, 0)],
        components=[("RES", "R1", 0)],
    )
    cache = dsn_fixtures.make_cache({
        "RES": [("1", 0, 0, 0, 0, 0x00), ("2", 100, 0, 100, 0, 0x00)],
    })
    dsn = dsn_fixtures.make_zip({PAGE: page, "Cache": cache})

    out = dsn2kicad.convert_dsn_bytes(dsn, project_name="t")
    sch = _schematics(out)
    assert '"R1"' in sch          # the placed component's reference
    assert "(wire" in sch         # the GND wire segment


def test_convert_zip_without_cache_still_converts(dsn2kicad, dsn_fixtures):
    # Cache is optional: a page-only fixture must still produce a schematic.
    page = dsn_fixtures.make_page(
        "01_TEST", components=[("RES", "R1", 0)])
    dsn = dsn_fixtures.make_zip({PAGE: page})
    out = dsn2kicad.convert_dsn_bytes(dsn, project_name="t")
    assert '"R1"' in _schematics(out)
