# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regenerate the committed fixtures used by the JavaScript tests.

    python3 tests/web/make_fixtures.py

The Node tests cannot import tests/dsn_fixtures.py, so the DSN they need is
built here and committed.  Output is deterministic; rerunning it on an
unchanged tree must leave git clean.
"""
import hashlib
import importlib.util
import io
import struct
import zipfile
from importlib.machinery import SourceFileLoader
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "fixtures"


def load_dsn_fixtures():
    path = str(HERE.parent / "dsn_fixtures.py")
    loader = SourceFileLoader("dsn_fixtures", path)
    spec = importlib.util.spec_from_loader("dsn_fixtures", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def minimal_dsn(fx):
    """One page with one wire, in a real OLE container."""
    page = fx.make_page(
        "Page1", modified=1617261986,
        nets={1: "N1"}, wires=[(1, 10, 10, 40, 10)],
    )
    return fx.make_ole({
        "Views/SCHEMATIC1/Pages/Page1": page,
        "Library": fx.make_library(["unused"]),
    })


FIXED_TIME = (1980, 1, 1, 0, 0, 0)
OLE_MAGIC = bytes.fromhex("d0cf11e0a1b11ae1")


def zip_bytes(members, *, compression=zipfile.ZIP_DEFLATED):
    """{name: bytes} -> ZIP, deterministic.  Python's zipfile is a different
    implementation from the fflate the page uses, which is the point."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression) as zf:
        for name, data in members.items():
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            info.compress_type = compression
            zf.writestr(info, data)
    return buf.getvalue()


class _Unseekable(io.RawIOBase):
    """A write-only stream zipfile cannot seek in, so it writes each member's
    sizes in a data descriptor after the data -- as macOS Archive Utility
    and other streaming writers do."""

    def __init__(self):
        self.data = bytearray()

    def writable(self):
        return True

    def write(self, b):
        self.data += b
        return len(b)


def zip_with_data_descriptors(members):
    sink = _Unseekable()
    with zipfile.ZipFile(sink, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in members.items():
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            with zf.open(info, "w") as f:
                f.write(data)
    return bytes(sink.data)


def _patch_headers(archive, name, *, flags_or=0, uncompressed_size=None):
    """Rewrite one member's local and central headers in place."""
    out = bytearray(archive)
    encoded = name.encode("utf-8")
    for signature, flags_at, size_at, name_len_at, name_at in (
        (b"PK\x03\x04", 6, 22, 26, 30),
        (b"PK\x01\x02", 8, 24, 28, 46),
    ):
        start = 0
        while (pos := out.find(signature, start)) >= 0:
            start = pos + 4
            name_len = struct.unpack_from("<H", out, pos + name_len_at)[0]
            if bytes(out[pos + name_at:pos + name_at + name_len]) != encoded:
                continue
            flags = struct.unpack_from("<H", out, pos + flags_at)[0]
            struct.pack_into("<H", out, pos + flags_at, flags | flags_or)
            if uncompressed_size is not None:
                struct.pack_into("<I", out, pos + size_at, uncompressed_size)
    return bytes(out)


def zip_fixtures(dsn):
    not_dsn = b"This is a text file, not an OrCAD design.\n"
    # A design whose bytes compress about a thousandfold.
    bomb = OLE_MAGIC + bytes(8 * 1024 * 1024)
    lying = OLE_MAGIC + bytes(2 * 1024 * 1024)
    # Incompressible, so its deflate stream spans many inflater chunks.
    noise = b"".join(
        hashlib.sha256(i.to_bytes(4, "little")).digest() for i in range(16384)
    )
    lying_noise = OLE_MAGIC + noise
    huge_neighbour = zip_bytes({"board.DSN": dsn, "huge.bin": b"x" * 64})
    # Corrupt huge.bin's deflate stream and claim 4 GB for it: reading the
    # archive succeeds only if that member is never inflated.
    pos = huge_neighbour.find(b"PK\x03\x04", 1)
    name_len, extra_len = struct.unpack_from("<HH", huge_neighbour, pos + 26)
    data_at = pos + 30 + name_len + extra_len
    corrupt = bytearray(huge_neighbour)
    corrupt[data_at:data_at + 4] = b"\xff\xff\xff\xff"
    huge_neighbour = _patch_headers(
        bytes(corrupt), "huge.bin", uncompressed_size=0xFFFFFFFF
    )
    return {
        "folder.zip": zip_bytes({
            "Design/": b"",
            "Design/board.DSN": dsn,
            "Design/notes.txt": not_dsn,
            "Design/.DS_Store": b"\x00\x00\x00\x01Bud1",
            "__MACOSX/Design/._board.DSN": b"\x00\x05\x16\x07",
        }),
        "stored.zip": zip_bytes(
            {"board.dsn": dsn}, compression=zipfile.ZIP_STORED
        ),
        "descriptors.zip": zip_with_data_descriptors({
            "board.DSN": dsn, "readme.txt": not_dsn,
        }),
        "utf8-name.zip": zip_bytes({"基板_ä.DSN": dsn}),
        "no-dsn.zip": zip_bytes({"readme.txt": not_dsn}),
        "two-dsn.zip": zip_bytes({"a.DSN": dsn, "sub/b.dsn": dsn}),
        "encrypted.zip": _patch_headers(
            zip_bytes({"board.DSN": dsn}), "board.DSN", flags_or=0x0001
        ),
        "not-ole.zip": zip_bytes({"board.DSN": not_dsn}),
        "bomb.zip": zip_bytes({"bomb.DSN": bomb}),
        "lying-size.zip": _patch_headers(
            zip_bytes({"lying.DSN": lying}), "lying.DSN", uncompressed_size=1000
        ),
        "lying-noise.zip": _patch_headers(
            zip_bytes({"noise.DSN": lying_noise}), "noise.DSN",
            uncompressed_size=1000,
        ),
        "huge-neighbour.zip": huge_neighbour,
    }


def main():
    fx = load_dsn_fixtures()
    OUT.mkdir(exist_ok=True)
    dsn = minimal_dsn(fx)
    (OUT / "minimal.DSN").write_bytes(dsn)
    for name, data in zip_fixtures(dsn).items():
        (OUT / name).write_bytes(data)


if __name__ == "__main__":
    main()
