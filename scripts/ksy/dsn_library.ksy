meta:
  id: dsn_library
  title: OrCAD DSN — Library stream
  endian: le
  license: CC0-1.0
  imports:
    - dsn_common

doc: |
  The `Library` stream of an OrCAD Capture 16.x .DSN file. Carries the
  project's font/style table plus the title-block field values
  (Title, Document Number, Rev — see also `Views/SCHEMATIC1/Pages/*`).

  Two regions:

    1. Header (32 bytes): the ASCII string `OrCAD Windows Design` (space
       padded, null terminated), then 2 bytes of format version
       (`03 00 02 00`), then a 4-byte Unix `time_t` mtime, then 8 bytes
       of zeros.

    2. Style records (60 bytes each, packed back-to-back) followed by
       the title-block field run (packed u16-length-prefixed strings).

  This sketch covers the font/style record structure. The title-block
  field run is parsed by `scripts/dsn2kicad`'s `parse_title_block` using
  a `SCHEMATIC1`-anchor heuristic; see ORCAD_FILE_FORMAT.md.

seq:
  - id: program_name
    size: 32
    doc: |
      The ASCII string "OrCAD Windows Design" padded to 32 bytes with
      spaces and a null terminator.
  - id: version_word
    type: u4
    doc: Constant `0x00020003` across all observed DSNs.
  - id: timestamp
    type: u4
    doc: Unix `time_t` (seconds since 1970-01-01 UTC) of last edit.
  - id: zeros1
    size: 8
  - id: records
    type: style_record
    repeat: until
    repeat-until: _io.eof
    doc: |
      Style records, followed by the title-block string run.
      Consumers that only want the font/style data should stop reading
      when a `style_record` parse fails (typically because the bytes
      stop matching the negative-tag pattern and the title-block
      strings begin).

types:

  style_record:
    doc: |
      A 60-byte font/style record. All observed records carry a font
      face name; no separate line-style or fill-style records have been
      identified in the Library stream.

      Layout:
        +0   i32   tag           negative value (see `style_tag` enum)
        +4   u32   index         per-tag sub-index
        +8   i32   escapement    LOGFONT lfEscapement (tenths of degrees)
                                   0 = horizontal, 2700 = vertical
        +12  4B   reserved
        +16  u32   weight        GDI LOGFONT lfWeight
                                   400 (0x190) = Normal
                                   700 (0x2BC) = Bold
        +20  u32   italic        LOGFONT-style italic flag
                                   0x00000000 = upright
                                   0x000000FF = italic
        +24  u8    pitch_family  LOGFONT lfPitchAndFamily
        +25  u8    charset       LOGFONT lfCharSet
        +26  u8    flag          typically 0x01
        +27  u8    quality       LOGFONT lfQuality
        +28  6B    face name (null-terminated ASCII, padded to 6 bytes
                   on average — actually a packed null-term string).
                   Common: "Arial", "Courier New", "Arial Narrow".
        +34  u32   ext_word      Originally suspected to encode color,
                                  but rules out: records 33 (bold-italic
                                  Arial, green title) and 35 (bold Arial,
                                  red CAUTION) both have the SAME value
                                  here (`0x0194d2f6`) despite rendering
                                  in different colors. May be a small
                                  point-size or style-attribute word,
                                  or an offset/handle into a Capture-
                                  internal palette.
                                  For records whose face name is longer
                                  than 5 chars (e.g. "Courier New",
                                  "Arial Narrow"), this offset holds
                                  spillover bytes of the name itself.
        +38  16B   reserved / face name continuation / usage strings
        +56  u8    has_ext_flag  Set (e.g. 0x07) when `ext_word` is
                                  meaningful, zero on plain styles.
        +57  3B    padding

      Page-stream text records reference these by `style_id` (1-based,
      so `style_records[style_id - 1]` is the entry for a given text).
      Confirmed on one cover page: every distinct `style_id`
      maps to a Library record whose weight/italic match the visible
      rendering (Bold for `INDEX`, Bold+Italic for the green title,
      Bold for the CAUTION body paragraphs).
    seq:
      - id: tag
        type: s4
        enum: style_tag
      - id: index
        type: u4
      - id: escapement
        type: s4
        doc: |
          LOGFONT lfEscapement: text rotation in tenths of degrees,
          counterclockwise. 0 = horizontal, 2700 = vertical (top-to-bottom).
      - id: reserved1
        size: 4
      - id: weight
        type: u4
        enum: gdi_weight
      - id: italic
        type: u4
      - id: pitch_family
        type: u1
      - id: charset
        type: u1
      - id: flag
        type: u1
      - id: quality
        type: u1
      - id: face_block
        size: 6
        doc: Null-terminated ASCII face name, possibly padded.
      - id: ext_word
        type: u4
        doc: |
          Originally suspected to encode color and/or rendered point
          size; both ruled out by comparison.

          - Color: records 33 (green bold-italic title) and 35 (red
            bold CAUTION) both have `0x0194d2f6` here despite
            rendering in different colors.
          - Size: a full byte-diff of records 33 vs 35 shows only the
            `tag` byte and the `italic` flag differ — there is no
            color/size byte hidden anywhere in the 60-byte record.

          For records whose face name is longer than 5 characters
          (e.g. "Courier New", "Arial Narrow"), this offset is part
          of the face-name string spillover and isn't a separate
          field at all.

          As of the latest investigation, font color has NOT been
          located in this stream. It may live in bytes we haven't
          decoded, or it may be applied by Capture from preferences
          stored elsewhere — we don't yet know which.
      - id: reserved2
        size: 16
      - id: has_ext_flag
        type: u1
      - id: padding
        size: 3

enums:

  style_tag:
    -7:  font_ref_a
    -8:  font_ref_b
    -9:  font_face_main
    -10: font_face_alt
    -11: font_binding_body
    -12: file_ref
    -13: font_binding_label
    -16: font_binding_aux1
    -20: font_binding_aux2
    -21: font_binding_aux3
    -24: font_binding_aux4
    -27: path_ref
    -29: font_binding_aux5
    -48: font_binding_extra1
    -64: font_binding_extra2
    doc: |
      Tag values observed in the current larger and smaller board DSNs. The exact
      semantic of each tag is not fully decoded; names here are
      placeholders. -12 and -27 records carry filesystem paths in
      their `rest` payload, not font face names — these likely
      record references to OLB libraries from when the project was
      saved.

  gdi_weight:
    0:    dontcare       # not used in observed records
    100:  thin
    200:  extralight
    300:  light
    400:  normal         # 0x190 — vast majority of records
    500:  medium
    600:  semibold
    700:  bold           # 0x2BC — observed in cover-page title and 5 others
    800:  extrabold
    900:  heavy
