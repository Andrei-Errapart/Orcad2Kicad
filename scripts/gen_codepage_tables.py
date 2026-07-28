#!/usr/bin/env python3
# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate the legacy-codepage decoding tables embedded in dsn2kicad.hs.

OrCAD stores Library string-pool text in the Windows ANSI codepage of the
machine that authored the design, and records nowhere which one that was (see
doc/ORCAD_FILE_FORMAT.md).  The converter therefore has to carry its own
tables: it has no C FFI, so iconv is unavailable, and the WASM target rules it
out anyway.

The tables come from Python's own codecs, which are the standard Microsoft
mappings, so this script needs no third-party package.  Run it after changing
CODEPAGES; it rewrites the marked block in dsn2kicad.hs in place:

    python3 gen_codepage_tables.py
"""

import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
HK_PATH = SCRIPT_DIR / 'dsn2kicad.hs'
HK_BEGIN = '-- BEGIN GENERATED CODEPAGE TABLES'
HK_END = '-- END GENERATED CODEPAGE TABLES'

UNMAPPED = '�'

# (Haskell identifier, Python codec, human name)
CODEPAGES = [
    ('cp932', 'cp932', 'Japanese (Shift-JIS)'),
    ('cp936', 'cp936', 'Simplified Chinese (GBK)'),
    ('cp950', 'cp950', 'Traditional Chinese (Big5)'),
]


def probe_singles(codec):
    """Bytes 0x80..0xFF that decode standalone (e.g. CP932 half-width kana)."""
    out = []
    for b in range(0x80, 0x100):
        try:
            decoded = bytes([b]).decode(codec)
        except Exception:
            out.append(UNMAPPED)
            continue
        out.append(decoded if len(decoded) == 1 else UNMAPPED)
    return out


def probe_doubles(codec):
    """Every (lead, trail) pair that decodes, plus the ranges actually used."""
    pairs = {}
    for lead in range(0x81, 0xFF):
        for trail in range(0x40, 0xFF):
            try:
                decoded = bytes([lead, trail]).decode(codec)
            except Exception:
                continue
            if len(decoded) == 1 and decoded != UNMAPPED:
                pairs[(lead, trail)] = decoded
    if not pairs:
        raise SystemExit(f'{codec}: no double-byte mappings found')
    leads = [k[0] for k in pairs]
    trails = [k[1] for k in pairs]
    return pairs, min(leads), max(leads), min(trails), max(trails)


def hs_string(chars):
    """Haskell string literal. Non-ASCII goes in verbatim (the source is UTF-8);
    control characters use numeric escapes, which then need \\& when a digit
    follows so the escape does not swallow it.  Unassigned slots are written as
    NUL, which no byte sequence legitimately maps to and which costs two source
    characters instead of the seven that a U+FFFD escape would."""
    out = []
    prev_numeric = False
    for ch in chars:
        code = ord(ch)
        if ch == UNMAPPED:
            out.append('\\0')
            prev_numeric = True
            continue
        # Escapes cover more than the ASCII controls: several codepages map a
        # byte to a C1 control (CP932 0x80 -> U+0080) and CP932 0x8140 is the
        # ideographic space, none of which may appear raw in a Haskell literal.
        if not ch.isprintable():
            out.append('\\%d' % code)
            prev_numeric = True
            continue
        if prev_numeric and ch.isdigit():
            out.append('\\&')
        prev_numeric = False
        if ch == '"':
            out.append('\\"')
        elif ch == '\\':
            out.append('\\\\')
        else:
            out.append(ch)
    return '"' + ''.join(out) + '"'


def emit_codepage(name, codec, label):
    singles = probe_singles(codec)
    pairs, lead_lo, lead_hi, trail_lo, trail_hi = probe_doubles(codec)
    span = trail_hi - trail_lo + 1
    rows = []
    for lead in range(lead_lo, lead_hi + 1):
        row = [pairs.get((lead, t), UNMAPPED)
               for t in range(trail_lo, trail_hi + 1)]
        rows.append((lead, row))
    total = (lead_hi - lead_lo + 1) * span

    lines = [
        '-- | %s.  %d single-byte and %d double-byte mappings.' % (
            label, sum(1 for c in singles if c != UNMAPPED), len(pairs)),
        '%sTable :: Codepage' % name,
        '%sTable = Codepage' % name,
        '  { cpName = "%s"' % name,
        '  , cpLeadLo = 0x%02x' % lead_lo,
        '  , cpLeadHi = 0x%02x' % lead_hi,
        '  , cpTrailLo = 0x%02x' % trail_lo,
        '  , cpTrailHi = 0x%02x' % trail_hi,
        '  , cpSingle = U.listArray (0, 127) %s' % hs_string(singles),
        '  , cpDouble = U.listArray (0, %d) $ concat' % (total - 1),
    ]
    for index, (lead, row) in enumerate(rows):
        prefix = '      [ ' if index == 0 else '      , '
        lines.append('%s%s -- 0x%02x' % (prefix, hs_string(row), lead))
    lines.append('      ]')
    lines.append('  }')
    lines.append('')
    return lines


def build_block():
    lines = [
        HK_BEGIN + ' -- AUTO-GENERATED, do not edit.',
        '-- Regenerate via: python3 gen_codepage_tables.py',
        '--',
        '-- Windows ANSI codepage tables for decoding Library string-pool text.',
        '-- Mappings are Python\'s own codecs, i.e. the standard Microsoft ones.',
        '-- A slot holding U+FFFD is an unassigned byte sequence, which',
        '-- decodeCodepage reports as a decode failure rather than substituting.',
        '',
        'data Codepage = Codepage',
        '  { cpName :: !String',
        '  , cpLeadLo :: !Int',
        '  , cpLeadHi :: !Int',
        '  , cpTrailLo :: !Int',
        '  , cpTrailHi :: !Int',
        '  , cpSingle :: !(U.UArray Int Char)',
        '  , cpDouble :: !(U.UArray Int Char)',
        '  }',
        '',
    ]
    for name, codec, label in CODEPAGES:
        lines.extend(emit_codepage(name, codec, label))
    # CP1252 is single-byte, so it needs only the 0x80..0x9F block; 0xA0..0xFF
    # is Latin-1 and maps to the identical code point.
    cp1252 = probe_singles('cp1252')
    lines.append("-- | Western European (CP1252): the 0x80..0xFF block.  Bytes")
    lines.append("-- 0xA0..0xFF coincide with Latin-1; 0x80..0x9F do not.")
    lines.append('cp1252High :: U.UArray Int Char')
    lines.append('cp1252High = U.listArray (0, 127) %s' % hs_string(cp1252))
    lines.append(HK_END)
    return '\n'.join(lines) + '\n'


def splice(block):
    text = HK_PATH.read_text(encoding='utf-8')
    if HK_BEGIN in text and HK_END in text:
        start = text.index(HK_BEGIN)
        end = text.index(HK_END) + len(HK_END) + 1
        new = text[:start] + block + text[end:]
    else:
        raise SystemExit('markers not found in %s; add them first' % HK_PATH)
    HK_PATH.write_text(new, encoding='utf-8')


def main():
    block = build_block()
    if '--stdout' in sys.argv[1:]:
        sys.stdout.write(block)
        return
    splice(block)
    print('spliced %d bytes of codepage tables into %s'
          % (len(block.encode('utf-8')), HK_PATH))


if __name__ == '__main__':
    main()
