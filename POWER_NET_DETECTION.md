# Power Net Detection in OrCAD DSN Files

Investigation notes for replacing the `is_power_net()` heuristic in `scripts/dsn2kicad`
with data-driven power net classification.

## Current Approach

`is_power_net()` at line 2797 decides whether a wire endpoint gets a power symbol
glyph (GND triangle / VCC bar) or a text label. It uses prefix/suffix matching:

```python
prefixes: VDD, GND, AGND, PGND, AVDD, DVDD, ADAVDD, ADAVSS, VIO, VCC, VBUS, VSS, +, -
suffixes: _VDD, _VCC, _VSS, _GND, _VBUS
regex:    _VBUS_(IN|OUT)\w*$
regex:    \d[\d.]*V\d*$   (e.g. "3V3", "5V0", "1.8V")
```

Called at 7 locations (lines 2985, 2991, 3185, 3204, 3228, 4685, 4691).

For test 0001 (CPU), this heuristic correctly identifies all 41 power nets and
produces zero false positives — but it relies on naming conventions that may not hold
for all OrCAD designs.

## Binary Format Investigation

### Locations examined

| Stream/Structure | Power/signal flag? | Notes |
|-----------------|-------------------|-------|
| Page net table | **No** | Sequential entries: `name_len(2) + name + null(1) + net_id(4)`. No flags between entries. |
| Page net table 32-byte index | **No** | Fixed-size records (72 on page 15): anchor(12) + constant(4) + zeros(5) + net_id(4) + zeros(7). All fields except net_id are identical across power and signal. |
| Hierarchy stream net table | **No** | Format: RECORD_MARKER + zeros(4) + sequential_index(4) + name_len(2) + name + null + fixed_pattern. All entries have identical `43 0b 00 00 00 00 00 00 00 43 00 00` suffix. |
| Net_id bit patterns | **No** | Tested all 32 bits across 133 power / 685 signal entries. No bit cleanly separates them (best is bit 14: 78% power vs 48% signal — not reliable). |
| Power symbol records | **Partial** | GND/VCC_BAR records carry no net_id, but their coordinate fields encode a derivable hotpoint that can be matched to wire endpoints. |
| Cache cell definitions | **No type flag** | GND/VCC_BAR use a different binary structure than regular cells (not parseable by `read_library_part()`). All 143 parseable cells have `implementation_type=0`. No "Symbol Type = Power" field found. |
| Cache cell source library | **Unreliable** | GND and VCC_BAR come from `CPU_BOARD.OLB`, same library as all regular components. Only ADAVSS/ADAVDD_18_SOC reference `POWER.OLB`. |
| Library `str_lst` | **Mixed** | Contains power net names but interleaved with component values, INS IDs, GUIDs, paths. No structural marker. |
| `SymbolPin.port_type` | **Not useful** | Only 4 values (0, 2, 4, 7). port_type=4 covers 2533 pins including both GND and signal. |
| Component `pin_nets` | **N/A** | Power symbols are NOT parsed by `parse_components()` — different binary format. |
| Power symbol `cell_id` | **Not an index** | Values in 19M range (sequential instance IDs). Don't match INS entries in str_lst. |

### Power symbol record format

```
ff e4 5c 39          RECORD_MARKER
00 00 00 00          4 zero bytes (distinguishes from wires)
rec_type(4, LE)      e.g. 0xE3, 0x039A — varies
header(4, LE)        e.g. 0x0DAB — varies
name_len(2, LE)      length of glyph name
name(name_len)       "GND", "VCC_BAR", "VCC", or "VCC_CIRCLE"
null(1)
cell_id(4, LE)       instance ID (19M range, sequential)
n0..n5(6 × i16)      coordinate-like fields used for hotpoint derivation
orient(2, LE)        e.g. 0x0030, 0x0130, 0x0330, 0x0430
property tags        0x25, 0x27, 0x21 tagged values (purpose unknown)
```

**Critical:** The coordinate fields are not directly the glyph anchor. Treating them
as literal positions gives poor spatial correlation. However, transforming the
extracted glyph anchor through the page instance logical box recovers the
electrical attachment point with high accuracy.

