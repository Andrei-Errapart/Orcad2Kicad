// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The converted project as the ZIP the visitor downloads: one top-level
// directory named like the CLI's default output directory, <project>_kicad/.

import { zipSync } from "./vendor/fflate/fflate.js";

export function archiveName(projectName) {
    return `${projectName}_kicad.zip`;
}

/**
 * @param {string} projectName
 * @param {Map<string, Uint8Array>} files  as the runner returns them
 * @returns {Uint8Array}
 */
export function buildProjectArchive(projectName, files) {
    const directory = `${projectName}_kicad`;
    const entries = {};
    for (const [name, data] of files) {
        entries[`${directory}/${name}`] = data;
    }
    return zipSync(entries, { level: 6 });
}
