// Copies the web build into the site (public/app), leaving out what the live app never loads:
// debug symbols, and the engine files for the WebAssembly renderers (skwasm, wimp) and the experimental
// webparagraph CanvasKit. This build is JavaScript with CanvasKit, which loads only canvaskit/canvaskit.*
// (Firefox, Safari) or canvaskit/chromium/canvaskit.* (Chrome, Edge).
// Usage (from app/): node tool/copy_web_build.mjs build/web ../public/app
import { cpSync, rmSync, existsSync } from 'node:fs';

const [from = 'build/web', to = '../public/app'] = process.argv.slice(2);
if (!existsSync(`${from}/canvaskit/chromium/canvaskit.wasm`) || !existsSync(`${from}/canvaskit/canvaskit.wasm`)) {
  throw new Error(`${from} has no local CanvasKit: build with flutter build web --no-web-resources-cdn`);
}
const unused = /\.symbols$|[\\/]canvaskit[\\/](skwasm|wimp|webparagraph)/;
rmSync(to, { recursive: true, force: true });
cpSync(from, to, { recursive: true, filter: (f) => !unused.test(f) });
console.log(`copied ${from} to ${to}`);