Each VCC_BAR record is followed by a secondary marker record with `rec_type = 0xE0`,
containing coordinates (-8, -12, 0) and additional property values. These secondary
records also do NOT contain net_ids or value indices.

### Page net_id structure

Each net name in a page's net table has a 4-byte LE net_id. This is a cross-reference
key tying wire segments to their net name. Example for VDD_BUCK1 on page 15:

| Location | Count | Purpose |
|----------|-------|---------|
| 32-byte index record | 1 | Fast-lookup table at start of page stream |
| Name table entry | 1 | `name_len + name + null + net_id` — the name-to-id mapping |
| Wire records | 17 | Each wire segment carrying VDD_BUCK1 has this net_id |

Wire record format (from `parse_wires()`):
```
RECORD_MARKER + zeros(4) + record_id(4) + net_id(4) + 0x30(4) + x1(4) + y1(4) + x2(4) + y2(4)
```

Net_ids are page-local (same net gets different IDs on different pages) and are in the
~20M range — shared number space with INS instance IDs but NOT the same objects.
The Hierarchy stream uses separate sequential indices (~12K–13K range).

### Spatial matching results

Attempted matching power symbol positions to wire endpoints across all 18 pages:

| Tolerance | Match rate | Notes |
|-----------|-----------|-------|
| Exact (0) | 1.9% | Only 12/648 |
| ≤ 10 units | 4.3% | |
| ≤ 20 units | 9.0% | |
| ≤ 50 units | 21.6% | |
| ≤ 100 units | 36.9% | Many false positives (signal nets) |

**Conclusion:** Naive spatial matching is not viable, but derived hotpoint matching is.

## Working Approach: Power Symbol Hotpoint Extraction

### Discovery

The `GND` and `VCC_BAR` page records do contain enough geometry to find the
electrical attachment point. The apparent "text bounding box" coordinates are in the
same raw page coordinate space as wire records, where one raw unit is 10 mil. KiCad
coordinates are therefore `raw * 0.254 mm`.

After the symbol name and null terminator, the record stores:

```
cell_id(4)
n0 n1 n2 n3 n4 n5    6 signed i16 coordinate-like values
orient(2)            e.g. 0x0030, 0x0130, 0x0330, 0x0430
property tags...
```

The electrical hotpoint is derived from the extracted Cache `GlobalSymbol` glyph.
Power glyph instances use a 20-by-10 logical box in page coordinates: `n4,n5`
are the logical origin, and the high byte of `orient` supplies the rotation/mirror
family. The glyph primitive anchor determines where the electrical terminal sits
inside that logical box:

```
GND/GND_POWER:       logical anchor (10, 0)
VCC_BAR/VCC/CIRCLE: logical anchor (10, 10)
```

The converter rotates that logical anchor into page coordinates:

```
rot 0: x = n4 + ax,          y = n5 + ay
rot 1: x = n4 + ay,          y = n5 + (width - ax)
rot 2: x = n4 + (width - ax), y = n5 + (height - ay)
rot 3: x = n4 + (height - ay), y = n5 + ax
```

where `rot = (orient >> 8) & 3`, `width = 20`, and `height = 10` for observed
OrCAD power-port logical boxes. This replaces the previous per-record hotpoint
equations for `GND`, `VCC_BAR`, `VCC`, and `VCC_CIRCLE`.

The `VCC`/`VCC_CIRCLE` transform is confirmed on `board 0120`;
all 114 records land exactly on parsed wire endpoints or component pins.

The resolved record name also selects the emitted KiCad power-symbol geometry.
For positive power symbols, `scripts/dsn2kicad` first tries to extract matching
OrCAD `GlobalSymbol` primitive graphics from the DSN Cache (`VCC_BAR`,
`VCC_CIRCLE`, etc.) and emits those as project-local KiCad power symbols. If
extraction is unavailable, it falls back to built-in GND, rail/bar, or circle
glyphs. GND-style symbols still use the controlled KiCad GND triangle path.

Use raw coordinates for matching to `parse_wires()` output. Multiply by 10 only when
comparing to the DSN-unit values implied by generated KiCad output.

### Validation on test 0001

