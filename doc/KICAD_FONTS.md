# `--kicad-fonts` — render with KiCad's built-in stroke font

**Status:** implemented (2026-06-08). The coupled switch landed via the helpers
`_font_size_comp()` / `_measure_face()` and the module flag `_use_kicad_fonts`.
Verified: default mode byte-stable (332/332), `--kicad-fonts` emits zero
`(face …)`, ref/value emitted `(size)` identical to default mode, connectivity
identical, renders cleanly via `kicad-cli`.

Calibration note (corrects the original point 3 below): bitmap measurement (render
known strings via `kicad-cli`, read ink extents) showed KiCad renders the Newstroke
stroke font **anisotropically** relative to the embedded metrics
(`text_metrics_data.py`, units_per_em=21): for a given `(size)`, advance **widths**
render at **~1.0×** but **caps** at **~1.12×** (`_NEWSTROKE_CAP_INFLATION`). So:

- **Reference/Value** (sized from OrCAD `lfHeight`): emit the same `(size)` as
  outline mode (`/1.4`); the first cut dropped the `/1.4` and rendered ~1.4× too
  big. Renders ~1.1× the default cap (intrinsic) — accepted.
- **Free text / notes** (sized to *fit* a bbox): each fit constraint is converted
  to a `(size)` with its own render factor — width `/1.0`, height `/(1.4·1.12)` —
  instead of one `/1.4`. A single `/1.4` made notes ~1.4× too small (underfilled);
  the per-axis version fills the box like default. Outline keeps `w==h==1.4`, so the
  default path is byte-unchanged.
- **Placement box** (`_text_box_dims`) uses the rendered width
  (`measure_newstroke × 1.0`) but, for the **centring height**, a consistent cap
  reference (`'0'`) rather than the per-string ink extent. KiCad's Newstroke `'/'`
  renders ~1.22× the cap height, so centring a slash-bearing value (e.g.
  `22/0603`) on its own extent dropped it ~0.2 mm below the slash-free designator
  (`R2`); the cap reference keeps Reference/Value baselines level. Default
  (outline) mode keeps the per-string extent (≈cap for Arial, PDF-validated).
  Vertical nudge stays `0.416`. (Rotated 90/270 fields take the width into the
  perpendicular axis, so they still carry the Newstroke-is-wider offset above.)

## Known trade-off — not a bug

KiCad's Newstroke font is wider than Arial — ~**1.3×** for digit/punctuation-heavy
strings (Arial has narrow digits; Newstroke is an even stroke font). Example:
the value `10u/6.3V/1005` renders 14.87 mm in Arial but **19.52 mm** in Newstroke.
Reference/Value fields are centred at the OrCAD-derived position (correct to
~0.2 mm), so the wider stroke text extends ~2 mm further each side and **digit-heavy
values can overlap nearby wires** that the narrower Arial text cleared (e.g. C2/C5
on page 3 of fixture 0001).

This is intrinsic to the stroke font, not a placement or measurement error (the
converter measures Newstroke width to ~0.99×). It is **accepted on purpose**: the
`--kicad-*` flags exist to produce a *native* KiCad design — native symbols
(`--kicad-power`/`--kicad-rc`) and the native font (`--kicad-fonts`) — to import or
keep editing in KiCad, where a designer nudges the odd wide value just like in any
hand-built schematic. Default (Arial) mode remains the faithful, PDF-matching
reproduction. **Do not** "fix" the overlap by re-measuring or re-placing; the only
way to remove it would be to horizontally condense the text via `(size x y)`, which
defeats the native-look goal and was deliberately declined.

## Original implementation plan

The original `--kicad-fonts` design plan (idea, the coupled-switch mechanics,
code touch-points, testing notes, estimate) lived here. Parts of it — notably the
size / `/1.4` and nudge handling — were **superseded** by the calibration note
above; see this file's git history for the full original plan.
