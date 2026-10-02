// Copyright (C) 2026 Andrei Errapart
// SPDX-License-Identifier: GPL-2.0-or-later
//
// From the bytes a visitor dropped, picked or pasted to the one .DSN the
// converter gets.  Runs in the worker (no DOM API), so a slow or hostile
// archive never blocks the page and Cancel can always stop it.
//
// A ZIP is always unwrapped here and never handed to the converter: the
// Haskell reader treats any ZIP as a stored-only streams fixture
// (isZipArchive in scripts/hs/Container.hs).  The member is chosen from the
// archive's central directory without inflating anything, and only that
// member is inflated, with its output bounded while it runs.

import { Inflate } from "./vendor/fflate/fflate.js";

/** The largest design, and the largest file, the page accepts. */
export const MAX_INPUT_BYTES = 100 * 1024 * 1024;

/**
 * Compressed bytes pushed to the inflater at a time.  fflate's Inflate
 * decompresses everything pushed in one call before reporting output, so the
 * output check after each push can only be as fine as the chunk: DEFLATE
 * expands at most about 1032:1, bounding the overshoot to about 17 MB.
 */
export const INFLATE_CHUNK = 16 * 1024;

const OLE_MAGIC = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
const LOCAL_HEADER = 0x04034b50;
const CENTRAL_HEADER = 0x02014b50;
const END_OF_DIRECTORY = 0x06054b50;
const FLAG_ENCRYPTED = 0x0001;
const FLAG_UTF8 = 0x0800;
const STORED = 0;
const DEFLATED = 8;

class InputError extends Error {
    constructor(message, extra = {}) {
        super(message);
        this.extra = extra;
    }
}

const megabytes = (n) => `${Math.round(n / (1024 * 1024))} MB`;

function tooLarge(limit, inflatedBytes) {
    return new InputError(
        `The design is larger than ${megabytes(limit)}, the most this page converts.`,
        { inflatedBytes },
    );
}

function damaged(fileName) {
    return new InputError(`The archive “${fileName}” is damaged or incomplete.`);
}

function startsWithOle(bytes) {
    return bytes.length >= OLE_MAGIC.length
        && OLE_MAGIC.every((byte, i) => bytes[i] === byte);
}

function startsWithZip(bytes) {
    // A local header, or the end record of an empty archive.
    return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b
        && ((bytes[2] === 3 && bytes[3] === 4) || (bytes[2] === 5 && bytes[3] === 6));
}

/**
 * A KiCad project name from a file name: the base name without its
 * extension, with characters that are unsafe in file names on any common
 * system replaced.
 */
