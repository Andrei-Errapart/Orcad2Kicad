// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Page wiring: take a file from drop, picker or paste, hand its bytes to the
// conversion worker, show the result and offer the download.  The visitor's
// file is never sent anywhere: it goes from the browser's File API to the
// worker and back as converted files, all in this tab.

import { archiveName, buildProjectArchive } from "./archive.js";
import { MAX_INPUT_BYTES } from "./input.js";
import { showPreview } from "./preview.js";

const $ = (id) => document.getElementById(id);
const ui = {
    drop: $("drop"),
    picker: $("picker"),
    options: $("options"),
    status: $("status"),
    statusText: $("status-text"),
    cancel: $("cancel"),
    result: $("result"),
    resultName: $("result-name"),
    resultDetail: $("result-detail"),
    download: $("download"),
    sheets: $("sheets"),
    viewer: $("viewer"),
    previewNote: $("preview-note"),
    version: $("version"),
};

let version = "development build";
let wasmUrl = new URL("dsn2kicad.wasm", import.meta.url).href;
let worker = null;
let current = null; // {name, bytes} of the file last chosen
let result = null; // {projectName, files} of the last successful conversion
let requestId = 0;
let inFlight = false; // a conversion request is with the worker

// A worker loaded from a network URL gets its policy from that script's own
// response headers -- and GitHub Pages sends none we control -- so it would
// run without the page's Content-Security-Policy.  A worker loaded from a
// blob: URL inherits the page's policy instead; its one line imports the
// real module from this origin.
function startWorker() {
    const moduleUrl = new URL("worker.js", import.meta.url).href;
    const bootstrap = new Blob(
        [`import ${JSON.stringify(moduleUrl)};\n`],
        { type: "text/javascript" },
    );
    worker = new Worker(URL.createObjectURL(bootstrap), { type: "module" });
    worker.addEventListener("message", onWorkerMessage);
    worker.addEventListener("error", (event) => {
        event.preventDefault();
        inFlight = false;
        showError(`The converter could not start (${event.message || "worker error"}).`);
    });
    worker.postMessage({ type: "warm", wasmUrl });
}

function restartWorker() {
    worker?.terminate();
    startWorker();
}

function setBusy(text) {
    ui.status.dataset.state = "busy";
    ui.statusText.textContent = text;
    ui.cancel.hidden = false;
}

function showError(message) {
    ui.status.dataset.state = "error";
    ui.statusText.textContent = message;
    ui.cancel.hidden = true;
}

function showIdle(message = "") {
    ui.status.dataset.state = message ? "info" : "idle";
    ui.statusText.textContent = message;
    ui.cancel.hidden = true;
}

function readOptions() {
    const form = new FormData(ui.options);
    return {
        kicadPower: form.has("kicadPower"),
        kicadRc: form.has("kicadRc"),
        kicadFonts: form.has("kicadFonts"),
        noWorksheet: form.has("noWorksheet"),
        sourceEncoding: form.get("sourceEncoding") || "",
    };
}

async function acceptFile(file) {
    if (!file) return;
    if (file.size > MAX_INPUT_BYTES) {
        showError(
            `“${file.name}” is larger than ${MAX_INPUT_BYTES / (1024 * 1024)} MB, `
            + "the most this page converts.",
        );
        return;
    }
    setBusy(`Reading ${file.name}…`);
    try {
        current = { name: file.name, bytes: await file.arrayBuffer() };
    } catch (error) {
        showError(`“${file.name}” could not be read (${error.message}).`);
        return;
    }
    runConversion();
}

function runConversion() {
    if (!current) return;
    // A new request supersedes one still running.
    if (inFlight) restartWorker();
    inFlight = true;
    requestId += 1;
    setBusy(`Opening ${current.name}…`);
    worker.postMessage({
        type: "convert",
        id: requestId,
        wasmUrl,
        fileName: current.name,
        // Copied, not transferred: the page keeps the original so that an
        // option change can convert it again.
        bytes: current.bytes,
        options: readOptions(),
    });
}

function onWorkerMessage({ data }) {
    if (data.id !== requestId) return;
    if (data.stage === "converting") {
        setBusy(`Converting ${current.name}…`);
        return;
    }
    inFlight = false;
    if (!data.ok) {
        showError(data.message);
        return;
    }
    result = { projectName: data.projectName, files: new Map(data.files) };
    showIdle();
    showResult(data.member);
}

function showResult(member) {
    const { projectName, files } = result;
    ui.result.hidden = false;
    ui.resultName.textContent = projectName;
    const sheetCount = [...files.keys()]
        .filter((name) => name.endsWith(".kicad_sch") && name !== `${projectName}.kicad_sch`)
        .length;
    ui.resultDetail.textContent =
        `${sheetCount} sheet${sheetCount === 1 ? "" : "s"}, ${files.size} files`
        + (member ? ` · from ${member}` : "");
    ui.download.textContent = `Download ${archiveName(projectName)}`;
    ui.previewNote.hidden = true;
    showPreview(
        {
            list: ui.sheets,
            viewer: ui.viewer,
            onError: (message) => {
                ui.previewNote.textContent = message;
                ui.previewNote.hidden = false;
            },
        },
        projectName,
        files,
    );
}

function download() {
    if (!result) return;
    const blob = new Blob(
        [buildProjectArchive(result.projectName, result.files)],
        { type: "application/zip" },
    );
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = archiveName(result.projectName);
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

// --- Input routes ---------------------------------------------------------

ui.picker.addEventListener("change", () => {
    acceptFile(ui.picker.files[0]);
    ui.picker.value = "";
});

for (const type of ["dragenter", "dragover"]) {
    document.addEventListener(type, (event) => {
        event.preventDefault();
        ui.drop.dataset.over = "true";
    });
}
for (const type of ["dragleave", "drop"]) {
    document.addEventListener(type, (event) => {
        event.preventDefault();
        if (type === "dragleave" && event.relatedTarget) return;
        ui.drop.dataset.over = "false";
    });
}
document.addEventListener("drop", (event) => {
    acceptFile(event.dataTransfer?.files?.[0]);
});

document.addEventListener("paste", (event) => {
    const file = event.clipboardData?.files?.[0];
    if (file) {
        event.preventDefault();
        acceptFile(file);
    } else if (!(event.target instanceof HTMLInputElement)) {
        showIdle(
            "The clipboard holds no file. Copy the .DSN or .zip itself "
            + "(not its contents), or drop or choose it instead.",
        );
    }
});

ui.options.addEventListener("change", () => runConversion());
ui.cancel.addEventListener("click", () => {
    if (inFlight) restartWorker();
    inFlight = false;
    requestId += 1;
    showIdle("Cancelled.");
});
ui.download.addEventListener("click", download);

// --- Start-up ---------------------------------------------------------------

// The deploy workflow writes the commit into version.json; the commit also
// busts caches of the converter binary.
try {
    const response = await fetch(new URL("version.json", import.meta.url));
    if (response.ok) {
        const info = await response.json();
        if (info.commit) {
            version = info.commit;
            wasmUrl = `${wasmUrl}?v=${encodeURIComponent(info.commit)}`;
        }
    }
} catch {
    // Local development: no version.json.
}
ui.version.textContent = version;
if (version !== "development build") {
    ui.version.href = `https://github.com/Andrei-Errapart/Orcad2Kicad/tree/${version}`;
}
startWorker();
