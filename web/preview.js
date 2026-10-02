// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The schematic preview: a sheet list supplied by the page and one KiCanvas
// embed showing the selected sheet, fed from memory.  KiCanvas's own
// multi-sheet navigation is not used -- in an embed it hides behind a
// collapsed side bar or a double-click on a sheet box.  The generated root
// sheet, which holds only sheet boxes, is not listed.
//
// Only listSheets runs outside a browser; KiCanvas is loaded on first use.

const decoder = new TextDecoder();

// KiCanvas reads its theme from localStorage when its module loads, and its
// default is a dark one; ask for the KiCad colour scheme first.
const KICANVAS_THEME_KEY = "kc:prefs:theme";
let kicanvas = null;

function loadKiCanvas() {
    if (!kicanvas) {
        try {
            localStorage.setItem(KICANVAS_THEME_KEY, JSON.stringify({ val: "kicad" }));
        } catch {
            // Storage blocked: the preview still works, in KiCanvas's colours.
        }
        kicanvas = import("./vendor/kicanvas/kicanvas.js");
        kicanvas.catch(() => {
            kicanvas = null;
        });
    }
    return kicanvas;
}

const unescape = (text) => text.replace(/\\(.)/g, "$1");
const QUOTED = '"((?:[^"\\\\]|\\\\.)*)"';
const SHEET_PROPERTY = new RegExp(`\\(property ${QUOTED} ${QUOTED}`, "g");

/**
 * The project's sheets in the root schematic's order, titled with their
 * sheet names; schematics the root does not reference follow, by file name.
 *
 * @param {string} projectName
 * @param {Map<string, Uint8Array>} files
 * @returns {{file: string, title: string}[]}
 */
export function listSheets(projectName, files) {
    const root = `${projectName}.kicad_sch`;
    const sheets = [];
    const seen = new Set([root]);
    if (files.has(root)) {
        let name = null;
        for (const [, key, value] of decoder.decode(files.get(root)).matchAll(SHEET_PROPERTY)) {
            if (key === "Sheetname") {
                name = unescape(value);
            } else if (key === "Sheetfile") {
                const file = unescape(value);
                if (files.has(file) && !seen.has(file)) {
                    sheets.push({ file, title: name ?? file.replace(/\.kicad_sch$/, "") });
                    seen.add(file);
                }
                name = null;
            }
        }
    }
    const rest = [...files.keys()]
        .filter((file) => file.endsWith(".kicad_sch") && !seen.has(file))
        .sort();
    for (const file of rest) {
        sheets.push({ file, title: file.replace(/\.kicad_sch$/, "") });
    }
    return sheets;
}

/**
 * Show a converted project: fill `list` with one button per sheet and show
 * the first sheet in `viewer`.  Failures are reported through `onError` and
 * never thrown, so a preview problem cannot block the download.
 */
export function showPreview({ list, viewer, onError }, projectName, files) {
    const sheets = listSheets(projectName, files);
    const buttons = sheets.map(({ file, title }) => {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = title;
        button.title = file;
        button.addEventListener("click", () => select(button, file));
        return button;
    });
    list.replaceChildren(...buttons);

    async function select(button, file) {
        for (const other of buttons) {
            other.setAttribute("aria-pressed", String(other === button));
        }
        viewer.replaceChildren();
        try {
            await loadKiCanvas();
        } catch (error) {
            onError(`The preview could not be loaded (${error.message}).`);
            return;
        }
        const embed = document.createElement("kicanvas-embed");
        embed.setAttribute("controls", "basic");
        // The page has its own download button.
        embed.setAttribute("controlslist", "nodownload");
        const source = document.createElement("kicanvas-source");
        source.setAttribute("name", file);
        source.setAttribute("type", "schematic");
        source.textContent = decoder.decode(files.get(file));
        embed.append(source);
        viewer.replaceChildren(embed);
    }

    if (buttons.length > 0) {
        select(buttons[0], sheets[0].file);
    } else {
        viewer.replaceChildren();
        onError("The converted project has no sheets to show.");
    }
}
