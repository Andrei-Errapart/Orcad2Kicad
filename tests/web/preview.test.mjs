// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// web/preview.js: which sheets the preview lists, in which order, under which
// names.  The KiCanvas rendering itself is covered by the manual browser
// checklist.

import assert from "node:assert/strict";
import { test } from "node:test";
import { listSheets } from "../../web/preview.js";

const encode = (text) => new TextEncoder().encode(text);

function sheet(name, file) {
    return `\t(sheet
\t\t(property "Sheetname" "${name}"
\t\t\t(at 15 24.3 0)
\t\t)
\t\t(property "Sheetfile" "${file}"
\t\t\t(at 15 37.7 0)
\t\t)
\t)
`;
}

test("sheets follow the root's order and use their sheet names", () => {
    const files = new Map([
        ["board.kicad_sch", encode(
            "(kicad_sch\n"
            + sheet("02_POWER", "02_POWER.kicad_sch")
            + sheet("01_COVER", "01_COVER.kicad_sch")
            + ")\n",
        )],
        ["01_COVER.kicad_sch", encode("(kicad_sch)")],
        ["02_POWER.kicad_sch", encode("(kicad_sch)")],
        ["board.kicad_pro", encode("{}")],
        ["board.kicad_sym", encode("(kicad_symbol_lib)")],
    ]);
    assert.deepEqual(listSheets("board", files), [
        { file: "02_POWER.kicad_sch", title: "02_POWER" },
        { file: "01_COVER.kicad_sch", title: "01_COVER" },
    ]);
});

test("escaped quotes and backslashes in names are unescaped", () => {
    const files = new Map([
        ["b.kicad_sch", encode(sheet('A \\"quoted\\" \\\\ sheet', "A_sheet.kicad_sch"))],
        ["A_sheet.kicad_sch", encode("(kicad_sch)")],
    ]);
    assert.deepEqual(listSheets("b", files), [
        { file: "A_sheet.kicad_sch", title: 'A "quoted" \\ sheet' },
    ]);
});

test("schematics the root does not reference are still listed, last", () => {
    const files = new Map([
        ["b.kicad_sch", encode(sheet("ONE", "1.kicad_sch"))],
        ["1.kicad_sch", encode("")],
        ["z_orphan.kicad_sch", encode("")],
        ["a_orphan.kicad_sch", encode("")],
    ]);
    assert.deepEqual(listSheets("b", files).map((s) => s.file), [
        "1.kicad_sch", "a_orphan.kicad_sch", "z_orphan.kicad_sch",
    ]);
});

test("a sheet file the root names but the project lacks is skipped", () => {
    const files = new Map([
        ["b.kicad_sch", encode(sheet("GONE", "gone.kicad_sch"))],
    ]);
    assert.deepEqual(listSheets("b", files), []);
});
