meta:
  id: dsn_common
  title: Shared types for OrCAD DSN streams
  endian: le
  license: CC0-1.0

doc: |
  Shared building blocks used by several OrCAD Capture .DSN streams.
  Imported by `dsn_page`, `dsn_cache`, `dsn_hierarchy`.

types:

  record_marker:
    doc: |
      4-byte separator that prefixes nearly every structured record in
      page streams and the Cache stream: FF E4 5C 39.
    seq:
      - id: magic
        contents: [0xff, 0xe4, 0x5c, 0x39]

  u2_prefixed_string:
    doc: |
      Length-prefixed ASCII string: u2 length, then `length` bytes, then a
      single null terminator.
    seq:
      - id: len_str
        type: u2
      - id: value
        type: str
        size: len_str
        encoding: ASCII
      - id: terminator
        contents: [0x00]

  u2_prefixed_string_no_term:
    doc: |
      Length-prefixed ASCII string without trailing null. Used inside some
      Cache cell-header records where a path string is followed directly by
      a subtype field.
    seq:
      - id: len_str
        type: u2
      - id: value
        type: str
        size: len_str
        encoding: ASCII