Across all page streams in `board 0001`:

| Symbol | Hotpoints matching a wire endpoint | Notes |
|--------|------------------------------------|-------|
| GND | 393 / 394 | The remaining miss is a deliberately floating GND symbol. |
| VCC_BAR | 246 / 254 | The misses are valid direct-to-component-pin attachments, not missing power nets. |

For `15_POWER1`, the transform matches all 74 GND expected anchors and 51 of 53
VCC_BAR expected anchors exactly. The two VCC_BAR misses are confirmed direct
connections to component pins (`R256` and `R257`) with no intervening wire segment.

Exact wire-endpoint matching should therefore be combined with component-pin matching:
a power symbol hotpoint can connect either to a wire endpoint or directly to a
component pin. Direct pin attachments observed in test 0001 include `R12`, `R19`,
`R23`, `FB21`, `R256`, `R257`, and `R278`.

Known exact-match exceptions from visual inspection:

| Page | Symbol | Hotpoint | Interpretation |
|------|--------|----------|----------------|
| `11_PCIe` | GND | `(4300, 10400)` | Floating, disconnected GND in original schematic. |
| `10_Ethernet` | GND | `(15000, 11500)` | Horizontal GND in OrCAD; transformed anchor matches the wire endpoint. |
| `03_Clock...` | VCC_BAR | `(8700, 14200)` | Valid connection on opposite side; transformed anchor matches the wire endpoint. |
| `03_Clock...` | VCC_BAR | `(4500, 12500)` | Direct connection to `R19`. |
| `03_Clock...` | VCC_BAR | `(2800, 13300)` | Direct connection to `R23`. |
| `03_Clock...` | VCC_BAR | `(2000, 6800)` | Direct connection to `R12`. |
| `10_Ethernet` | VCC_BAR | `(16000, 3600)` | Direct connection to `FB21`. |
| `16_POWER2` | VCC_BAR | `(2900, 11000)` | Direct connection to `R278`. |
| `15_POWER1` | VCC_BAR | `(1900, 7200)` | Direct connection to `R256`. |
| `15_POWER1` | VCC_BAR | `(3300, 8100)` | Direct connection to `R257`. |

### Detection method

1. Parse power glyph records from each page stream (`GND`, `VCC_BAR`, `VCC`,
   `VCC_CIRCLE`, etc.).
2. Compute each hotpoint from the extracted glyph anchor and page instance
   transform.
3. Build an index from wire endpoint `(x, y)` to the wire's page-local `net_id`.
4. Build or reuse a component-pin coordinate index with each pin's connected `net_id`.
5. A power-symbol hotpoint matching either a wire endpoint or a component pin marks
   that `net_id` as a power net.
6. Resolve the `net_id` through the page net table to get the net name.

This is the first high-confidence data-driven method found for implicit labels such
as `VDD_BUCK1` and `VIO1.8V`, which do not have text records.

## Supporting Approach: Text Record Extraction

### Discovery

Power net names are stored in page-stream **text records** — the same type used for
other text annotations. These carry the visible label text displayed next to VCC_BAR
power symbols.

### Text record format

```
ff e4 5c 39          RECORD_MARKER
00 00 00 00          zeros
00 00 00 00          rec_type = 0
00 00                padding
30 00 00 00          subtype 0x30
01 00 2e 2e          TEXT_RECORD_TYPE_WORD
NN 00 00 00 00 00 00 00   subtype byte + 7 zeros (NN varies: 0x30, 0x2C, 0x2D)
x1(4) y1(4) x2(4) y2(4) x3(4) y3(4)   bounding coordinates (6 × i32)
3e 00                text marker (0x3E)
XX XX                2 bytes (flags? color? — varies)
name_len(2, u16 LE)  length of text string
text(name_len)       the text content (e.g. "VDD1G_1p8")
null(1)
```

### Detection method

1. Scan each page for text records (`RECORD_MARKER` + `TEXT_RECORD_TYPE_WORD` at offset +18)
2. Extract the text string (after `0x3E` marker, u16 length prefix)
3. Intersect with the page's net table (case-insensitive match)
4. Any text record whose content matches a net name → that net is a power net

