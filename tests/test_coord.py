# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
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
