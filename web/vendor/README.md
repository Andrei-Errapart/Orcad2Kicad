# Vendored third-party code

Everything the page loads is served from this site; nothing comes from a CDN.
Each entry records where the files came from, their licence, and every local
change. To update one, replace the files from the stated source, re-apply the
listed patches, update the hashes, and run the manual browser checklist in
`doc/specs/2026-10-03-web-converter-design.md`.

## browser_wasi_shim

- Source: npm `@bjorn3/browser_wasi_shim` 0.4.2, the `dist/` directory plus
  both licence files (<https://github.com/bjorn3/browser_wasi_shim>).
- Tarball SHA-256: `9c0281520d0e99f027ec7c1c79b4036c0f8168ed9bf98aba19db4737a1333782`
- Licence: MIT OR Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`).
- Used by `web/runner.js` to run the converter with an in-memory filesystem.

Local patch, `wasi.js` only:

- `args_sizes_get` sized each argument as `arg.length + 1`, which counts
  UTF-16 code units, while `args_get` writes UTF-8 bytes. A non-ASCII DSN
  file name -- the project name is passed as an argument -- overflowed the
  argument buffer the module had allocated, and a long one crashed it with
  "memory access out of bounds". It now counts
  `new TextEncoder().encode(arg).length + 1`, as the shim's own
  `environ_sizes_get` already does. Covered by `tests/web/runner.test.mjs`.

| File | SHA-256 |
|---|---|
| `wasi.js` (patched) | `68f7380b3eccff240feeb6d77aa8e140e2286514fb8fc09ee5426e939c47d302` |
| `wasi.js` (upstream) | `168eb977a826f75ab0c39f9322f78cc58dbd5b233019ad1d6a7e940af8a7c4aa` |
| `index.js` | `7e2fd52ee3f728bb0b1d6e449724e0f13e3d586bb25bde6e02a66366175b5605` |
| `fs_mem.js` | `85dbc9e0ee784d9ff8b55452644e00bf7058e32355aab974f8b71d7d85772324` |
| `fd.js` | `9e82e1fc1bfd3e3573f64349dc42b4b624ed61d24e5c553f2bb4d041444f166c` |
| `fs_opfs.js` | `4b96aaeb5ac5986cf802cbf22b975c656682d22a38248160c96fc2ded5644869` |
| `wasi_defs.js` | `0db0f42ba330749a7b05095ea1fd0ff63fd2b30e84cead30fe4c28359d15f194` |
| `debug.js` | `a91848ee180529e2a60c05dfb9584cad19cd4e1c6f391fdb76a938bcae4c0328` |
| `strace.js` | `ece435d3784d928d02bff4d015b7cb686f8c06de8536ff9f8ebc38a8f403a3be` |
