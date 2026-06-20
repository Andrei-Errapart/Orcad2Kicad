# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests for the ZIP-backed olefile work-alike (scripts/ole_zip.py)."""
import io
import zipfile
from pathlib import Path

import pytest


def _zip_bytes(members):
    """Build a ZIP archive in memory from {member_name: bytes}."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)
    return buf.getvalue()


class TestZipOleFile:
    def test_openstream_roundtrips_bytes(self, ole_zip):
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes({"Cache": b"hello"})))
        assert z.openstream("Cache").read() == b"hello"

    def test_openstream_missing_raises_oserror(self, ole_zip):
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes({"Cache": b"x"})))
        with pytest.raises(OSError):
            z.openstream("Nope")

    def test_openstream_nested_path(self, ole_zip):
        members = {"Views/SCHEMATIC1/Pages/Page1": b"pagedata"}
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes(members)))
        assert z.openstream("Views/SCHEMATIC1/Pages/Page1").read() == b"pagedata"

    def test_listdir_returns_component_lists(self, ole_zip):
        members = {"Cache": b"a", "Views/SCHEMATIC1/Pages/Page1": b"b"}
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes(members)))
        listing = z.listdir(streams=True, storages=False)
        assert ["Cache"] in listing
        assert ["Views", "SCHEMATIC1", "Pages", "Page1"] in listing

    def test_listdir_feeds_get_page_streams(self, ole_zip, dsn2kicad):
        members = {
            "Views/SCHEMATIC1/Pages/Page1": b"b",
            "Views/SCHEMATIC1/Pages/Page2": b"c",
            "Cache": b"a",
        }
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes(members)))
        assert dsn2kicad.get_page_streams(z) == [
            "Views/SCHEMATIC1/Pages/Page1",
            "Views/SCHEMATIC1/Pages/Page2",
        ]

    def test_case_insensitive_openstream(self, ole_zip):
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes({"Cache": b"x"})))
        assert z.openstream("cache").read() == b"x"

    def test_exists(self, ole_zip):
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes({"Library": b"x"})))
        assert z.exists("Library") is True
        assert z.exists("library") is True
        assert z.exists("Missing") is False

    def test_directory_entries_skipped(self, ole_zip):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr("Views/", b"")
            zf.writestr("Views/SCHEMATIC1/Pages/Page1", b"b")
        z = ole_zip.ZipOleFile(io.BytesIO(buf.getvalue()))
        assert ["Views", ""] not in z.listdir(streams=True, storages=False)
        assert z.exists("Views/") is False

    def test_close_does_not_raise(self, ole_zip):
        z = ole_zip.ZipOleFile(io.BytesIO(_zip_bytes({"Cache": b"x"})))
        z.close()


class TestOpenDsnContainer:
    def test_zip_magic_returns_zipolefile(self, ole_zip):
        c = ole_zip.open_dsn_container(_zip_bytes({"Cache": b"x"}))
        assert isinstance(c, ole_zip.ZipOleFile)
        assert c.openstream("Cache").read() == b"x"

    def test_ole_magic_falls_back_to_olefile(self, ole_zip):
        # A committed real OLE compound document (OLB) as genuine OLE bytes.
        olb = Path(__file__).resolve().parent / "test_data_olb" / "0000.OLB"
        c = ole_zip.open_dsn_container(olb.read_bytes())
        assert not isinstance(c, ole_zip.ZipOleFile)
        assert c.exists("Library")
