# zxing-wasm 3.1.3

The barcode decoder the scanner uses in browsers without a built-in barcode reader (desktop Chrome on
Windows and Linux, Firefox, Safari). MIT licence, see LICENSE. Served from this site so the scanner
also works on networks that block jsDelivr.

- `zxing_reader.wasm`: byte-identical to `dist/reader/zxing_reader.wasm` in the npm package.
- `index.js`: `dist/iife/reader/index.js` from the npm package, plus the last two lines, which make it
  fetch the `.wasm` file from this folder. `lib/main.dart` points the scanner at this file.

The version must match `zxingWasmVersion` in the mobile_scanner package (7.4.2 pins 3.1.3).
