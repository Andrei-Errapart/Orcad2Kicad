meta:
  id: dsn_directory
  title: OrCAD DSN — generic "*Directory" index stream
  endian: le
  license: CC0-1.0

doc: |
  Shared envelope used by every "*Directory" stream in an OrCAD Capture
  .DSN OLE compound document, including (observed on the CPU
  board, where these are non-empty):

    - "Cells Directory"        — cell names    (e.g. "CPU_0M")
    - "Parts Directory"        — part names    (e.g. "CPU_0E.Normal")
    - "Packages Directory"     — package names (e.g. "CPU_0")
    - "Symbols Directory"      — symbol names  (e.g. "ERC")
    - "Views Directory"        — view names    (e.g. "SCHEMATIC1")
    - "ExportBlocks Directory" — empty (count = 0)
    - "Graphics Directory"     — empty (count = 0)

  All share the same header (u32 unix timestamp + u16 entry count) and
  the same per-entry layout. The only per-stream difference is what the
  per-entry `kind` field holds and what naming convention the entries
  use.

  This file *replaces* the earlier `dsn_cells_directory.ksy` sketch,
  which incorrectly modelled the 4-byte leading word as part of a
  fixed-size record and used a Windows FILETIME for the leading word.

seq:
  - id: header
    type: dir_header
  - id: entries
    type: dir_entry
    repeat: expr
    repeat-expr: header.count

types:

  dir_header:
    doc: |
      8-byte header.

      `timestamp` is a Unix `time_t` (seconds since 1970-01-01 UTC),
      little-endian u32. Confirmed across CPU board and sub-board DSNs:
      values like `fb e4 13 69` (= 0x6913e4fb = 2025-11-12 01:38:03 UTC,
      CPU board) and `8c 73 b4 67` (= 0x67b4738c = 2025-02-17 15:53:48
      UTC, microSD sub-board).

      `count` is the number of `dir_entry` records that follow. Empty
      directories have `count == 0`, giving a 6-byte stream.
    seq:
      - id: timestamp
        type: u4
        doc: Unix `time_t` (seconds since 1970-01-01 UTC).
      - id: count
        type: u2

  dir_entry:
    doc: |
      One directory record. Total size is variable:
        2 + name_len + 1 + 2 + 8 + 8 + 4 = 21 + name_len bytes.

      Empirically, 104 entries × 34 bytes (for 9-char names like
      "CPU_0M") + 6-byte header = 3542 bytes of "Cells Directory",
      matching exactly.
    seq:
      - id: name_len
        type: u2
      - id: name
        type: str
        size: name_len
        encoding: ASCII
      - id: terminator
        contents: [0x00]
      - id: kind
        type: u2
        doc: |
          Per-entry kind/flags word. Stream-dependent:
            0x0006 — "Cells Directory"    (cell)
            0x0018 — "Parts Directory"    (part, '.Normal' suffix)
            0x001f — "Packages Directory" (package, CPU_0..3)
            0x004b — "Symbols Directory"  (single entry "ERC")
            0x0009 — "Views Directory"    (single entry "SCHEMATIC1")
          Confirmed identical across CPU board, eMMC sub-board, and
          microSD sub-board DSNs. Bit-meanings within this u16 are not
          fully decoded.
      - id: filetime_created
        type: u8
        doc: |
          Windows FILETIME (100-ns intervals since 1601-01-01 UTC).
          Suspected creation timestamp of the entry; not yet
          cross-validated.
      - id: filetime_modified
        type: u8
        doc: |
          Second FILETIME, suspected modification timestamp. For the
          four CPU_xN cells of the CPU board this field is the same
          across the four sibling units, while `filetime_created`
          differs — consistent with "modified together, created
          separately".
      - id: trailer
        size: 4
        doc: |
          Trailing 4 bytes. Observed values, constant within each stream
          kind but differing between kinds:
            `d8 04 02 00` — Cells, Parts, Packages directories
            `03 00 02 00` — Symbols, Views directories
          Likely encodes a per-stream-kind schema/version word; the low
          word looks like a format version (0x04d8 vs 0x0003) and the
          high word like a flags field (0x0002 in both cases). Not
          fully decoded.
