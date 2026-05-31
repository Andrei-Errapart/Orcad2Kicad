meta:
  id: olb_common
  title: Shared types for OrCAD OLB streams
  endian: le
  license: CC0-1.0

doc: |
  Shared building blocks used by OrCAD Capture .OLB library streams.
  The OLB file is an OLE Compound Document; these types describe the
  binary layout within individual OLE streams extracted by olefile.

  The format uses two pervasive framing mechanisms:

  1. **Preamble** — a 4-byte magic (FF E4 5C 39) followed by a u4
     data length and that many bytes of opaque payload.  Preambles
     appear after prefix blocks and after each primitive record.

  2. **Prefix block** — a sequence of N "prefix" entries that encode
     checkpoint offsets within the following data.  The first N-1
     entries are 9 bytes each (u1 type, u4 byte_offset, 4 unknown);
     the last entry is a "short prefix" (u1 type, s2 size, then
     |size| pairs of u4 if size >= 0).  The number of prefixes N is
     fixed per structure type but must be determined empirically.

types:

  preamble:
    doc: |
      Magic marker + length-delimited opaque data block.
      Appears after prefix blocks and after primitive records.
    seq:
      - id: magic
        contents: [0xff, 0xe4, 0x5c, 0x39]
      - id: data_len
        type: u4
      - id: data
        size: data_len

  len_string:
    doc: |
      u2-prefixed ASCII string followed by a null terminator.
      The length does NOT include the terminator.
    seq:
      - id: len_str
        type: u2
      - id: value
        type: str
        size: len_str
        encoding: ASCII
      - id: terminator
        contents: [0x00]

  point_yx:
    doc: |
      2D point stored as (y, x) in u2 pairs.
      Used inside polyline, polygon, and bezier primitives.
      Coordinates are in OrCAD units (10 mils = 0.254 mm).
    seq:
      - id: y
        type: u2
      - id: x
        type: u2

  logfont:
    doc: |
      Windows LOGFONTA structure (60 bytes).
      Describes a font used for text rendering.
    seq:
      - id: height
        type: s4
      - id: width
        type: s4
      - id: escapement
        type: s4
      - id: orientation
        type: s4
      - id: weight
        type: s4
      - id: italic
        type: u1
      - id: underline
        type: u1
      - id: strike_out
        type: u1
      - id: charset
        type: u1
      - id: out_precision
        type: u1
      - id: clip_precision
        type: u1
      - id: quality
        type: u1
      - id: pitch_and_family
        type: u1
      - id: face_name
        type: str
        size: 32
        encoding: ASCII

  # --- Prefix framework ---

  full_prefix:
    doc: |
      A "full" prefix entry (9 bytes): type byte, byte offset from
      the prefix start to a checkpoint in the data, and 4 unknown bytes.
    seq:
      - id: type_byte
        type: u1
      - id: byte_offset
        type: u4
      - id: unknown
        size: 4

  short_prefix_pair:
    seq:
      - id: name_index
        type: u4
      - id: value_index
        type: u4

  short_prefix:
    doc: |
      The final prefix entry: type byte + s2 size.
      If size >= 0, followed by |size| pairs of (u4 name_idx, u4 value_idx).
    seq:
      - id: type_byte
        type: u1
      - id: size
        type: s2
      - id: pairs
        type: short_prefix_pair
        repeat: expr
        repeat-expr: "size >= 0 ? size : 0"
