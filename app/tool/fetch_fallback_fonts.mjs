// Copies the fallback fonts the Flutter web engine can ask for (Arabic, emoji, CJK and other scripts that
// IBM Plex does not cover) into the web build, so the staff app never fetches from fonts.gstatic.com.
// The list is read from the compiled engine, so it always matches the Flutter version that built the app.
// Downloads are cached in app/.fallback-fonts-cache, so only the first build needs fonts.gstatic.com;
// files the engine no longer lists (after a Flutter upgrade) are removed from the cache.
// Usage (from app/): node tool/fetch_fallback_fonts.mjs build/web
import { readFileSync, existsSync, mkdirSync, copyFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';

const out = process.argv[2] ?? 'build/web';
const cache = '.fallback-fonts-cache';
const source = 'https://fonts.gstatic.com/s/';
const mainJs = join(out, 'main.dart.js');
if (!existsSync(mainJs)) throw new Error(`${mainJs} not found: run this after a JavaScript build (flutter build web), not a --wasm build`);
const js = readFileSync(mainJs, 'utf8');
if (!js.includes('fontFallbackBaseUrl')) throw new Error('main.dart.js has no fontFallbackBaseUrl: engine changed, check this script');
const files = [...new Set(js.match(/"[a-z0-9]+\/v\d+\/[A-Za-z0-9_.-]+\.(?:woff2|ttf)"/g) ?? [])].map((s) => s.slice(1, -1)).sort();
if (files.length < 100) throw new Error(`only ${files.length} fallback font paths found in main.dart.js; expected several hundred`);

async function fetchWithRetry(url, tries = 5) {
  for (let i = 1; ; i++) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(30000) });
      if (!res.ok) throw new Error(`${res.status} ${url}`);
      return Buffer.from(await res.arrayBuffer());
    } catch (e) {
      if (i >= tries) throw e;
      await new Promise((r) => setTimeout(r, 1000 * i));
    }
  }
}

let fetched = 0;
let bytes = 0;
const queue = [...files];
async function worker() {
  while (queue.length) {
    const f = queue.shift();
    const cached = join(cache, f);
    if (!existsSync(cached)) {
      mkdirSync(dirname(cached), { recursive: true });
      writeFileSync(cached, await fetchWithRetry(source + f));
      fetched++;
    }
    const dest = join(out, 'fallback-fonts', f);
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(cached, dest);
    bytes += readFileSync(dest).length;
  }
}
await Promise.all(Array.from({ length: 8 }, worker));
console.log(`fallback fonts: ${files.length} files, ${(bytes / 1048576).toFixed(1)} MB in ${join(out, 'fallback-fonts')} (${fetched} downloaded, rest from cache)`);

// Drop cached fonts that this engine no longer asks for.
const wanted = new Set(files.map((f) => join(cache, f)));
let pruned = 0;
for (const e of readdirSync(cache, { recursive: true, withFileTypes: true })) {
  const p = join(e.parentPath, e.name);
  if (e.isFile() && !wanted.has(p)) { rmSync(p); pruned++; }
}
if (pruned) console.log(`fallback fonts: removed ${pruned} cached files the engine no longer lists`);
