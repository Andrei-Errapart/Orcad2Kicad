# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
def test_esc_kicad_plain(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("hello") == "hello"


def test_esc_kicad_quotes(dsn2kicad):
    assert dsn2kicad._esc_kicad_str('a"b') == 'a\\"b'


def test_esc_kicad_backslash(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("a\\b") == "a\\\\b"


def test_esc_kicad_newline(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("a\nb") == "a\\nb"


def test_esc_kicad_crlf(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("a\r\nb") == "a\\nb"


def test_esc_kicad_cr(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("a\rb") == "a\\nb"


def test_esc_kicad_tab(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("a\tb") == "a b"


def test_esc_kicad_empty(dsn2kicad):
    assert dsn2kicad._esc_kicad_str("") == ""


def test_overline_none(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("ABC") == "ABC"


def test_overline_single(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("\\A") == "~{A}"


def test_overline_consecutive(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("\\O\\E") == "~{OE}"


def test_overline_mixed(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("1\\O\\E\\") == "1~{OE}"


def test_overline_prefix_plain(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("A\\B") == "A~{B}"


def test_overline_multiple_groups(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("\\AX\\B") == "~{A}X~{B}"


def test_overline_empty(dsn2kicad):
    assert dsn2kicad._orcad_overline_to_kicad("") == ""


def test_pin_label_overline(dsn2kicad):
    assert dsn2kicad._pin_label_for_kicad("\\O\\E") == "~{OE}"


def test_pin_label_plain(dsn2kicad):
    assert dsn2kicad._pin_label_for_kicad("CLK") == "CLK"


def test_pin_label_numeric(dsn2kicad):
    assert dsn2kicad._pin_label_for_kicad(42) == "42"
