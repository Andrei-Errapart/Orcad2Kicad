// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Run the converter -- scripts/dsn2kicad.hs compiled for wasm32-wasi by
// scripts/build-wasm -- exactly as the CLI runs: the DSN sits in an in-memory
// /in directory, the module is started with CLI arguments, and the project is
// read back from an in-memory /out.  No DOM API is used, so the same code runs
// in the page's worker and under Node in the tests.

import {
    ConsoleStdout, File, OpenFile, PreopenDirectory, WASI,
} from "./vendor/browser_wasi_shim/index.js";

const FLAGS = [
    ["kicadPower", "--kicad-power"],
    ["kicadRc", "--kicad-rc"],
    ["kicadFonts", "--kicad-fonts"],
    ["noWorksheet", "--no-worksheet"],
];

/** The CLI flags for the page's option object. */
export function optionArgs(options) {
    const args = FLAGS.filter(([key]) => options[key]).map(([, flag]) => flag);
    if (options.sourceEncoding) {
        args.push(`--source-encoding=${options.sourceEncoding}`);
    }
    return args;
}

/**
 * Convert one DSN.
 *
 * @param {WebAssembly.Module} module  the compiled converter
 * @param {Uint8Array} dsnBytes
 * @param {string} projectName  becomes the KiCad project's name, as the
 *     DSN's base name does on the command line
 * @param {object} options  see optionArgs
 * @returns {Promise<{ok: true, files: Map<string, Uint8Array>}
 *                 | {ok: false, message: string}>}
 */
export async function convert(module, dsnBytes, projectName, options) {
    const inputName = `${projectName}.DSN`;
    const output = new PreopenDirectory("/out", new Map());
    const stderr = [];
    const wasi = new WASI(
        // The input path starts with "/in/", so it can never be read as a
        // flag; "--" is not passed.
        ["dsn2kicad", ...optionArgs(options), `/in/${inputName}`, "/out"],
        [],
        [
            new OpenFile(new File([])),
            ConsoleStdout.lineBuffered(() => {}),
            ConsoleStdout.lineBuffered((line) => stderr.push(line)),
            new PreopenDirectory("/in", new Map([
                [inputName, new File(dsnBytes, { readonly: true })],
            ])),
            output,
        ],
    );

    // A fresh instance, and so fresh memory, for every conversion.
    const instance = await WebAssembly.instantiate(module, {
        wasi_snapshot_preview1: wasi.wasiImport,
    });
    let exitCode;
    try {
        exitCode = wasi.start(instance);
    } catch (error) {
        return {
            ok: false,
            message: `The converter stopped unexpectedly (${error.message}).`,
        };
    }
    if (exitCode !== 0) {
        return {
            ok: false,
            message: stderr.join("\n") || `The converter failed (exit code ${exitCode}).`,
        };
    }

    const files = new Map();
    for (const name of [...output.dir.contents.keys()].sort()) {
        files.set(name, output.dir.contents.get(name).data);
    }
    return { ok: true, files };
}