export function projectNameFrom(fileName) {
    const base = String(fileName).split(/[\\/]/).pop().replace(/\.[^.]*$/, "");
    const safe = base
        .replace(/[\u0000-\u001f\u007f<>:"|?*]/g, "_")
        .trim()
        .replace(/[. ]+$/, "");
    return safe || "design";
}

/**
 * @param {Uint8Array} bytes  what the visitor supplied
 * @param {string} fileName  its name, for messages and the project name
 * @param {{limit?: number}} [options]
 * @returns {{ok: true, projectName: string, dsnBytes: Uint8Array,
 *            member: string | null}
 *         | {ok: false, message: string, inflatedBytes?: number}}
 */
export function prepareInput(bytes, fileName, { limit = MAX_INPUT_BYTES } = {}) {
    try {
        if (startsWithOle(bytes)) {
            if (bytes.length > limit) throw tooLarge(limit, 0);
            return {
                ok: true, projectName: projectNameFrom(fileName),
                dsnBytes: bytes, member: null,
            };
        }
        if (startsWithZip(bytes)) return extractFromZip(bytes, fileName, limit);
        throw new InputError(
            `“${fileName}” is not an OrCAD .DSN file or a ZIP archive.`,
        );
    } catch (error) {
        if (error instanceof InputError) {
            return { ok: false, message: error.message, ...error.extra };
        }
        throw error;
    }
}

function extractFromZip(bytes, fileName, limit) {
    const entries = readCentralDirectory(bytes, fileName);
    const candidates = entries.filter((entry) => isDsnMember(entry.name));
    if (candidates.length === 0) {
        throw new InputError(`The archive “${fileName}” contains no .DSN file.`);
    }
    if (candidates.length > 1) {
        throw new InputError(
            `The archive “${fileName}” contains several .DSN files `
            + `(${candidates.map((entry) => entry.name).join(", ")}); `
            + "it must contain exactly one.",
        );
    }

    const entry = candidates[0];
    if (entry.flags & FLAG_ENCRYPTED) {
        throw new InputError(
            `“${entry.name}” in the archive is encrypted, which is not supported.`,
        );
    }
    if (entry.method !== STORED && entry.method !== DEFLATED) {
        throw new InputError(
            `“${entry.name}” in the archive uses an unsupported compression method.`,
        );
    }
    // The declared size allows an early refusal, never a bound: it can lie.
    if (entry.size > limit) throw tooLarge(limit, 0);

    const data = memberData(bytes, entry, fileName);
    const dsnBytes = entry.method === STORED
        ? copyStored(data, limit)
        : inflateBounded(data, limit, fileName);
    if (dsnBytes.length !== entry.size) throw damaged(fileName);
    if (!startsWithOle(dsnBytes)) {
        throw new InputError(
            `“${entry.name}” in the archive is not an OrCAD .DSN file.`,
        );
    }
    return {
        ok: true,
        projectName: projectNameFrom(entry.nameReliable ? entry.name : fileName),
        dsnBytes,
        member: entry.name,
    };
}

function isDsnMember(name) {
    if (name.endsWith("/") || name.endsWith("\\")) return false;
    const parts = name.split(/[\\/]/);
    if (parts.includes("__MACOSX")) return false;
    const base = parts[parts.length - 1];
    // Dot-files include macOS's ._board.DSN resource forks.
    return !base.startsWith(".") && base.toLowerCase().endsWith(".dsn");
}

/** Every entry's name, flags, method, sizes and local-header offset. */
function readCentralDirectory(bytes, fileName) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const need = (offset, length) => {
        if (offset < 0 || offset + length > bytes.length) throw damaged(fileName);
    };
    const u16 = (offset) => (need(offset, 2), view.getUint16(offset, true));
    const u32 = (offset) => (need(offset, 4), view.getUint32(offset, true));

    // The end record sits in the last 22 bytes plus at most a 64 KiB comment.
    let end = -1;
    for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 0xffff); i--) {
        if (view.getUint32(i, true) === END_OF_DIRECTORY) {
            end = i;
            break;
        }
    }
    if (end < 0) throw damaged(fileName);
    const count = u16(end + 10);
    const directorySize = u32(end + 12);
    const directoryOffset = u32(end + 16);
    if (count === 0xffff || directoryOffset === 0xffffffff) {
        throw new InputError(`“${fileName}” is a ZIP64 archive, which is not supported.`);
    }
    if (directoryOffset + directorySize > end) throw damaged(fileName);

    const entries = [];
    let at = directoryOffset;
    for (let i = 0; i < count; i++) {
        if (u32(at) !== CENTRAL_HEADER) throw damaged(fileName);
        const flags = u16(at + 8);
        const nameLength = u16(at + 28);
        need(at + 46, nameLength);
        entries.push({
            flags,
            method: u16(at + 10),
            compressedSize: u32(at + 20),
            size: u32(at + 24),
            localOffset: u32(at + 42),
            ...decodeName(bytes.subarray(at + 46, at + 46 + nameLength), flags),
        });
        at += 46 + nameLength + u16(at + 30) + u16(at + 32);
    }
    return entries;
}

/**
 * Names are UTF-8 when flagged, and in practice often UTF-8 when not.  Any
 * other legacy encoding (an OEM codepage) is decoded byte for byte, which is
 * enough to match the extension, and is not trusted as the project name.
 */
function decodeName(nameBytes, flags) {
    if (flags & FLAG_UTF8) {
        return { name: new TextDecoder().decode(nameBytes), nameReliable: true };
    }
    try {
        const name = new TextDecoder("utf-8", { fatal: true }).decode(nameBytes);
        return { name, nameReliable: true };
    } catch {
        return { name: String.fromCharCode(...nameBytes), nameReliable: false };
    }
}

/** The member's compressed bytes, located through its local header. */
function memberData(bytes, entry, fileName) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const at = entry.localOffset;
    if (at + 30 > bytes.length || view.getUint32(at, true) !== LOCAL_HEADER) {
        throw damaged(fileName);
    }
    // The local header's own lengths: its extra field can differ from the
    // central directory's.  Sizes come from the central directory, which is
    // correct even when the local header defers them to a data descriptor.
    const start = at + 30 + view.getUint16(at + 26, true) + view.getUint16(at + 28, true);
    const end = start + entry.compressedSize;
    if (end > bytes.length) throw damaged(fileName);
    return bytes.subarray(start, end);
}

function copyStored(data, limit) {
    if (data.length > limit) throw tooLarge(limit, 0);
    return data.slice();
}

function inflateBounded(data, limit, fileName) {
    const chunks = [];
    let total = 0;
    const inflater = new Inflate((chunk) => {
        chunks.push(chunk);
        total += chunk.length;
    });
    try {
        for (let offset = 0; offset < data.length || offset === 0; offset += INFLATE_CHUNK) {
            const end = Math.min(offset + INFLATE_CHUNK, data.length);
            inflater.push(data.subarray(offset, end), end === data.length);
            if (total > limit) throw tooLarge(limit, total);
            if (end === data.length) break;
        }
    } catch (error) {
        if (error instanceof InputError) throw error;
        throw damaged(fileName);
    }
    const out = new Uint8Array(total);
    let at = 0;
    for (const chunk of chunks) {
        out.set(chunk, at);
        at += chunk.length;
    }
    return out;
}