### Results on test 0001

| Metric | Value |
|--------|-------|
| Expected power nets | 42 |
| Detected by text records | 31 (74%) |
| False positives | 0 |
| Missing | 11 |

**Missing nets:** ADAVDD_18_SOC, ADAVSS, DSI_VREG_0P4V, UPD_1V8, UPD_3V3,
USBC_VBUS_OUT1, USB_OTG_5V, VDD5G_1P8_EN, VDD6G_1P2_EN, VDD_BUCK1, VIO1.8V

LDO3_1P2 was initially suspected as a false positive but is confirmed as a real
power net (verified against the original OrCAD schematic).

### Pages with text records

Only power-heavy pages have text records with net names:
- Page 15 (POWER1): 19 text records, all match net names
- Page 16 (POWER2): 5 match net names, 1 non-net ("(0.8V)")
- Page 17 (POWER3): 7 text records, all match net names
- Other pages: 0-2 text records, none match net names

## The Missing 11: VIO1.8V, VDD_BUCK1, etc.

These power nets have VCC_BAR glyph records on pages but NO associated text record.
Their net names appear ONLY in net tables and the Library str_lst — never as visible
text annotations in the page stream.

### VDD_BUCK1 — 4 raw file occurrences (2 power symbols in schematic)

| Location | Stream | Stream offset | What |
|----------|--------|---------------|------|
| Library str_lst | Library | 0x0a1f5 | Value string (interleaved with INS IDs) |
| Hierarchy net table | Hierarchy | 0x05833 | Master net entry (sequential index 13138) |
| Page 15 net table | Pages/15_POWER1 | 0x00d49 | Page net entry (net_id 20010015) |
| Page 16 net table | Pages/16_POWER2 | 0x009cf | Page net entry (net_id 20010954) |

### VIO1.8V — 4 raw file occurrences (4 power symbols in schematic)

| Location | Stream | Stream offset | What |
|----------|--------|---------------|------|
| Library str_lst | Library | 0x021e6 | Block of power net names (indices 223-232) |
| Hierarchy net table | Hierarchy | 0x0029b | Standard net entry |
| Page 03 net table | Pages/03_... | 0x00ea2 | Page net entry |
| Page 15 net table | Pages/15_... | 0x00d59 | Page net entry |

### Pattern

These nets exist ONLY as:
1. Wire segments (carrying the net_id in their wire records)
2. Net table entries (name-to-id mapping)
3. Library str_lst strings

They do NOT have explicit text annotation records. OrCAD renders their labels
implicitly from the wire's net name when displaying the VCC_BAR glyph.

**Open question:** What determines whether OrCAD stores a text record for a power
net label vs. rendering it implicitly? Possible factors:
- Manual text placement vs. automatic labeling
- Whether the label was edited/moved after placement
- OrCAD version differences
- Some other property of the VCC_BAR instance record

## OrCAD Power Symbol Architecture (from manual)

Per the OrCAD Capture User Guide:
- Power symbols are created by selecting **"Power" as the Symbol Type** in the
  New Symbol dialog. This is a property of the cell/library definition.
- Power nets are **global by default** — they connect all same-named pins across
  the entire design hierarchy without needing off-page connectors.
- Signal nets crossing page boundaries require off-page connectors; power nets don't.
- Only two glyph shapes exist: GND (triangle) and VCC_BAR (bar with line).
- The net name comes from the invisible **power pin** (pin type = POWER, not visible).
- Off-page connector names take precedence over power symbol names for scope isolation.

### Implication for detection

Power nets tend to appear on more pages than signal nets (global scope):
- Power nets: median 2 pages, mean 3.2, max 16 (GND)
- Signal nets: median 1 page, mean 1.5, max 5

However, there is overlap (some power nets appear on only 1 page, some signal nets
span 5 pages), so page count alone is not a reliable discriminator.

A more robust approach: nets appearing on multiple pages WITHOUT corresponding
off-page connector records are likely power nets (they connect globally via their
power pin, not via off-page connectors). Off-page connectors (`OFFPAGELEFT-L`,
`OFFPAGELEFT-R`, `OFFPAGELEFT-BIDIR`) are already parsed by the converter.

