meta:
  id: dsn_hierarchy
  title: OrCAD DSN — Views/SCHEMATIC1/Hierarchy/Hierarchy
  endian: le
  license: CC0-1.0
  imports:
    - dsn_common

doc: |
  The Hierarchy stream contains cross-page net connectivity. dsn2kicad
  uses it to decide which nets are global (appear on multiple pages →
  global labels in KiCad) versus local.

  Header begins with `B1` (0x42 0x31) followed by the schematic name
  (`SCHEMATIC1`). After the header, net records follow, each framed by
  the `FF E4 5C 39` marker. After all net-name records there are repeating
  `BH` blocks (~26 bytes each) carrying pin-to-net connectivity — these
  are not modeled here yet.

seq:
  - id: header
    type: hierarchy_header
  - id: nets
    type: net_record
    repeat: until
    repeat-until: _io.eof
    doc: |
      Marker-framed net records. The consumer in dsn2kicad
      (`parse_hierarchy_nets`) does not currently parse the trailing
      pin-to-net `BH` blocks; this schema also stops at the net-name
      records.

types:

  hierarchy_header:
    doc: |
      Header preamble. Starts with the bytes 'B1' followed by the
      schematic name (e.g. "SCHEMATIC1"). The exact layout after the
      schematic name has not been determined; consumers should
      seek to the first marker to begin reading net records.
    seq:
      - id: magic
        contents: [0x42, 0x31]
      - id: rest
        size-eos: false
        size: 0
        doc: |
          Placeholder. In practice, scan forward to the first
          `FF E4 5C 39` marker before parsing net records.

  net_record:
    doc: |
      Per `parse_hierarchy_nets` (in dsn2kicad.py), after the
      marker:
        +0  marker(4)
        +4  unknown(4)
        +8  net_id(4)
        +12 name_len(2)
        +14 name(name_len)
        +14+name_len  null(1)
    seq:
      - id: marker
        type: dsn_common::record_marker
      - id: unknown
        size: 4
      - id: net_id
        type: u4
      - id: name_len
        type: u2
      - id: name
        type: str
        size: name_len
        encoding: ASCII
      - id: terminator
        contents: [0x00]
