// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The conversion worker.  Everything that parses the visitor's file runs
// here -- ZIP extraction and the converter -- so the page stays responsive
// and terminating this worker stops either.
//
// app.js starts it from a blob: URL that imports this module, so that the
// worker inherits the page's Content-Security-Policy; see app.js.
//
// Messages in:  {type: "warm", wasmUrl}
//               {type: "convert", id, wasmUrl, fileName, bytes, options}
// Messages out: {id, stage: "converting"}
//               {id, ok: true, projectName, member, files: [[name, bytes]...]}
//               {id, ok: false, message}

import { prepareInput } from "./input.js";
import { convert } from "./runner.js";

let compiled = null;

function compileOnce(wasmUrl) {
    if (!compiled) {
        compiled = (async () => {
            const response = await fetch(wasmUrl);
            if (!response.ok) {
                throw new Error(`the converter could not be loaded (HTTP ${response.status})`);
            }
            return WebAssembly.compile(await response.arrayBuffer());
        })();
        // A failed load is retried by the next request.
        compiled.catch(() => {
            compiled = null;
        });
    }
    return compiled;
}

self.addEventListener("message", async ({ data }) => {
    if (data.type === "warm") {
        compileOnce(data.wasmUrl).catch(() => {});
        return;
    }
    const { id, wasmUrl, fileName, bytes, options } = data;
    try {
        const module = compileOnce(wasmUrl);
        const input = prepareInput(new Uint8Array(bytes), fileName);
        if (!input.ok) {
            self.postMessage({ id, ok: false, message: input.message });
            return;
        }
        self.postMessage({ id, stage: "converting" });
        const result = await convert(await module, input.dsnBytes, input.projectName, options);
        if (!result.ok) {
            self.postMessage({ id, ok: false, message: result.message });
            return;
        }
        const files = [...result.files];
        const buffers = [...new Set(files.map(([, data]) => data.buffer))];
        self.postMessage(
            { id, ok: true, projectName: input.projectName, member: input.member, files },
            buffers,
        );
    } catch (error) {
        self.postMessage({ id, ok: false, message: `Conversion failed: ${error.message}.` });
    }
});
