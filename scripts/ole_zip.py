# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""ZIP-archive backend for reading OrCAD-style stream containers.

``olefile`` is read-only, so synthetic ``.DSN`` test fixtures cannot be
authored as OLE compound documents in Python.  This module lets the converter
ALSO accept a ZIP archive whose members are the OLE streams, e.g. a member
named ``Cache``, ``Library``, or ``Views/SCHEMATIC1/Pages/Page1``.  Python's
stdlib ``zipfile`` reads *and* writes, so tests build fixtures with no
third-party dependency.

:class:`ZipOleFile` duck-types the small ``olefile.OleFileIO`` surface the
converter depends on (``openstream``, ``listdir``, ``exists``, ``close``), and
:func:`open_dsn_container` sniffs the leading magic bytes to return either a
``ZipOleFile`` (ZIP) or a real ``olefile.OleFileIO`` (OLE).

Note: ``olefile`` matches stream names case-insensitively while ZIP members are
case-sensitive, so names are indexed lower-cased.  If a fixture stores two
members differing only in case, the last one wins (real OLE files never have
case-colliding sibling streams).
"""
import io
import zipfile

#: Leading bytes of a ZIP local file header.
ZIP_MAGIC = b"PK\x03\x04"
#: Leading bytes of an OLE2 compound document.
OLE_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


class ZipOleFile:
    """Read-only ``olefile.OleFileIO`` work-alike backed by a ZIP archive.

    Each OLE stream is a ZIP member whose name is the ``/``-joined stream path.
    Implements the ``olefile`` subset the converter uses: ``openstream``,
    ``listdir``, ``exists``, ``close``.
    """

    def __init__(self, fp):
        # fp: a path string or a file-like object (e.g. io.BytesIO) — the same
        # flexibility as olefile.OleFileIO(path) / OleFileIO(BytesIO(data)).
        self._zf = zipfile.ZipFile(fp, "r")
        # Case-insensitive index (lower-cased name -> real member name);
        # directory entries (trailing "/") are not streams and are skipped.
        self._index = {
            name.lower(): name
            for name in self._zf.namelist()
            if not name.endswith("/")
        }

    def _resolve(self, name):
        """Map an OLE stream path (string or component list) to a member name."""
        if isinstance(name, (list, tuple)):
            name = "/".join(name)
        return self._index.get(name.lower())

    def openstream(self, name):
        """Return a ``.read()``-able stream for ``name``.

        Raises ``OSError`` for a missing stream, matching ``olefile`` (whose
        ``_find`` raises ``IOError``, an alias of ``OSError`` in Python 3) so the
        converter's ``except`` guards degrade gracefully.
        """
        real = self._resolve(name)
        if real is None:
            raise OSError("file not found")
        return io.BytesIO(self._zf.read(real))

    def listdir(self, streams=True, storages=False):
        """Return stream paths as component lists, like ``olefile.listdir``.

        The only caller (``get_page_streams``) passes ``storages=False``; every
        ZIP member is a stream, so the ``storages`` flag has no effect here.
        """
        if not streams:
            return []
        return [real.split("/") for real in self._index.values()]

    def exists(self, name):
        """Return whether ``name`` resolves to a stream member."""
        return self._resolve(name) is not None

    def close(self):
        self._zf.close()


def open_dsn_container(data):
    """Return an ``olefile``-compatible reader for ``data`` (raw file bytes).

    Sniffs the leading magic bytes: a ZIP archive yields a :class:`ZipOleFile`;
    anything else falls through to ``olefile.OleFileIO`` (which raises its own
    error for genuinely malformed input).
    """
    if data[:4] == ZIP_MAGIC:
        return ZipOleFile(io.BytesIO(data))
    import olefile
    return olefile.OleFileIO(io.BytesIO(data))
