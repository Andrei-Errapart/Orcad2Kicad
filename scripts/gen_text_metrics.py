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
  with freetype from the **Liberation** family (Liberation Sans / Sans Narrow /
  Mono), which is metric-compatible with those faces and free (OFL-1.1; the
  Narrow variant is GPL-2.0 + font exception). Liberation's advance widths are
  bit-identical to Arial's, so the emitted widths match exactly while sourcing
  the metrics from a free font avoids any proprietary-Arial licensing question.
  The full family — including the Narrow face — ships with LibreOffice.
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

# The native Haskell converter embeds the same tables inline (it stays a single
# self-contained runghc script). We splice a generated block into it between
# these markers, so the two converters always measure text with identical data.
HK_PATH = SCRIPT_DIR / 'dsn2kicad.hs'
HK_BEGIN = '-- BEGIN GENERATED FONT METRICS'
HK_END = '-- END GENERATED FONT METRICS'

NEWSTROKE_URL = (
    'https://gitlab.com/kicad/code/kicad/-/raw/master/common/newstroke_font.cpp'
)

# Metric source: the Liberation family only. Liberation Sans ≡ Arial,
# Liberation Sans Narrow ≡ Arial Narrow, Liberation Mono ≡ Courier New, with
# bit-identical advance widths — so the committed metrics carry no proprietary
# (Arial) font dependency. The first existing file per face wins. The full family
# (including the Narrow face, dropped from Liberation 2.x) ships with LibreOffice.
_LIBERATION_DIRS = [
    '/Applications/LibreOffice.app/Contents/Resources/fonts/truetype',  # macOS
    '/usr/share/fonts/truetype/liberation',                             # Debian/Ubuntu
    '/usr/share/fonts/truetype/liberation2',
    '/usr/share/fonts/liberation',                                      # Fedora/RHEL
    '/usr/share/fonts/liberation-sans-narrow',
    '/opt/homebrew/share/fonts',                                        # Homebrew
    '/Library/Fonts',
    str(Path.home() / 'Library' / 'Fonts'),
]

_FACE_FILES = {
    ('arial', False, False): 'LiberationSans-Regular.ttf',
    ('arial', True, False): 'LiberationSans-Bold.ttf',
    ('arial', False, True): 'LiberationSans-Italic.ttf',
    ('arial', True, True): 'LiberationSans-BoldItalic.ttf',
    ('arial narrow', False, False): 'LiberationSansNarrow-Regular.ttf',
    ('arial narrow', True, False): 'LiberationSansNarrow-Bold.ttf',
    ('arial narrow', False, True): 'LiberationSansNarrow-Italic.ttf',
    ('arial narrow', True, True): 'LiberationSansNarrow-BoldItalic.ttf',
    ('courier new', False, False): 'LiberationMono-Regular.ttf',
    ('courier new', True, False): 'LiberationMono-Bold.ttf',
    ('courier new', False, True): 'LiberationMono-Italic.ttf',
    ('courier new', True, True): 'LiberationMono-BoldItalic.ttf',
}

