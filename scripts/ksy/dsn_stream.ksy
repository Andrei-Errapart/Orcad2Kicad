meta:
  id: dsn_stream
  title: OrCAD DSN — DsnStream
  endian: le
  license: CC0-1.0
  imports:
    - dsn_common

doc: |
  The top-level `DsnStream` of an OrCAD Capture .DSN file. Carries the
  install/license/version metadata as a JSON document.

  The stream is in two parts:

    1. A **20-byte prefix** (purpose largely undecoded — three constants
       and one varying word).
    2. A **marker-framed record** starting at offset 0x14, identical in
       shape to record envelopes seen elsewhere in DSN: marker, length,
       length-duplicate, two `u4` constants (0x07 and 0x06), then the
       JSON payload of `record_length - 12` bytes.

  Total stream sizes observed:
    - 157 bytes (CPU board, 117-byte JSON)
    - 146 bytes (sub-boards, 106-byte JSON)

  No trailing slack: `40 + json_len == total stream size` exactly.

  History: an earlier sketch claimed a "32-byte opaque header" before the
  JSON. That was wrong. A subsequent sketch claimed "40-byte fixed
  header then raw JSON". That was also wrong — the JSON sits inside a
  record envelope, not directly after a fixed header.

seq:
  - id: prefix
    type: prefix_block
    doc: 20-byte preamble before the marker-framed record.

  - id: record
    type: framed_record
    doc: Marker-framed record containing two constants and the JSON.

types:

  prefix_block:
    seq:
      - id: tag_and_payload_size
        type: u4
        doc: |
          Low byte = `0x04` (record-type tag — same value across all
          three DSNs). Byte 1 tracks the stream size:
            - CPU board (157-byte stream):     byte1 = 0x94 = 148  (157 - 9)
            - sub-boards (146-byte stream):    byte1 = 0x89 = 137  (146 - 9)
          Consistent with `byte1 == stream_size - 9` across all observed
          DSNs. Upper two bytes are zero.
      - id: zero_a
        contents: [0x00, 0x00, 0x00, 0x00]
      - id: version_word
        contents: [0x00, 0x04, 0x01, 0x00]
        doc: |
          Constant `0x00010400` across all three observed DSNs. Suspected
          OrCAD Capture format version tag.
      - id: type_word
        contents: [0x15, 0x00, 0x00, 0x00]
        doc: |
          Constant `0x00000015` (= 21 decimal). Suspected record-type
          identifier for the DsnStream's metadata record.
      - id: variant
        type: u4
        doc: |
          The one prefix field that differs between DSNs. Observed:
            0x00000ddd (CPU board)
            0x000000bb (eMMC sub-board)
            0x0000015c (microSD sub-board)
          Likely an identifier (UID/serial/CRC) — no obvious correlation
          with size, JSON length, or board content.

  framed_record:
    seq:
      - id: marker
        type: dsn_common::record_marker
        doc: Standard DSN record marker `FF E4 5C 39`.
      - id: rec_len
        type: u4
        doc: |
          Length of the record from immediately after this field through
          end-of-stream. Equivalent to: total_stream_size - 28. Covers
          `rec_len_dup`, the two `const_*` words, the JSON, and any
          trailing nul padding. Observed: 129 (CPU), 118 (sub-boards).
          Verified: offset(rec_len) + 4 + rec_len == stream size exactly
          across all three observed DSNs.
      - id: rec_len_dup
        type: u4
        doc: |
          Same value as `rec_len`. The duplicate-length idiom appears in
          OLE-container records and may distinguish logical vs on-disk
          length when compression is used. In DsnStream they always
          match.
      - id: const_07
        contents: [0x07, 0x00, 0x00, 0x00]
        doc: Constant `0x00000007`. Constant across all observed DSNs.
      - id: const_06
        contents: [0x06, 0x00, 0x00, 0x00]
        doc: Constant `0x00000006`. Constant across all observed DSNs.
      - id: json_and_padding
        size: rec_len - 12
        doc: |
          JSON document followed by zero-or-more trailing nul bytes of
          padding inside the record. Application code should strip
          trailing 0x00 bytes to get the canonical JSON document. Length
          is `rec_len - 12` bytes (subtracting `rec_len_dup` + the two
          `const_*` u4 fields).

          Example payloads (after stripping trailing 0x00):

          CPU board (Concept HDL Studio export):
            {"InstallMode":"0","License":"Concept_HDL_studio",
             "InstalledVersionBase":"17.4-2019","InstalledVersionISR":"S014"}

          Sub-boards (Capture export):
            {"InstallMode":"0","License":"Capture",
             "InstalledVersionBase":"17.4-2019","InstalledVersionISR":"S005"}

          Note `License` differs between project types
          (Concept_HDL_studio vs Capture) but the version base is
          identical.

          Observed padding lengths: 4 bytes (CPU) and 4 bytes
          (sub-boards) — the slack inside the record itself, not OLE
          sector slack.
