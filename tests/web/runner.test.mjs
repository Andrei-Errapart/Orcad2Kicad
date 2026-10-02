// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// node --test tests/web/*.test.mjs
//
// The converter contract of web/runner.js.  Byte-for-byte agreement with the
// native CLI is checked by tests/test_wasm_parity.py; this covers what the
// page relies on beyond that.  Needs web/dsn2kicad.wasm (scripts/build-wasm).

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { convert, optionArgs } from "../../web/runner.js";

const WASM = fileURLToPath(new URL("../../web/dsn2kicad.wasm", import.meta.url));
const FIXTURE = fileURLToPath(new URL("fixtures/minimal.DSN", import.meta.url));

const haveWasm = existsSync(WASM);
const wasmSkip = haveWasm || process.env.ORCAD2KICAD_REQUIRE_WASM === "1"
    ? false
    : "web/dsn2kicad.wasm not built (scripts/build-wasm)";
const compiled = haveWasm ? WebAssembly.compile(readFileSync(WASM)) : null;

test("options map to the CLI's flags", () => {
    assert.deepEqual(optionArgs({}), []);
    assert.deepEqual(
        optionArgs({
            kicadPower: true, kicadRc: true, kicadFonts: true,
            noWorksheet: true, sourceEncoding: "cp932",
        }),
        [
            "--kicad-power", "--kicad-rc", "--kicad-fonts", "--no-worksheet",
            "--source-encoding=cp932",
        ],
    );
    assert.deepEqual(optionArgs({ kicadPower: false, sourceEncoding: "" }), []);
});

test("a DSN converts to a complete project", { skip: wasmSkip }, async () => {
    const result = await convert(await compiled, readFileSync(FIXTURE), "board", {});
    assert.equal(result.ok, true, result.message);
    assert.deepEqual([...result.files.keys()].sort(), [
        "Page1.kicad_sch", "board.kicad_pro", "board.kicad_sch",
        "board.kicad_sym", "board.kicad_wks", "sym-lib-table",
    ]);
    for (const data of result.files.values()) {
        assert.ok(data instanceof Uint8Array);
    }
});

test("an option reaches the converter", { skip: wasmSkip }, async () => {
    const result = await convert(
        await compiled, readFileSync(FIXTURE), "board", { noWorksheet: true },
    );
    assert.equal(result.ok, true, result.message);
    assert.equal(result.files.has("board.kicad_wks"), false);
});

test("a non-ASCII project name round-trips", { skip: wasmSkip }, async () => {
    // The shim once sized argv in UTF-16 units while writing UTF-8 bytes.
    const name = "基板_ä_" + "長".repeat(40);
    const result = await convert(await compiled, readFileSync(FIXTURE), name, {});
    assert.equal(result.ok, true, result.message);
    assert.ok(result.files.has(`${name}.kicad_sch`));
    const root = new TextDecoder().decode(result.files.get(`${name}.kicad_sch`));
    assert.match(root, new RegExp(name));
});

test("bytes that are not a DSN return the converter's message", { skip: wasmSkip }, async () => {
    const result = await convert(
        await compiled, new TextEncoder().encode("not a dsn"), "junk", {},
    );
    assert.equal(result.ok, false);
    assert.match(result.message, /not an OLE compound document/);
});

test("each conversion gets a fresh instance", { skip: wasmSkip }, async () => {
    const module = await compiled;
    const first = await convert(module, readFileSync(FIXTURE), "one", {});
    const second = await convert(module, readFileSync(FIXTURE), "two", {});
    assert.equal(first.ok && second.ok, true);
    assert.equal(second.files.has("one.kicad_sch"), false);
    assert.ok(second.files.has("two.kicad_sch"));
});