FONT_PATH_CANDIDATES = {
    key: [str(Path(d) / fn) for d in _LIBERATION_DIRS]
    for key, fn in _FACE_FILES.items()
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


def _hs_char_literal(ch):
    """Haskell Char literal for a glyph key, ASCII-safe.

    Non-ASCII glyphs (°, µ, Ω, …) are emitted as numeric ``'\\xNNN'`` escapes so
    the generated source needs no particular file encoding.
    """
    o = ord(ch)
    if ch == '\\':
        return "'\\\\'"
    if ch == "'":
        return "'\\''"
    if 0x20 <= o <= 0x7e:
        return "'%s'" % ch
    return "'\\x%x'" % o


def _hs_string_literal(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def _format_haskell_entry(name, key, upem, default_adv, glyphs):
    """One ``fontMetricsEntryN`` binding: a ((face, bold, italic), FaceMetrics)."""
    face, bold, italic = key
    hs_key = "(%s, %s, %s)" % (
        _hs_string_literal(face),
        'True' if bold else 'False',
        'True' if italic else 'False',
    )
    glyph_strs = [
        "(%s, (%d, %d, %d))" % (_hs_char_literal(ch), *glyphs[ch])
        for ch in sorted(glyphs, key=ord)
    ]
    glyph_block = "  [ " + "\n  , ".join(glyph_strs) + "\n  ]"
    return (
        "%s :: ((String, Bool, Bool), FaceMetrics)\n"
        "%s = (%s, FaceMetrics %d %d (Map.fromList\n%s))\n"
        % (name, name, hs_key, upem, default_adv, glyph_block)
    )


def _format_haskell_block(tables, provenance, ftver):
    """Render the full Haskell font-metrics block (spliced between markers)."""
    names = ['fontMetricsEntry%d' % i for i in range(len(tables))]
    entries = [
        _format_haskell_entry(name, key, upem, default_adv, glyphs)
        for name, (key, upem, default_adv, glyphs, _source)
        in zip(names, tables)
    ]
    head = [
        HK_BEGIN + ' — AUTO-GENERATED, do not edit.',
        '-- Regenerate (with text_metrics_data.py) via: python3 gen_text_metrics.py',
        '-- Per-glyph (advance, top, bot) in font units, keyed by',
        '-- (face_lc, bold, italic). The Python port lives in text_metrics_data.py;',
        '-- both converters therefore measure text with byte-identical data.',
        '-- freetype-py %s; faces: Arial / Arial Narrow / Courier New (via the'
        % ftver,
        '-- metric-compatible Liberation fonts) plus KiCad Newstroke.',
        '',
        'data FaceMetrics = FaceMetrics',
        '  { fmUnitsPerEm :: !Int',
        '  , fmDefaultAdvance :: !Int',
        '  , fmGlyphs :: !(Map.Map Char (Int, Int, Int))',
        '  }',
        '',
    ]
    tail = [
        'fontMetrics :: Map.Map (String, Bool, Bool) FaceMetrics',
        'fontMetrics = Map.fromList',
        '  [ ' + '\n  , '.join(names),
        '  ]',
        HK_END,
    ]
    return '\n'.join(head) + '\n'.join(entries) + '\n' + '\n'.join(tail) + '\n'


def _splice_haskell(block):
    """Insert/replace the font-metrics block in dsn2kicad.hs between markers."""
    text = HK_PATH.read_text(encoding='utf-8')
    if HK_BEGIN in text and HK_END in text:
        start = text.index(HK_BEGIN)
        end = text.index(HK_END) + len(HK_END) + 1  # include trailing newline
        new = text[:start] + block + text[end:]
    else:
        new = text.rstrip('\n') + '\n\n\n' + block
    HK_PATH.write_text(new, encoding='utf-8')


def main():
    newstroke_arg = None
    argv = sys.argv[1:]
    if '--newstroke' in argv:
        i = argv.index('--newstroke')
        newstroke_arg = argv[i + 1]

    # Raw tables: [(key, units_per_em, default_advance, glyphs, source)]. Both
    # the Python (_format_entry) and Haskell (_format_haskell_*) emitters render
    # from this single list, so the two data files can never drift.
    tables = []
    provenance = []

    for key, candidates in FONT_PATH_CANDIDATES.items():
        path = next((p for p in candidates if os.path.exists(p)), None)
        if path is None:
            print(f"  WARNING: no font found for {key}; skipping", file=sys.stderr)
            continue
        upem, glyphs = measure_outline_face(path)
        tables.append((key, upem, _default_advance(glyphs), glyphs,
                       os.path.basename(path)))
        provenance.append(f"#   {key}: {path}")

    ns_path = _resolve_newstroke(newstroke_arg)
    upem, glyphs = parse_newstroke(ns_path)
    for italic in (False, True):
        for bold in (False, True):
            tables.append((('newstroke', bold, italic), upem,
                           _default_advance(glyphs), glyphs, 'newstroke_font.cpp'))
    provenance.append(f"#   newstroke: {NEWSTROKE_URL}")

    entries = [_format_entry(*t) for t in tables]
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

    ftver = ".".join(str(x) for x in freetype.version())
    _splice_haskell(_format_haskell_block(tables, provenance, ftver))
    print(f"spliced {len(tables)} face variants into {HK_PATH}")


if __name__ == '__main__':
    main()
