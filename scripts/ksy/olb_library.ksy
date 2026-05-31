meta:
  id: olb_library
  title: OrCAD OLB Library stream
  endian: le
  license: CC0-1.0
  imports:
    - olb_common

doc: |
  The `Library` OLE stream inside an OrCAD .OLB file.

  Contains global metadata: file type, version, fonts, page settings,
  string table, and part aliases.  This stream is the same format in
  both .OLB (library) and .DSN (design) files.

  Known limitation: the string list length field is u4 in some files
  and u2 in others.  The Python parser uses a heuristic (value > 10000
  implies u2).  This schema uses u2 as the default.

seq:
  - id: introduction
    type: str
    size: 32
    encoding: ASCII
    doc: |
      Null-padded identifier string, e.g.
      "OrCAD Windows Library Editor" or "OrCAD Windows Design Editor".

  - id: version_major
    type: u2
  - id: version_minor
    type: u2
  - id: create_date
    type: u4
    doc: Windows FILETIME-style timestamp.
  - id: modify_date
    type: u4
  - id: unknown_zeros
    size: 4

  - id: text_font_count
    type: u2
    doc: |
      Number of font slots.  The first slot is implicit (default font),
      so (text_font_count - 1) LOGFONTA records follow.
  - id: text_fonts
    type: logfont
    repeat: expr
    repeat-expr: text_font_count - 1

  - id: some_data_count
    type: u2
    doc: Array of u2 values mapping font indices; purpose not fully known.
  - id: some_data
    type: u2
    repeat: expr
    repeat-expr: some_data_count

  - id: unknown_8_bytes
    size: 8

  - id: part_field_mapping
    type: len_string
    repeat: expr
    repeat-expr: 8
    doc: |
      Eight strings mapping OrCAD property field names
      (e.g. "PCB Footprint", "Value").

  - id: page_settings
    type: page_settings

  - id: str_lst_len
    type: u2
    doc: |
      Length of the string list.  CAVEAT: some files encode this as u4
      instead of u2.  If the parsed value seems wrong (strings don't
      decode), try re-reading with u4.
  - id: str_lst
    type: len_string
    repeat: expr
    repeat-expr: str_lst_len

  - id: alias_lst_len
    type: u2
  - id: alias_lst
    type: alias_entry
    repeat: expr
    repeat-expr: alias_lst_len

types:

  page_settings:
    doc: |
      Page / grid / border settings.  Many fields in the middle are
      unknown; they are consumed as opaque blocks.
    seq:
      - id: create_date_time
        type: u4
      - id: modify_date_time
        type: u4
      - id: unknown_16
        size: 16
        doc: Four unknown u4 values.
      - id: width
        type: u4
      - id: height
        type: u4
      - id: pin_to_pin
        type: u4
      - id: unknown_u16_a
        type: u2
      - id: horizontal_count
        type: u2
      - id: vertical_count
        type: u2
      - id: unknown_u16_b
        type: u2
      - id: horizontal_width
        type: u4
      - id: vertical_width
        type: u4
      - id: unknown_48
        size: 48
        doc: Twelve unknown u4 values.
      - id: horizontal_char
        type: u4
      - id: unknown_u32_a
        type: u4
      - id: horizontal_ascending
        type: u4
      - id: vertical_char
        type: u4
      - id: unknown_u32_b
        type: u4
      - id: vertical_ascending
        type: u4
      - id: is_metric
        type: u4
      - id: border_displayed
        type: u4
      - id: border_printed
        type: u4
      - id: grid_ref_displayed
        type: u4
      - id: grid_ref_printed
        type: u4
      - id: titleblock_displayed
        type: u4
      - id: titleblock_printed
        type: u4
      - id: ansi_grid_refs
        type: u4

  alias_entry:
    doc: An alias name mapped to its package name.
    seq:
      - id: alias_name
        type: len_string
      - id: package_name
        type: len_string
