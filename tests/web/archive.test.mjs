// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// web/archive.js: the converted project as the ZIP the visitor downloads.
// Also read back with Python's zipfile where available, so the check does not
// rest only on the library that wrote it.  (Not macOS's bundled Info-ZIP
// unzip: it ignores the UTF-8 name flag and mangles non-ASCII names.)

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { unzipSync } from "../../web/vendor/fflate/fflate.js";
import { archiveName, buildProjectArchive } from "../../web/archive.js";

const encode = (text) => new TextEncoder().encode(text);
const files = new Map([
    ["board.kicad_pro", encode("{}\n")],
    ["board.kicad_sch", encode("(kicad_sch)\n")],
    ["基板_ä.kicad_sch", encode("(kicad_sch 基板)\n")],
]);

test("the archive is named after the project", () => {
    assert.equal(archiveName("board"), "board_kicad.zip");
});

test("every file sits in one top-level directory", () => {
    const entries = unzipSync(buildProjectArchive("board", files));
    assert.deepEqual(Object.keys(entries).sort(), [
        "board_kicad/board.kicad_pro",
        "board_kicad/board.kicad_sch",
        "board_kicad/基板_ä.kicad_sch",
    ]);
    for (const [name, data] of files) {
        assert.deepEqual(entries[`board_kicad/${name}`], data);
    }
});

let havePython = true;
try {
    execFileSync("python3", ["--version"], { stdio: "ignore" });
} catch {
    havePython = false;
}

test("an independent reader extracts it intact", { skip: !havePython && "no python3" }, () => {
    const dir = mkdtempSync(join(tmpdir(), "archive-test-"));
    const zip = join(dir, "out.zip");
    writeFileSync(zip, buildProjectArchive("board", files));
    execFileSync("python3", ["-m", "zipfile", "-e", zip, dir]);
    const extracted = readdirSync(join(dir, "board_kicad")).sort();
    assert.deepEqual(extracted, [...files.keys()].sort());
    for (const [name, data] of files) {
        assert.deepEqual(
            new Uint8Array(readFileSync(join(dir, "board_kicad", name))), data,
        );
    }
});
