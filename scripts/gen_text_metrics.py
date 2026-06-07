#!/usr/bin/env python3
# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Dev-only generator for ``text_metrics_data.py``.

The runtime converter must measure text widths *without* any native font
library or font files (so it can run under Pyodide in a browser). This script
precomputes per-glyph advance/extent tables once, offline, and emits them as a
pure-Python data module that the runtime imports.

It is NOT imported at runtime and is NOT needed to run the converter. It needs
``freetype-py`` plus the source fonts (see ``[dev]`` extra in pyproject.toml).

Sources
-------
* Outline faces (Arial / Arial Narrow / Courier New, 4 styles each): measured
  with freetype from the same TTF candidates ``dsn2kicad`` historically used
  (macOS system fonts, with Liberation as the metric-compatible Linux stand-in).
  Reusing the same freetype ``FT_LOAD_NO_SCALE`` advances means the emitted
  table reproduces the old ``measure_text_width`` output exactly — no placement
  regression.
* KiCad built-in stroke font (Newstroke): advances parsed from KiCad's
  ``newstroke_font.cpp`` (each glyph encodes left/right bearing; advance =
  right - left; design grid is 21 units per em, matching KiCad's
  ``STROKE_FONT_SCALE = 1/21``).

Usage
-----
    python3 gen_text_metrics.py [--newstroke PATH_OR_URL]

