// How long does the first request take after the system has been idle, against the requests just after it?
//   node sim/cold-start.mjs [base-url] [--idle-minutes 20] [--rounds 3]
// Each round: wait, then one request (the "first after idle"), then five more straight away.
// Only reads the stock list, so it changes nothing.

const args = process.argv.slice(2);
const base = args[0] && !args[0].startsWith("--") ? args[0] : "https://countonce.pages.dev";
const opt = (name, dflt) => (args.includes("--" + name) ? Number(args[args.indexOf("--" + name) + 1]) : dflt);
const IDLE = opt("idle-minutes", 20), ROUNDS = opt("rounds", 3);

const time = async () => {
  const t0 = performance.now();
  const r = await fetch(`${base}/api/state`, { cache: "no-store" });
  await r.arrayBuffer();
  return { ms: Math.round(performance.now() - t0), ray: r.headers.get("cf-ray") ?? "" };
};

console.log(`${base}: ${ROUNDS} rounds, ${IDLE} minutes idle before each`);
for (let i = 1; i <= ROUNDS; i++) {
  await new Promise((r) => setTimeout(r, IDLE * 60_000));
  const first = await time();
  const warm = [];
  for (let j = 0; j < 5; j++) warm.push((await time()).ms);
  const median = [...warm].sort((a, b) => a - b)[2];
  console.log(`round ${i} at ${new Date().toISOString()}: first ${first.ms} ms, next five median ${median} ms (${warm.join(", ")}) ${first.ray}`);
}
