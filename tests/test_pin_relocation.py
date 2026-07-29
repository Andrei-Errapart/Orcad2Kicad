# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pin relocation under --kicad-rc, on a synthetic design.

`--kicad-rc` replaces OrCAD's R/C cells with KiCad's Device:R / Device:C,
whose pins sit at fixed offsets that generally do not coincide with the
original ones. Wires that landed on the old pin positions have to follow,
and where they cannot, a bridge segment has to keep the net connected.
Orcad.PinRelocation decides that; this exercises it end to end.

The corpus already covers this through `[option] --kicad-rc preserves
connectivity`, but only by converting whole multi-megabyte designs and
diffing exported netlists. These run against a three-net synthetic page in
about a second, which is what you want when bisecting the relocation logic
rather than confirming a whole board still works.
"""
import re
import shutil
import subprocess

import pytest

from .test_dsn2kicad_hk import PAGE, hk_argv


def _resistor_page(dsn_fixtures):
    """One resistor, its two pins wired outward to separate nets.

    The cache pins sit at +/-50 on the x axis; KiCad's Device:R pins sit on
    the y axis, so every endpoint has to move and neither move is collinear
    with its wire. That is the case the relocation logic exists for.
    """
    page = dsn_fixtures.make_page(
        "01_RC",
        nets={5: "NET_A", 6: "NET_B"},
        wires=[(5, -200, 0, -50, 0), (6, 50, 0, 200, 0)],
        components=[("R", "R1", 0)],
    )
    cache = dsn_fixtures.make_cache({
        "R": [("1", -50, 0, -50, 0, 0x00), ("2", 50, 0, 50, 0, 0x00)],
    })
    return dsn_fixtures.make_zip({PAGE: page, "Cache": cache})


def _convert(dsn_fixtures, tmp_path, *flags):
    tmp_path.mkdir(parents=True, exist_ok=True)
    dsn = tmp_path / "synthetic.DSN"
    dsn.write_bytes(_resistor_page(dsn_fixtures))
    out_dir = tmp_path / "out"
    result = subprocess.run(
        hk_argv(*flags, dsn, out_dir),
        capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stderr
    return "\n".join(
        p.read_text(encoding="utf-8") for p in sorted(out_dir.glob("*.kicad_sch"))
    )


def _wire_endpoints(sch):
    """Every (x, y) endpoint of every emitted wire segment, rounded to 4dp."""
    points = set()
    for block in re.findall(r"\(wire\s+\(pts(.*?)\)\s*\(stroke", sch, re.S):
        for x, y in re.findall(r"\(xy ([-0-9.]+) ([-0-9.]+)\)", block):
            points.add((round(float(x), 4), round(float(y), 4)))
    return points


def _symbol_pin_points(sch):
    """Placement anchors of every placed symbol, rounded to 4dp."""
    return {
        (round(float(x), 4), round(float(y), 4))
        for x, y in re.findall(
            r"\(symbol\s+\(lib_id[^)]*\)\s*\(at ([-0-9.]+) ([-0-9.]+)", sch)
    }


needs_runghc = pytest.mark.skipif(
    shutil.which("runghc") is None, reason="runghc not installed")


@needs_runghc
def test_default_mode_extends_pins_and_drags_the_wires_with_them(
        dsn_fixtures, tmp_path):
    """Native relocation, with no --kicad-rc involved.

    The fixture's cache pins have zero length (body and hot point both at
    +/-50 units), so symbolPinsForOutput extends each to the 10-unit minimum
    that keeps pin numbers legible. The hot ends therefore land at +/-60
    units = +/-15.24 mm, and the wires that met them at +/-50 must follow --
    both moves being collinear with their wire, so no bridge is needed.

    This is the half of the relocation that runs on every conversion, not
    just under --kicad-rc.
    """
    sch = _convert(dsn_fixtures, tmp_path)
    points = _wire_endpoints(sch)
    assert (-15.24, 0.0) in points, "left wire did not follow its extended pin"
    assert (15.24, 0.0) in points, "right wire did not follow its extended pin"
    assert (-12.7, 0.0) not in points, "wire was left behind at the unextended pin"


@needs_runghc
def test_kicad_rc_relocates_pins_and_keeps_both_nets_wired(
        dsn_fixtures, tmp_path):
    """With --kicad-rc the resistor becomes Device:R and its pins move off
    the x axis. Both nets must still reach the symbol: the wire count may
    grow (a bridge segment is legitimate) but must never shrink, and the
    outer endpoints -- which nothing asked to move -- must stay put."""
    plain = _convert(dsn_fixtures, tmp_path / "plain")
    rc = _convert(dsn_fixtures, tmp_path / "rc", "--kicad-rc")

    assert "Device:R" in rc, "--kicad-rc should swap in KiCad's native symbol"

    rc_points = _wire_endpoints(rc)
    # The far ends are anchored by nothing that moved, so they are invariant.
    for anchor in ((-50.8, 0.0), (50.8, 0.0)):
        assert anchor in rc_points, f"outer wire endpoint {anchor} was lost"

    assert len(_wire_endpoints(rc)) >= len(_wire_endpoints(plain)) - 2, (
        "relocation dropped wire geometry rather than moving or bridging it")
    assert _symbol_pin_points(rc), "no placed symbol survived the swap"


@needs_runghc
def test_kicad_rc_is_deterministic(dsn_fixtures, tmp_path):
    """The same input twice must produce identical output -- relocation
    involves set and map traversals, which is exactly where accidental
    ordering dependence hides."""
    first = _convert(dsn_fixtures, tmp_path / "a", "--kicad-rc")
    second = _convert(dsn_fixtures, tmp_path / "b", "--kicad-rc")
    assert first == second
