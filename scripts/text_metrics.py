# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pure-Python text measurement — no native font library, no font files.

Drop-in replacement for the freetype-backed ``measure_text_width`` /
``measure_text_height`` that ``dsn2kicad`` used to carry. Widths and extents come
from precomputed per-glyph tables in ``text_metrics_data.py`` (advance / top /
bot in font units), so the converter runs anywhere CPython runs — including
Pyodide in a browser, where ctypes and system fonts are unavailable.

The tables are generated (see ``gen_text_metrics.py``) from the metric-compatible
**Liberation** fonts (Liberation Sans / Sans Narrow / Mono ≡ Arial / Arial Narrow
/ Courier New), whose advance widths are bit-identical to Arial's. So the metrics
carry no proprietary-font dependency while horizontal placement stays exact; the
handful of glyphs whose vertical extent differs shift placement by <0.1 mm, far
inside the test tolerance. Faces covered: Arial, Arial Narrow, Courier New
(regular/bold/italic/bold-italic) and KiCad's built-in Newstroke stroke font.
"""

try:
    from text_metrics_data import FONT_METRICS
except ImportError:  # pragma: no cover - allow `python -m`/package import too
    from .text_metrics_data import FONT_METRICS


# Caller face names normalize to these table keys.
_FACE_ALIASES = {
    '': 'arial',
    'kicad font': 'newstroke',
    'kicad': 'newstroke',
    'stroke': 'newstroke',
}


def _resolve(face_name, bold, italic):
    """Return the metrics entry for (face, bold, italic), Arial as fallback."""
    name = (face_name or 'arial').lower()
    name = _FACE_ALIASES.get(name, name)
    b, i = bool(bold), bool(italic)
    for key in ((name, b, i), ('arial', b, i), ('arial', False, False)):
        entry = FONT_METRICS.get(key)
        if entry is not None:
            return entry
    return None


def measure_text_width(s, size_mm, face_name='Arial', bold=False, italic=False):
    """Return the rendered width of `s` in mm at the given KiCad `size_mm`.

    Sums per-glyph advance widths (font units) and scales by
    ``size_mm / units_per_em`` — the same arithmetic the freetype path used.
    Falls back to ``0.6 * size_mm * len(s)`` only if no table is available.
    """
    if not s:
        return 0.0
    entry = _resolve(face_name, bold, italic)
    if entry is None:
        return 0.6 * size_mm * len(s)
    glyphs = entry['glyphs']
    default = entry['default_advance']
    upem = entry['units_per_em']
    total = 0
    for ch in s:
        g = glyphs.get(ch)
        total += g[0] if g is not None else default
    return total / upem * size_mm


def measure_text_height(s, size_mm, face_name='Arial', bold=False, italic=False):
    """Return the rendered glyph-bbox height of `s` in mm at KiCad `size_mm`.

    The vertical extent of the inked glyphs (max ascent minus min descent), so an
    all-caps/digit string reports its cap height. Spaces are ignored. Falls back
    to `size_mm` if nothing measurable.
    """
    if not s:
        return 0.0
    entry = _resolve(face_name, bold, italic)
    if entry is None:
        return size_mm
    glyphs = entry['glyphs']
    upem = entry['units_per_em']
    top, bot = None, None
    for ch in s:
        if ch == ' ':
            continue
        g = glyphs.get(ch)
        if g is None:
            continue
        _, gtop, gbot = g
        top = gtop if top is None else max(top, gtop)
        bot = gbot if bot is None else min(bot, gbot)
    if top is None:
        return size_mm
    return (top - bot) / upem * size_mm
