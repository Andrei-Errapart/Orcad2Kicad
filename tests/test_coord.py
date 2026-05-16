def test_unit_to_mm_constant(dsn2kicad):
    assert dsn2kicad.UNIT_TO_MM == 0.254


def test_dsn_to_mm_zero(dsn2kicad):
    assert dsn2kicad.dsn_to_mm(0) == 0.0


def test_dsn_to_mm_positive(dsn2kicad):
    assert dsn2kicad.dsn_to_mm(100) == 25.4


def test_dsn_to_mm_negative(dsn2kicad):
    assert dsn2kicad.dsn_to_mm(-10) == -2.54


def test_dsn_to_mm_one(dsn2kicad):
    assert dsn2kicad.dsn_to_mm(1) == 0.25


def test_snap_to_grid_exact(dsn2kicad):
    assert dsn2kicad.snap_to_grid(2.54) == 2.54


def test_snap_to_grid_rounds_nearest(dsn2kicad):
    result = dsn2kicad.snap_to_grid(2.6)
    assert result == 2.54


def test_snap_to_grid_rounds_up(dsn2kicad):
    result = dsn2kicad.snap_to_grid(3.9)
    assert result == 2.54 * 2  # 5.08


def test_snap_to_grid_zero(dsn2kicad):
    assert dsn2kicad.snap_to_grid(0.0) == 0.0


def test_snap_to_grid_custom(dsn2kicad):
    assert dsn2kicad.snap_to_grid(1.0, 0.5) == 1.0


def test_snap_to_grid_negative(dsn2kicad):
    assert dsn2kicad.snap_to_grid(-2.6) == -2.54
