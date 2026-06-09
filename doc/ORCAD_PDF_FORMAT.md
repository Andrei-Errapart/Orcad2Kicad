# OrCAD PDF Format

Format of OrCAD Capture's schematic PDF export — colors and wire geometry.

## Colors

OrCAD draws each element class in a fixed color, which is how one can
tell wires from pins from symbol bodies, etc. (KiCad's own PDF export uses a
different palette — e.g. it renders wires green `#009500` rather than OrCAD's
blue `#4200ff` — so color maps are *not* interchangeable between the two PDFs.)

### Drawing elements (lines)

| Element | Hex | Width | Notes |
|---------|-----|-------|-------|
| Wires | `#4200ff` | 0.127–0.169mm | Always horizontal/vertical |
| Pins | `#aa8744` | 0.127mm | H/V only, short (1.8mm or 5.3mm) |
| Symbol body | `#cc8005` | 0.127–0.169mm | H/V and diagonal |
| Pin-end markers | `#803f00` | 0.132mm | Small diagonal X shapes, in pairs |
| Border/frame | `#000000` | 0.127–0.508mm | Page outline and grid |
| Off-page connectors | `#008000` | 0.127–0.169mm | Port symbol lines |
| Filled shapes (no stroke) | fill `#cc8006` | — | Symbol body fills |

### Curves

| Element | Hex | Notes |
|---------|-----|-------|
| Junction dots | `#ff0000` | Tiny ~0.3mm circles |
| Symbol body arcs | `#cc8005` | Part of symbol outlines |
| Off-page connector shapes | `#008000` | Larger curved port symbols |

### Text

| Element | Hex | Examples |
|---------|-----|---------|
| Pin numbers, grid refs | `#000000` | "1", "2", "5" |
| Net/signal labels | `#0000cc` | "TRD2+", "MOS1_D", "Vdda" |
| Page title, design notes | `#008000` | "Ethernet", "Length Matching..." |
| Warnings, cross-refs | `#ff0000` | "AGND and PGND are separated..." |
| Block titles | `#0000ff` | "CPU EtherMAC", "SLEEP#" |
| Symbol internal labels | `#cc8006` | "A", "B", "G", "IPU", "IPD" |
| Config/table text | `#400040` | board configuration labels, "L" |
| Component color codes | `#000080` | "GREEN" |
| Component specs | `#000040` | "1mohm 1% 1/2W" |

Line widths: smaller-board PDFs use ~0.169mm for most elements, larger boards
~0.127mm; pin-end markers are consistently 0.132mm.

## Wire geometry

1. **Wire coordinates are usually scaled uniformly** — the same factor for x and
   y. The factor is the ratio of the OrCAD Capture page size to the export PDF
   page size, so it is design-specific (observed ~1.4–2.0) and must not be assumed.
2. **Some PDFs extend individual wire lengths** by a small discrete amount —
   multiples of a half-grid step (0, 1.27mm, 2.54mm, …) — from how OrCAD draws
   the overlap of a net segment with the pin it meets. This is additive and
   discrete, not a scaling error, and is absent on designs whose wires terminate
   cleanly on grid.
3. **The wire *bounding box*, by contrast, is always strictly scaled** with no
   per-wire adjustment — the extreme endpoints carry no offset.

The conversion itself preserves wire lengths exactly (`dsn2kicad` applies a fixed
`× 0.254` 10-mil→mm with no grid snapping, and `kicad-cli sch export pdf` renders
at `× 1.0`), so any non-uniformity relative to the OrCAD PDF originates in
OrCAD's exporter, not the conversion.
