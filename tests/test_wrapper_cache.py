# Copyright (C) 2026 Andrei Errapart
# SPDX-License-Identifier: GPL-2.0-or-later
"""The wrapper must rebuild when any module changes, not just the entry file.

Before the split the cache key hashed only dsn2kicad.hs, so editing an
imported module would silently keep serving a stale binary.

The probe runs against a *copy* of the scripts tree under tmp_path.  Mutating
the checked-out source would leave the repository dirty if the test were
killed, and a concurrent build could observe the probe.
"""
import os
import shutil
import subprocess
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"


def _sandbox(tmp_path):
    """A standalone copy of the wrapper, Main and the module tree."""
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    shutil.copy2(SCRIPTS_DIR / "dsn2kicad", scripts / "dsn2kicad")
    shutil.copy2(SCRIPTS_DIR / "dsn2kicad.hs", scripts / "dsn2kicad.hs")
    shutil.copytree(SCRIPTS_DIR / "hs", scripts / "hs")
    return scripts


def _cached_binaries(scripts, cache_dir):
    """Run the wrapper and report which binaries the cache now holds."""
    env = dict(os.environ, ORCAD2KICAD_HS_CACHE=str(cache_dir))
    subprocess.run([str(scripts / "dsn2kicad")], env=env,
                   capture_output=True, timeout=900)
    return sorted(p.name for p in Path(cache_dir).glob("dsn2kicad-*"))


def test_touching_an_imported_module_changes_the_cache_key(tmp_path):
    scripts = _sandbox(tmp_path)
    cache = tmp_path / "cache"

    before = _cached_binaries(scripts, cache)
    assert before, "wrapper produced no cached binary"

    module = scripts / "hs" / "Text" / "MetricsTables.hs"
    module.write_bytes(module.read_bytes() + b"\n-- cache key probe\n")
    after = _cached_binaries(scripts, cache)

    assert set(after) - set(before), (
        "editing an imported module did not produce a new cache key; "
        "the wrapper is still hashing only the entry file"
    )
