// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// web/input.js: from the bytes a visitor supplied to the DSN the converter
// gets.  Fixtures are written by tests/web/make_fixtures.py with Python's
// zipfile, an implementation independent of the page's.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
    INFLATE_CHUNK, MAX_INPUT_BYTES, prepareInput, projectNameFrom,
} from "../../web/input.js";

const fixture = (name) =>
    new Uint8Array(readFileSync(new URL(`fixtures/${name}`, import.meta.url)));
const DSN = fixture("minimal.DSN");

// The spec's chunk size, written out rather than imported so that a change to
// the module's constant fails here.  DEFLATE expands at most about 1032:1, so
// one pushed chunk can overshoot the limit by at most MAX_OVERSHOOT.
const CHUNK = 16 * 1024;
const MAX_OVERSHOOT = CHUNK * 1032;

function assertDsn(result, projectName) {
    assert.equal(result.ok, true, result.message);
    assert.equal(result.projectName, projectName);
    assert.deepEqual(result.dsnBytes, DSN);
}

test("a DSN passes through", () => {
    assertDsn(prepareInput(DSN, "board.DSN"), "board");
});

test("the container is recognised by content, not by extension", () => {
    assertDsn(prepareInput(DSN, "board.txt"), "board");
    assertDsn(prepareInput(fixture("folder.zip"), "design.DSN"), "board");
});

test("bytes that are neither a DSN nor a ZIP are refused", () => {
    const result = prepareInput(new TextEncoder().encode("hello"), "x.DSN");
    assert.equal(result.ok, false);
    assert.match(result.message, /not an OrCAD .DSN file or a ZIP archive/);
});

test("a DSN over the limit is refused", () => {
    const result = prepareInput(DSN, "board.DSN", { limit: DSN.length - 1 });
    assert.equal(result.ok, false);
    assert.match(result.message, /larger than/);
});

test("a zipped design folder yields its one DSN", () => {
    // Directories, notes, .DS_Store and __MACOSX/._board.DSN are ignored.
    const result = prepareInput(fixture("folder.zip"), "Design.zip");
    assertDsn(result, "board");
    assert.equal(result.member, "Design/board.DSN");
});

test("a stored member with a lower-case extension is found", () => {
    assertDsn(prepareInput(fixture("stored.zip"), "a.zip"), "board");
});

test("an archive written with data descriptors is read", () => {
    assertDsn(prepareInput(fixture("descriptors.zip"), "a.zip"), "board");
});

test("a UTF-8 member name becomes the project name", () => {
    assertDsn(prepareInput(fixture("utf8-name.zip"), "a.zip"), "基板_ä");
});

test("an archive without a DSN is refused", () => {
    const result = prepareInput(fixture("no-dsn.zip"), "a.zip");
    assert.equal(result.ok, false);
    assert.match(result.message, /no \.DSN file/);
});

test("an archive with several DSNs is refused, naming them", () => {
    const result = prepareInput(fixture("two-dsn.zip"), "a.zip");
    assert.equal(result.ok, false);
    assert.match(result.message, /a\.DSN/);
    assert.match(result.message, /sub\/b\.dsn/);
});

test("an encrypted member is refused", () => {
    const result = prepareInput(fixture("encrypted.zip"), "a.zip");
    assert.equal(result.ok, false);
    assert.match(result.message, /encrypted/);
});

test("a zipped file that is not a DSN is refused", () => {
    const result = prepareInput(fixture("not-ole.zip"), "a.zip");
    assert.equal(result.ok, false);
    assert.match(result.message, /not an OrCAD \.DSN/);
});

test("a large neighbour of the DSN is never inflated", () => {
    // huge.bin claims 4 GB and its deflate stream is corrupt.
    assertDsn(prepareInput(fixture("huge-neighbour.zip"), "a.zip"), "board");
});

test("a member that inflates past the limit is stopped near the limit", () => {
    const limit = 1024 * 1024;
    const result = prepareInput(fixture("bomb.zip"), "a.zip", { limit });
    assert.equal(result.ok, false);
    assert.match(result.message, /larger than/);
    // The 8 MB member was declared honestly, so it is refused before
    // anything is inflated.
    assert.equal(result.inflatedBytes, 0);
});

test("a member larger than it declares is stopped near the limit", () => {
    // Declares 1000 bytes, really inflates to 2 MB.
    const limit = 64 * 1024;
    const result = prepareInput(fixture("lying-size.zip"), "a.zip", { limit });
    assert.equal(result.ok, false);
    assert.match(result.message, /larger than/);
    assert.ok(result.inflatedBytes > limit);
    assert.ok(result.inflatedBytes <= limit + MAX_OVERSHOOT, `${result.inflatedBytes}`);
});

test("the inflater is fed in chunks, so it stops within one chunk", () => {
    // 512 KB of incompressible data declaring 1000 bytes: fed whole, it
    // would all be inflated before any check could run.
    const limit = 64 * 1024;
    const result = prepareInput(fixture("lying-noise.zip"), "a.zip", { limit });
    assert.equal(result.ok, false);
    assert.ok(result.inflatedBytes > limit);
    assert.ok(
        result.inflatedBytes <= limit + 2 * CHUNK, `${result.inflatedBytes}`,
    );
});

test("a truncated archive is refused, not thrown", () => {
    const zip = fixture("folder.zip");
    const result = prepareInput(zip.subarray(0, zip.length - 30), "a.zip");
    assert.equal(result.ok, false);
});

test("the limits are the spec's: 100 MB, inflated 16 KiB at a time", () => {
    assert.equal(MAX_INPUT_BYTES, 100 * 1024 * 1024);
    assert.equal(INFLATE_CHUNK, CHUNK);
});

test("project names are made safe for file names", () => {
    assert.equal(projectNameFrom("board.DSN"), "board");
    assert.equal(projectNameFrom("Board.v2.dsn"), "Board.v2");
    assert.equal(projectNameFrom("dir/sub\\board.DSN"), "board");
    assert.equal(projectNameFrom('a<b>c:d"e|f?g*h.DSN'), "a_b_c_d_e_f_g_h");
    assert.equal(projectNameFrom("tab\there.DSN"), "tab_here");
    assert.equal(projectNameFrom(".DSN"), "design");
    assert.equal(projectNameFrom("  spaced .DSN"), "spaced");
    assert.equal(projectNameFrom("基板.DSN"), "基板");
});
