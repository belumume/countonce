// Load simulator: many phones scanning at once over a bad network, against a running API.
// It only touches its own demonstration item (DEMO-...), never real stock.
//
//   node sim/simulate.mjs [base-url] [options]
//     --phones 8        phones scanning at the same time
//     --scans 25        scans per phone
//     --stock 60        starting stock of the demonstration item
//     --dup 0.2         chance that a request is sent twice (the phone retries too early)
//     --drop 0.15       chance that the reply is lost, so the phone sends the same request again later
//     --late 0.1        chance that a request is held back and arrives after later ones (out of order)
//     --seed 7          same seed, same scans and same network trouble
//     --stop-after 40   stop the whole simulator after this many sends in this run (a crash), keeping the outbox
//     --resume          start again from the outbox file left by a stopped run
//     --latency 20      instead of the load run: time 20 single scans from send to visible on the dashboard
//
// At the end it compares the server with what should have happened:
//   stock on the server = starting stock + every scan that was applied, each counted once;
//   ledger rows marked applied on the server = scans the phones were told were applied.

import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";

const args = process.argv.slice(2);
const base = args[0] && !args[0].startsWith("--") ? args[0] : "http://localhost:8788";
const opt = (name, dflt) => {
  const i = args.indexOf("--" + name);
  if (i < 0) return dflt;
  const v = args[i + 1];
  return v === undefined || v.startsWith("--") ? true : Number(v);
};
const PHONES = opt("phones", 8), SCANS = opt("scans", 25), STOCK = opt("stock", 60);
const DUP = opt("dup", 0.2), DROP = opt("drop", 0.15), LATE = opt("late", 0.1), SEED = opt("seed", 7);
const STOP_AFTER = opt("stop-after", Infinity), RESUME = opt("resume", false), LATENCY = opt("latency", 0);
const OUTBOX = new URL("./outbox.json", import.meta.url);

