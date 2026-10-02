// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Test helper: convert one .DSN through web/runner.js -- the code the page
// runs in its worker -- and write the files to a directory, so that
// tests/test_wasm_parity.py can compare it with the native and wasmtime runs.
//
//   node tests/web/run_converter.mjs <dsn2kicad.wasm> <file.DSN> <out_dir> [flag...]
//
// Flags are the CLI's; they are mapped back to the page's option object.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { convert } from "../../web/runner.js";

const [wasmPath, dsnPath, outDir, ...flags] = process.argv.slice(2);

const options = {};
for (const flag of flags) {
    if (flag === "--kicad-power") options.kicadPower = true;
    else if (flag === "--kicad-rc") options.kicadRc = true;
    else if (flag === "--kicad-fonts") options.kicadFonts = true;
    else if (flag === "--no-worksheet") options.noWorksheet = true;
    else if (flag.startsWith("--source-encoding=")) {
        options.sourceEncoding = flag.slice("--source-encoding=".length);
    } else {
        console.error(`run_converter: unknown flag ${flag}`);
        process.exit(2);
    }
}

const module = await WebAssembly.compile(readFileSync(wasmPath));
const projectName = basename(dsnPath, extname(dsnPath));
const result = await convert(module, readFileSync(dsnPath), projectName, options);
if (!result.ok) {
    console.error(result.message);
    process.exit(1);
}
mkdirSync(outDir, { recursive: true });
for (const [name, data] of result.files) {
    writeFileSync(join(outDir, name), data);
}
