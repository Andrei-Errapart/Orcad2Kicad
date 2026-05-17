# OrCAD Schematic PDF Color Map

Colors used in OrCAD Capture schematic PDF exports. Verified across 3 PDF files from OrCAD Capture 23.1.

## Drawing Elements (Lines)

| Element | Hex | Width | Notes |
|---------|-----|-------|-------|
| Wires | `#4200ff` | 0.127–0.169mm | Always horizontal/vertical |
| Pins | `#aa8744` | 0.127mm | H/V only, short (1.8mm or 5.3mm) |
| Symbol body | `#cc8005` | 0.127–0.169mm | H/V and diagonal |
| Pin-end markers | `#803f00` | 0.132mm | Small diagonal X shapes, in pairs |
| Border/frame | `#000000` | 0.127–0.508mm | Page outline and grid |
| Off-page connectors | `#008000` | 0.127–0.169mm | Port symbol lines |
| Annotation lines | `#ff0000` | 0.381mm | Thick red, only on some pages |
| Filled shapes (no stroke) | None (fill `#cc8006`) | — | Symbol body fills |

## Curves

| Element | Hex | Notes |
|---------|-----|-------|
| Junction dots | `#ff0000` | Tiny ~0.3mm circles |
| Symbol body arcs | `#cc8005` | Part of symbol outlines |
| Off-page connector shapes | `#008000` | Larger curved port symbols |

## Text

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

## Line Width Variations

Smaller board PDFs use 0.169mm for most elements; the larger board PDF uses 0.127mm. Pin-end markers consistently use 0.132mm across all files.