// A small seeded random number generator (mulberry32), so a run can be repeated exactly.
const seeded = (seed) => {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};
const rand = seeded(SEED);
// The phones run at the same time, so one shared generator would hand out its numbers in whatever order
// the network answers, and the same seed would give different network trouble on each run. So each scan
// gets its own generator, seeded from the run's seed and the scan's place in the list.
const scanRands = new Map();
const randFor = (scan) => {
  if (!scanRands.has(scan)) scanRands.set(scan, seeded(Math.imul(SEED, 1000003) + run.scans.indexOf(scan) + 1));
  return scanRands.get(scan);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A failed connection comes back as status 0, and a reply that is not JSON (an error page) as its status
// alone, so the phones treat both as "no answer" and try again, as a real phone would.
const post = async (path, body) => {
  const t0 = performance.now();
  try {
    const r = await fetch(base + path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    return { ms: performance.now() - t0, status: r.status, ...(await r.json().catch(() => ({}))) };
  } catch {
    return { ms: performance.now() - t0, status: 0 };
  }
};
const state = (item) => fetch(`${base}/api/state?item=${item}`).then((r) => r.json());
const pct = (xs, p) => {
  const a = [...xs].sort((x, y) => x - y);
  return a.length ? a[Math.min(a.length - 1, Math.floor((p / 100) * a.length))] : NaN;
};
const ms = (x) => `${Math.round(x)} ms`;

// ---- Latency mode: send one scan, then read the dashboard's data until the change shows -------------
if (LATENCY) {
  const item = "DEMO-" + crypto.randomUUID().slice(0, 6).toUpperCase();
  await post("/api/reset", { item_id: item, qty: 1000 });
  const send = [], visible = [];
  for (let i = 0; i < LATENCY; i++) {
    const t0 = performance.now();
    const r = await post("/api/move", { request_id: crypto.randomUUID(), item_id: item, delta: -1, staff: "Latency" });
    send.push(r.ms);
    while ((await state(item)).items.find((x) => x.id === item).qty !== r.qty) await sleep(20);
    visible.push(performance.now() - t0);
    await sleep(200);
  }
  console.log(`${LATENCY} scans against ${base}`);
  console.log(`  scan sent until the API answered:     median ${ms(pct(send, 50))}, 95th percentile ${ms(pct(send, 95))}`);
  console.log(`  scan sent until the dashboard data shows it: median ${ms(pct(visible, 50))}, 95th percentile ${ms(pct(visible, 95))}`);
  console.log(`  the dashboard page reads that data every 3 s, so on screen add up to 3 s`);
  process.exit(0);
}

// ---- Load run ----------------------------------------------------------------------------------------
// Every scan the phones will make, decided up front from the seed. Each has its request id from the start,
// as the staff app makes it once at scan time, so every resend of it carries the same id.
let run;
if (RESUME) {
  if (!existsSync(OUTBOX)) throw new Error("no outbox.json to resume from");
  run = JSON.parse(readFileSync(OUTBOX, "utf8"));
  console.log(`resuming: ${run.scans.filter((x) => !x.answer).length} scans still unanswered`);
} else {
  const item = "DEMO-" + crypto.randomUUID().slice(0, 6).toUpperCase();
  const scans = [];
  for (let p = 0; p < PHONES; p++) {
    for (let n = 0; n < SCANS; n++) {
      const delta = rand() < 0.8 ? -1 - Math.floor(rand() * 3) : 1 + Math.floor(rand() * 5);
      scans.push({ request_id: crypto.randomUUID(), item_id: item, delta, staff: `Phone ${p + 1}`, phone: p, answer: null });
    }
  }
  run = { item, stock: STOCK, phones: PHONES, seed: SEED, scans, sends: 0 };
  await post("/api/reset", { item_id: item, qty: STOCK });
}
const save = () => writeFileSync(OUTBOX, JSON.stringify(run));
save();

const stats = { sends: 0, dupSends: 0, lostReplies: 0, lateSends: 0, repeatedAnswers: 0, ms: [] };
let stopped = false;

async function sendOnce(scan) {
  if (stopped) return null;
  if (stats.sends >= STOP_AFTER) {
    stopped = true;
    return null;
  }
  run.sends++;
  stats.sends++;
  const { request_id, item_id, delta, staff } = scan;
  const r = await post("/api/move", { request_id, item_id, delta, staff });
  stats.ms.push(r.ms);
  if (r.repeated) stats.repeatedAnswers++;
  return r;
}

// One phone: its scans in order, each kept in its outbox until an answer gets back.
async function phone(p) {
  for (const scan of run.scans.filter((x) => x.phone === p && !x.answer)) {
    const rnd = randFor(scan);
    if (rnd() < LATE) {
      stats.lateSends++;
      setTimeout(() => deliver(scan), 300 + rnd() * 700); // arrives after the phone's later scans
      continue;
    }
    await deliver(scan);
    await sleep(rnd() * 40);
  }
}

async function deliver(scan) {
  const rnd = randFor(scan);
  while (!scan.answer && !stopped) {
    const sends = [sendOnce(scan)];
    if (rnd() < DUP) {
      stats.dupSends++;
      sends.push(sendOnce(scan)); // the same request, twice, at once
    }
    const replies = (await Promise.all(sends)).filter(Boolean);
    if (rnd() < DROP) {
      stats.lostReplies++; // the server answered, but the phone never heard: try again later
      await sleep(50 + rnd() * 150);
      continue;
    }
    const r = replies[0];
    if (!r) return;
    if (r.status === 0 || r.status >= 500) {
      await sleep(200);
      continue;
    }
    scan.answer = { outcome: r.outcome ?? `error ${r.status}`, repeated: !!r.repeated };
    save();
  }
}

const t0 = performance.now();
await Promise.all(Array.from({ length: run.phones }, (_, p) => phone(p)));
while (!stopped && run.scans.some((x) => !x.answer)) await sleep(100); // the late ones
const seconds = (performance.now() - t0) / 1000;

if (stopped) {
  save();
  console.log(`stopped after ${stats.sends} sends, as asked. ${run.scans.filter((x) => !x.answer).length} scans unanswered,`);
  console.log(`kept in sim/outbox.json. Run again with --resume to finish.`);
  process.exit(0);
}

// ---- The verdict -------------------------------------------------------------------------------------
const s1 = await state(run.item);
const server = s1.items.find((x) => x.id === run.item).qty;
const applied = run.scans.filter((x) => x.answer.outcome === "applied");
const refused = run.scans.filter((x) => x.answer.outcome === "refused");
const expected = run.stock + applied.reduce((a, x) => a + x.delta, 0);
// The server's own count of ledger rows for the item, against the scans the phones were told were applied.
const rows = (await fetch(`${base}/api/history?item=${run.item}`).then((r) => r.json())).ledger;
// Each scan sent once more, 20 at a time, until it gets an answer: the server must hand back the result
// the phone was given the first time.
const resend = async (x) => {
  for (;;) {
    const r = await post("/api/move", { request_id: x.request_id, item_id: x.item_id, delta: x.delta, staff: x.staff });
    if (r.status !== 0 && r.status < 500) return r;
    await sleep(200);
  }
};
const again = [];
for (let i = 0; i < run.scans.length; i += 20) again.push(...(await Promise.all(run.scans.slice(i, i + 20).map(resend))));
const same = again.every((r, i) => r.repeated && r.outcome === run.scans[i].answer.outcome);
const ok = server === expected && rows.applied === applied.length && same;

console.log(`${run.scans.length} scans from ${run.phones} phones against ${base}, seed ${run.seed}, in ${seconds.toFixed(1)} s`);
console.log(`  network trouble: ${stats.dupSends} sent twice at once, ${stats.lostReplies} replies lost and resent, ${stats.lateSends} sent late (out of order)`);
console.log(`  requests sent this run: ${stats.sends}, answered "seen before": ${stats.repeatedAnswers}`);
console.log(`  outcome per scan: ${applied.length} applied, ${refused.length} refused (not enough stock)`);
console.log(`  request time: median ${ms(pct(stats.ms, 50))}, 95th percentile ${ms(pct(stats.ms, 95))}, slowest ${ms(Math.max(...stats.ms))}`);
console.log(`  stock: started ${run.stock}, server says ${server}; start + each applied scan once = ${expected} -> ${server === expected ? "CORRECT" : "WRONG"}`);
console.log(`  ledger: ${rows.applied} rows applied on the server, ${applied.length} scans applied on the phones -> ${rows.applied === applied.length ? "each counted once" : "MISMATCH"}`);
console.log(`  sent once more, every scan got back the answer the phone first had: ${same ? "yes" : "NO"}`);
rmSync(OUTBOX);
process.exit(ok ? 0 : 1);