## Library str_lst Structure

The Library stream's string table (`str_lst`, ~3551 entries) contains power net names
in two identifiable locations:

### Block 1: Power net values (indices 223-232)

```
[223] VDD1G_1p8        ← power net value
[224] Name             ← field metadata keyword
[225] VDD2G_1p8        ← power net value
[226] VDD1G_0p8
[227] VIO1.8V
[228] D5.0V1
[229] S1.2V
[230] S1.8V
[231] SDTSourceLibName ← metadata keyword (boundary marker)
[232] GND
[233] C:\rd\ui\GENERIC_POWER.LIB  ← library path
```

This block appears to be the set of power net values defined in the design's initial
power symbol instances (the "original" power nets set up during schematic creation).

### Block 2: POWER.OLB references (index 3468)

```
[3468] C:\ORCADWORK16_6\COMMON\POWER.OLB  ← external power library
[3469] ADAVSS                              ← power net from POWER.OLB
[3470] ADAVDD_18_SOC                       ← power net from POWER.OLB
[3471] 1.04                                ← version number
```

Entries immediately following `.OLB` paths containing "POWER" are power symbol names
from that library.

### Other power net locations

Scattered throughout str_lst as component values (following INS instance IDs):
```
[606] DDR_VDDQ_1.1V
[607] DDR_VDDQLP_0.6V
[764] VDD1833_SD0
[1138] USB_OTG_5V
[2159] VDD09_CA55
[2618] VDD_BUCK1
[2853] USBC_VBUS_OUT
```

These are indistinguishable from regular component values by structure alone.

## Proposed Detection Strategy

### Layer 1: Power-symbol hotpoint + wire endpoint match (primary)

Parse `GND`/`VCC_BAR` records, compute hotpoints, and match those hotpoints to parsed
wire endpoints. This directly identifies the page-local `net_id` connected to the
power object and should replace name-based classification wherever the match exists.

### Layer 2: Text record + net table intersection (~73% coverage, high precision)

Parse text records from all pages, intersect with net tables. This is the only
method that extracts power net names directly from page-level data without heuristics.

### Layer 3: Library str_lst extraction (~5% additional)

- Entries following `POWER.OLB` paths → ADAVSS, ADAVDD_18_SOC
- Entries 223-232 between "Name" and "SDTSourceLibName" keywords → VDD1G_1p8, etc.

`ADAVSS` is a named GND-style power symbol: visually it uses a GND glyph with the
name shown, unlike ordinary nameless GND symbols. Its page-stream GND hotpoint
resolves to the physical `GND` net, so it must be recovered from the `POWER.OLB`
name block when `ADAVSS` is present in the page net table.

When emitting named GND-style symbols such as `ADAVSS`, use a `power:<name>` symbol
with GND triangle geometry and keep the visible `Value` text outside the triangle.
For generated schematic instances, the positive-Y side is visually below the symbol
in KiCad sheet coordinates; `y + 3.81 mm` gives the text enough clearance. Plain
`GND` still hides its value text.

### Layer 4: GND family (hardcoded, small fixed set)

GND, AGND, PGND, DGND, SGND, VSS — these always use the GND triangle glyph.
GND records in page streams never carry text records with the net name.

### Layer 5: Name heuristic fallback

For unmatched or malformed records, fall back to the existing pattern-matching
heuristic and log that the classification was not object-derived.

## Ruled Out

These approaches were investigated and confirmed not viable:

- **Net_id bit patterns:** No bit in the 32-bit net_id separates power from signal.
- **Cache "Symbol Type" field:** Per OrCAD docs, power symbols have "Symbol Type =
  Power" in their library definition. However, GND/VCC_BAR cells in this file use a
  different binary structure than regular cells (not parseable by `read_library_part()`).
  No explicit type flag was found in the raw bytes. All 143 parseable regular cells
  have `implementation_type=0` with no variation.
- **Source library as discriminator:** GND and VCC_BAR are in `CPU_BOARD.OLB` alongside
  all regular components. Only 2 of 42 power nets (ADAVSS, ADAVDD_18_SOC) reference
  `POWER.OLB`.
