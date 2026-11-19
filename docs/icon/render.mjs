// Renders SVG files to PNG with Chromium. Input: a JSON job list [{svg, size, out}] on argv[2].
// PLAYWRIGHT_PKG must point at a package.json whose dependencies include playwright.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const require = createRequire(process.env.PLAYWRIGHT_PKG);
const { chromium } = require("playwright");
const jobs = JSON.parse(readFileSync(process.argv[2], "utf8"));

const browser = await chromium.launch({ executablePath: process.env.CHROME_EXE || undefined });
const page = await browser.newPage({ deviceScaleFactor: 1 });
for (const { svg, size, out } of jobs) {
  const src = readFileSync(svg, "utf8");
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(
    `<!doctype html><style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${src}`,
  );
  await page.locator("svg").screenshot({ path: out, omitBackground: true });
}
await browser.close();
console.log(`rendered ${jobs.length}`);