Writes ``text_metrics_data.py`` next to this script.
"""

import os
import re
import sys
import urllib.request
from pathlib import Path

import freetype

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_PATH = SCRIPT_DIR / 'text_metrics_data.py'

NEWSTROKE_URL = (
    'https://gitlab.com/kicad/code/kicad/-/raw/master/common/newstroke_font.cpp'
)

# Same (face_lc, bold, italic) -> candidate TTF paths the converter used before
# the freetype dependency was removed. The first existing file wins, so the
# committed table reflects whatever metric-compatible font is installed.
FONT_PATH_CANDIDATES = {
    ('arial', False, False): [
        '/System/Library/Fonts/Supplemental/Arial.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ],
    ('arial', True, False): [
        '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    ],
    ('arial', False, True): [
        '/System/Library/Fonts/Supplemental/Arial Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-Italic.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf',
    ],
    ('arial', True, True): [
        '/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Arial_Bold_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSans-BoldItalic.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf',
    ],
    ('arial narrow', False, False): [
        '/System/Library/Fonts/Supplemental/Arial Narrow.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Regular.ttf',
    ],
    ('arial narrow', True, False): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Bold.ttf',
    ],
    ('arial narrow', False, True): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Italic.ttf',
    ],
    ('arial narrow', True, True): [
        '/System/Library/Fonts/Supplemental/Arial Narrow Bold Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationSansNarrow-BoldItalic.ttf',
    ],
    ('courier new', False, False): [
        '/System/Library/Fonts/Supplemental/Courier New.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
    ],
    ('courier new', True, False): [
        '/System/Library/Fonts/Supplemental/Courier New Bold.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf',
    ],
    ('courier new', False, True): [
        '/System/Library/Fonts/Supplemental/Courier New Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationMono-Italic.ttf',
    ],
    ('courier new', True, True): [
        '/System/Library/Fonts/Supplemental/Courier New Bold Italic.ttf',
        '/usr/share/fonts/truetype/msttcorefonts/Courier_New_Bold_Italic.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationMono-BoldItalic.ttf',
    ],
}

# Printable ASCII plus a few symbols that show up in component values/labels.
CHARSET = [chr(c) for c in range(0x20, 0x7F)] + [
    '°',  # °  degree
    '±',  # ±  plus-minus
    'µ',  # µ  micro sign
    '×',  # ×  multiplication
    '÷',  # ÷  division
    '²',  # ²
    '³',  # ³
    '½',  # ½
    '¼',  # ¼
    'Ω',  # Ω  Greek capital omega
    'μ',  # μ  Greek small mu
    'Ω',  # Ω  ohm sign
    '–',  # –  en dash
    '—',  # —  em dash
]


def measure_outline_face(path):
    """Return (units_per_em, {char: (advance, top, bot)}) from a TTF.

    Mirrors the old ``measure_text_width``/``measure_text_height`` exactly:
    ``FT_LOAD_NO_SCALE`` advances/bearings in font units, top = horiBearingY,
    bot = horiBearingY - height.
    """
    face = freetype.Face(path)
    upem = face.units_per_EM
    face.set_char_size(int(upem))
    glyphs = {}
    for ch in CHARSET:
        try:
            face.load_char(
                ch, freetype.FT_LOAD_NO_BITMAP | freetype.FT_LOAD_NO_SCALE)
        except Exception:
            continue
        gi = face.get_char_index(ch)
        if gi == 0 and ch != ' ':
            # No glyph for this codepoint in this face; skip (runtime falls
            # back to default_advance).
            continue
        m = face.glyph.metrics
        glyphs[ch] = (int(m.horiAdvance),
                      int(m.horiBearingY),
                      int(m.horiBearingY - m.height))
    return upem, glyphs


def _resolve_newstroke(arg):
    """Return a path to newstroke_font.cpp, downloading if given a URL/None."""
    if arg and os.path.exists(arg):
        return arg
    url = arg or NEWSTROKE_URL
    if not (url.startswith('http://') or url.startswith('https://')):
        raise SystemExit(f"newstroke source not found: {url}")
    cache = Path('/tmp/newstroke_cache/newstroke_font.cpp')
    if cache.exists():
        return str(cache)
    cache.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading newstroke font from {url} ...")
    urllib.request.urlretrieve(url, cache)
    return str(cache)


def parse_newstroke(path):
    """Return (21, {char: (advance, top, bot)}) from KiCad's newstroke_font.cpp.

    Each glyph string starts with a left/right bearing pair (advance =
    right-left). Remaining character pairs are stroke coordinates; ' R' marks a
    pen-up. Coordinates decode as ``ord(c) - ord('R')``. The KiCad design grid
    is 21 units/em (STROKE_FONT_SCALE = 1/21). top/bot are stored as -min_y /
    -max_y so the runtime's ``max(top) - min(bot)`` reproduces the inked extent.
    """
    txt = Path(path).read_text(encoding='utf-8', errors='replace')
    m = re.search(r'newstroke_font\[\]\s*=\s*\{', txt)
    if not m:
        raise SystemExit("could not find newstroke_font[] array")
    body = txt[m.end():]
    body = body[:body.index('};')]
    lits = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
    glyphs = {}
    for code in range(0x20, 0x7F):
        idx = code - 0x20
        if idx >= len(lits):
            break
        g = lits[idx].encode('latin-1').decode('unicode_escape')
        if len(g) < 2:
            continue
        left = ord(g[0]) - ord('R')
        right = ord(g[1]) - ord('R')
        advance = right - left
        ys = []
        i = 2
        while i + 1 < len(g):
            a, b = g[i], g[i + 1]
            if a == ' ' and b == 'R':   # pen-up marker, not a coordinate
                i += 2
                continue
            ys.append(ord(b) - ord('R'))
            i += 2
        if ys:
            top, bot = -min(ys), -max(ys)
        else:
            top = bot = 0
        glyphs[chr(code)] = (advance, top, bot)
    return 21, glyphs


def _default_advance(glyphs):
    advs = [v[0] for v in glyphs.values() if v[0] > 0]
    return int(round(sum(advs) / len(advs))) if advs else 0


def _format_entry(key, upem, default_adv, glyphs, source):
    face, bold, italic = key
    lines = [f"    ({face!r}, {bold}, {italic}): {{"]
    lines.append(f"        'units_per_em': {upem},")
    lines.append(f"        'default_advance': {default_adv},")
    lines.append(f"        'source': {source!r},")
    lines.append("        'glyphs': {")
    for ch in sorted(glyphs, key=ord):
        adv, top, bot = glyphs[ch]
        lines.append(f"            {ch!r}: ({adv}, {top}, {bot}),")
    lines.append("        },")
    lines.append("    },")
    return "\n".join(lines)


def main():
    newstroke_arg = None
    argv = sys.argv[1:]
    if '--newstroke' in argv:
        i = argv.index('--newstroke')
        newstroke_arg = argv[i + 1]

    entries = []
    provenance = []

    for key, candidates in FONT_PATH_CANDIDATES.items():
        path = next((p for p in candidates if os.path.exists(p)), None)
        if path is None:
            print(f"  WARNING: no font found for {key}; skipping", file=sys.stderr)
            continue
        upem, glyphs = measure_outline_face(path)
        entries.append(_format_entry(key, upem, _default_advance(glyphs),
                                     glyphs, os.path.basename(path)))
        provenance.append(f"#   {key}: {path}")

    ns_path = _resolve_newstroke(newstroke_arg)
    upem, glyphs = parse_newstroke(ns_path)
    for italic in (False, True):
        for bold in (False, True):
            entries.append(_format_entry(
                ('newstroke', bold, italic), upem, _default_advance(glyphs),
                glyphs, 'newstroke_font.cpp'))
    provenance.append(f"#   newstroke: {NEWSTROKE_URL}")

    header = [
        '"""Embedded font advance/extent tables. AUTO-GENERATED — do not edit.',
        '',
        'Regenerate with: python3 gen_text_metrics.py',
        '',
        'Each face maps (face_lc, bold, italic) -> {units_per_em, default_advance,',
        'glyphs: {char: (advance, top, bot)}} in font units. See text_metrics.py.',
        '',
        f'freetype-py {".".join(str(x) for x in freetype.version())}; sources:',
        *provenance,
        '"""',
        '',
        'FONT_METRICS = {',
    ]
    spdx = ("# Copyright (C) 2026 Andrei Errapart\n"
            "# SPDX-License-Identifier: GPL-2.0-or-later\n")
    out = spdx + "\n".join(header) + "\n" + "\n".join(entries) + "\n}\n"
    OUT_PATH.write_text(out, encoding='utf-8')
    print(f"wrote {OUT_PATH} ({len(entries)} face variants, "
          f"{len(out)} bytes)")


if __name__ == '__main__':
    main()