- **Naive spatial matching:** Raw power-symbol coordinates are not direct connection
  points. Match only after deriving the hotpoint from the record fields.

## Leads for Further Investigation

1. **VCC_BAR property tags:** The `0x25`, `0x27`, `0x21` tagged values in power
   symbol records have unknown semantics. The 2-byte value after `0x25` in VCC_BAR
   records varies (256, 280, 284, 322, 340) — these might encode something useful
   but don't correspond to str_lst indices or net_ids.

2. **Secondary 0xE0 records:** Each VCC_BAR is followed by a `rec_type=0xE0` record.
   The u16 at offset +19 in these records also varies but doesn't map to useful data.
   The 4 bytes after `0x21` tag (e.g. 0x013E8568) are in the 20M range but don't
   match any known ID space.

3. **Text record subtype byte:** The byte at offset +22 in text records varies
   (0x30, 0x2C, 0x2D). This might encode text type (power label, note, etc.) but
   hasn't been correlated with power/signal classification.

4. **Missing text records pattern:** Why do some VCC_BAR symbols have text records
   while others don't? If this can be understood, we might find the missing 11 nets
   through an alternative mechanism.

5. **Wire-to-glyph edge cases:** Hotpoint extraction solves the main attachment
   problem. Remaining cases need explanation: some symbols do not land exactly on a
   parsed wire endpoint, and some object-derived VCC_BAR anchors appear to be absent
   from the current heuristic-generated expected output.

6. **GND/VCC_BAR binary structure in Cache:** These cells have a different record
   format from regular cells — preceded by `RECORD_MARKER + zeros(4) + name_len(2)`
   rather than the `(.{4})\1\x18\x00\x18` pattern used for LibraryPart structures.
   The distinguishing structural difference hasn't been fully characterized.

## Test Data Reference

Test case: `board 0001`

Legacy expected output classified these 42 names as power nets:
```
ADAVDD_18_SOC, ADAVSS, D3.3V, D3.5V, D5.0V1, D5.0V2, DDR_VDDQLP_0.6V,
DDR_VDDQ_1.1V, DSI_VREG_0P4V, GND, LDO3_1P2, MICROSD0_1833V,
MICROSD0_3.3V, MICROSD1_1833V, MICROSD1_3.3V, PCIE_12V0, PCIE_3V3,
S1.2V, S1.8V, UPD_1V8, UPD_3V3, USBC_VBUS_IN, USBC_VBUS_OUT,
USBC_VBUS_OUT1, USB_OTG_5V, VDD08_DDR, VDD09_CA55, VDD1833_SD0,
VDD1833_SD1, VDD1G_0P8, VDD1G_1P8, VDD2G_1P8, VDD3G_0P8, VDD4G_0P8,
VDD4G_3P3, VDD5G_1P8, VDD5G_1P8_EN, VDD6G_1P2, VDD6G_1P2_EN,
VDD_BUCK1, VIO1.8V, VPROG_22V
```

After hotpoint-based classification, the following previously heuristic-only names
are considered non-power unless another OrCAD power object proves otherwise:
`DSI_VREG_0P4V`, `VDD5G_1P8_EN`, `VDD6G_1P2_EN`.

Hotpoint-based classification additionally confirms these VCC_BAR-style power nets
that the legacy heuristic expected as labels:
```
ETH0_AVDDH, ETH0_AVDDL, ETH0_AVDDL_PLL, ETH0_DVDDH, ETH0_DVDDL,
ETH1_AVDDH, ETH1_AVDDL, ETH1_AVDDL_PLL, ETH1_DVDDH, ETH1_DVDDL,
UART_BRIDGE_VCCIO, MIPI_CSI_VCC0
```

Signal nets with VDD/GND-like substrings that are correctly NOT power:
```
USB20_USDVDD, USB20_USVDD18, USB20_USVDD33, USB30_USVDD33_SOC,
PCIE_VCC08A_L01_SOC, PCIE_VCC18A_CMN_SOC, PCIE_VCC18A_L01_SOC,
PLDVDD08_*, PLVDD_*, CSI*_MSVDD*, DSI_VDD*
```
