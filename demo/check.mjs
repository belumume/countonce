// Fires the failure cases at a running API and prints what happened.
// Usage: node demo/check.mjs [base-url] [--measure]   (default http://localhost:8788)
// When the API has a staff key, give it in COUNTONCE_STAFF_KEY: a few checks touch a real item.

const base = process.argv.slice(2).find((a) => !a.startsWith("--")) ?? "http://localhost:8788";
const item = "DEMO-" + crypto.randomUUID().slice(0, 6).toUpperCase();

const KEY = process.env.COUNTONCE_STAFF_KEY ?? "";
// The same length as the key but one character different, so the API has to compare the contents.
const wrongKey = KEY.slice(0, -1) + (KEY.endsWith("x") ? "y" : "x");
const post = (path, body, key = KEY) =>
  fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", "x-staff-key": key },
    body: JSON.stringify(body),
  }).then(async (r) => {
    // A 401 to the key the checks were given means every check after it would fail for that reason alone.
    if (r.status === 401 && key === KEY) {
      console.log(KEY ? "This API did not accept the key in COUNTONCE_STAFF_KEY." : "This API has a staff key. Set COUNTONCE_STAFF_KEY to it and run the checks again.");
      process.exit(1);
    }
    return { status: r.status, ...(await r.json()) };
  });

const send = (path, request_id, delta = -1, staff = "Aisha", extra = {}) =>
  post(path, { request_id, item_id: item, delta, staff, ...extra });

const reset = (qty, reorder_point = 0, reorder_qty = 0) => post("/api/reset", { item_id: item, qty, reorder_point, reorder_qty });

const stock = async () => {
  const s = await fetch(`${base}/api/state?item=${item}`).then((r) => r.json());
  const row = s.items.find((i) => i.id === item);
  const applied = s.movements.filter((m) => m.outcome === "applied").length;
  return { qty: row.qty, applied };
};

let failed = 0;
let ours = 0;
let controls = 0;
const expect = (label, got, want, control = false) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failed++;
  control ? controls++ : ours++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${control ? "[obvious way] " : ""}${label}: got ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
};
const outcomes = (rs) => rs.map((r) => r.outcome).sort();

// 1. One unit left, two people take it at the same moment.
await reset(1);
let id = crypto.randomUUID();
let rs = await Promise.all([send("/api/move", id + "-a", -1, "Aisha"), send("/api/move", id + "-b", -1, "Bilal")]);
expect("last unit, two takers", { outcomes: outcomes(rs), ...(await stock()) }, { outcomes: ["applied", "refused"], qty: 0, applied: 1 });

await reset(1);
id = crypto.randomUUID();
rs = await Promise.all([send("/api/move-unsafe", id + "-a", -1, "Aisha"), send("/api/move-unsafe", id + "-b", -1, "Bilal")]);
expect("last unit, two takers", { outcomes: outcomes(rs), ...(await stock()) }, { outcomes: ["applied", "applied"], qty: 0, applied: 2 }, true);

// 2. Four units, ten people at the same moment.
await reset(4);
id = crypto.randomUUID();
rs = await Promise.all(Array.from({ length: 10 }, (_, i) => send("/api/move", `${id}-${i}`, -1, `Staff ${i}`)));
expect("four units, ten takers", { applied: rs.filter((r) => r.outcome === "applied").length, refused: rs.filter((r) => r.outcome === "refused").length, qty: (await stock()).qty }, { applied: 4, refused: 6, qty: 0 });

// 3. The phone sends the same request twice, one after the other.
await reset(5);
id = crypto.randomUUID();
let first = await send("/api/move", id);
let second = await send("/api/move", id);
expect("same request twice", { repeated: [first.repeated, second.repeated], secondSaysQty: second.qty, ...(await stock()) }, { repeated: [false, true], secondSaysQty: 4, qty: 4, applied: 1 });

await reset(5);
id = crypto.randomUUID();
first = await send("/api/move-unsafe", id);
second = await send("/api/move-unsafe", id);
expect("same request twice", { repeated: [first.repeated, second.repeated], ...(await stock()) }, { repeated: [false, false], qty: 3, applied: 2 }, true);

// 4. The same request twice at the same moment.
await reset(5);
id = crypto.randomUUID();
rs = await Promise.all([send("/api/move", id), send("/api/move", id)]);
expect("same request twice at once", { repeated: rs.map((r) => r.repeated).sort(), ...(await stock()) }, { repeated: [false, true], qty: 4, applied: 1 });

// 5. A refused request, repeated: still refused, stock untouched.
await reset(0);
id = crypto.randomUUID();
first = await send("/api/move", id);
second = await send("/api/move", id);
expect("refused request repeated", { status: [first.status, second.status], repeated: second.repeated, qty: (await stock()).qty }, { status: [409, 409], repeated: true, qty: 0 });

// 6. A request id reused for a different movement is rejected, not answered as if done.
await reset(5);
id = crypto.randomUUID();
await send("/api/move", id, -1);
second = await send("/api/move", id, -3);
expect("same id, different quantity", { status: second.status, qty: (await stock()).qty }, { status: 409, qty: 4 });
second = await post("/api/move", { request_id: id, item_id: "GLOVE-M", delta: -1, staff: "Aisha" });
expect("same id, different item", second.status, 409);

// 6b. With a staff key set on the API, real stock cannot be changed without it.
// The request id is the one already used above, so an API that has no key answers 409 and changes nothing.
if (KEY) {
  const real = { request_id: id, item_id: "GLOVE-M", delta: 1, staff: "Check" };
  const noKey = (await post("/api/move", real, "")).status;
  expect("movement on a real item without the staff key", noKey, 401);
  if (noKey === 401) {
    expect("movement on a real item with a wrong key", (await post("/api/move", real, wrongKey)).status, 401);
    expect("order for a real item without the staff key", (await post("/api/order", { request_id: crypto.randomUUID(), item_id: "GLOVE-M" }, "")).status, 401);
  }
}

// 7. Bad input is turned away.
await reset(5);
expect("empty request id", (await send("/api/move", "")).status, 400);
expect("request id of spaces", (await send("/api/move", "        ")).status, 400);
expect("request id over 100 characters", (await send("/api/move", "x".repeat(101))).status, 400);
expect("quantity over the limit", (await send("/api/move", crypto.randomUUID(), 5000)).status, 400);
expect("unknown item", (await post("/api/move", { request_id: crypto.randomUUID(), item_id: "NO-SUCH", delta: -1, staff: "Aisha" })).status, 404);

// 8. A delivery adds stock.
id = crypto.randomUUID();
expect("delivery of 7", (await send("/api/move", id, 7)).qty, 12);

// 9. The demonstration endpoints cannot touch real stock.
expect("reset refused on a real item", (await post("/api/reset", { item_id: "BOX-A4", qty: 0 })).status, 403);
expect("obvious way refused on a real item", (await post("/api/move-unsafe", { request_id: crypto.randomUUID(), item_id: "BOX-A4", delta: -1, staff: "Aisha" })).status, 403);

// 10. Supplier orders: one shortage is ordered once (rule 3), however often the flow asks.
// The demonstration item gets a reorder point of 2 and a reorder quantity of 5.
const order = (request_id, extra = {}) => post("/api/order", { request_id, item_id: item, raised_by: "Node-RED", ...extra });
const received = (order_id) => post("/api/order/received", { order_id });
const openOrders = async () =>
  (await fetch(`${base}/api/state?item=${item}`).then((r) => r.json())).orders.filter((o) => o.item_id === item && o.status === "open").length;

await reset(1, 2, 5);
id = crypto.randomUUID();
rs = await Promise.all(Array.from({ length: 10 }, (_, i) => order(`${id}-${i}`)));
expect("ten orders for one shortage at once", { ordered: rs.filter((r) => r.outcome === "ordered").length, alreadyOpen: rs.filter((r) => r.outcome === "already open").length, open: await openOrders() }, { ordered: 1, alreadyOpen: 9, open: 1 });

await reset(1, 2, 5);
id = crypto.randomUUID();
first = await order(id, { qty: 999 });
second = await order(id);
expect("quantity comes from the item, not the message", first.order.qty, 5);
expect("same order message twice", { status: [first.status, second.status], repeated: second.repeated, sameOrder: first.order.id === second.order.id, open: await openOrders() }, { status: [201, 200], repeated: true, sameOrder: true, open: 1 });
expect("same order id, different item", (await post("/api/order", { request_id: id, item_id: "GLOVE-M", raised_by: "x" })).status, 409);

// 11. The delivery arrives: stock goes up once, even if "received" is pressed twice at once.
rs = await Promise.all([received(first.order.id), received(first.order.id)]);
expect("delivery received twice at once", { repeated: rs.map((r) => r.repeated).sort(), ...(await stock()), open: await openOrders() }, { repeated: [false, true], qty: 6, applied: 1, open: 0 });
expect("an order when stock is above the reorder point", (await order(crypto.randomUUID())).outcome, "not needed");
await send("/api/move", crypto.randomUUID(), -4);
expect("a new shortage after the delivery gets a new order", (await order(crypto.randomUUID())).outcome, "ordered");

// 12. Bad order input is turned away.
await reset(1, 2, 0);
expect("an item with no reorder quantity", (await order(crypto.randomUUID())).outcome, "not set up");
expect("order with no request id", (await order("")).status, 400);
expect("order for an unknown item", (await post("/api/order", { request_id: crypto.randomUUID(), item_id: "NO-SUCH", raised_by: "x" })).status, 404);
expect("received for an unknown order", (await received(999999999)).status, 404);
expect("a movement may not use a delivery's request id", (await send("/api/move", "order-1-received", 1)).status, 400);

// 13. Visitor practice items: three of the caller's own, named after the real items, no key needed.
const visitor = crypto.randomUUID().replace(/-/g, "").slice(0, 8).toUpperCase();
const vstate = () => fetch(`${base}/api/state?visitor=${visitor}`).then((r) => r.json());
expect("bad visitor id", (await post("/api/visitor", { visitor: "abc" })).status, 400);
expect("visitor's items before they exist", (await vstate()).items.length, 0);
let v = await post("/api/visitor", { visitor });
const realNames = (await fetch(`${base}/api/state`).then((r) => r.json())).items.map((i) => i.name).sort();
expect("visitor gets three items named after the real ones", { status: v.status, names: v.items.map((i) => i.name).sort() }, { status: 200, names: realNames });
const vg = v.items.find((i) => i.id.endsWith("G"));
const vmove = (request_id, delta) => post("/api/move", { request_id, item_id: vg.id, delta, staff: "Visitor" }, "");
id = crypto.randomUUID();
first = await vmove(id, -6);
second = await vmove(id, -6);
expect("visitor takes 6 gloves out without a key, sent twice", { status: [first.status, second.status], repeated: second.repeated, qty: second.qty }, { status: [200, 200], repeated: true, qty: 6 });
v = await post("/api/visitor", { visitor });
expect("starting again keeps what the visitor did", v.items.find((i) => i.id === vg.id).qty, 6);
const vorder = await post("/api/order", { request_id: crypto.randomUUID(), item_id: vg.id, raised_by: "Playground" }, "");
expect("the reorder rule orders the visitor's gloves", { outcome: vorder.outcome, qty: vorder.order?.qty }, { outcome: "ordered", qty: 12 });
expect("the visitor can receive the delivery", (await received(vorder.order.id)).qty, 18);
expect("visitor items stay out of the real stock list", (await fetch(`${base}/api/state`).then((r) => r.json())).items.some((i) => i.id.startsWith("DEMO-")), false);
expect("demo orders stay out of the real order list", (await fetch(`${base}/api/state`).then((r) => r.json())).orders.some((o) => o.item_id.startsWith("DEMO-")), false);
expect("another visitor sees none of them", (await fetch(`${base}/api/state?visitor=ZZZZ0000`).then((r) => r.json())).items.some((i) => i.id === vg.id), false);

// Measurement, not a pass/fail check: how often does the obvious way go wrong with no added pause?
if (process.argv.includes("--measure")) {
  const runs = 20;
  let wrong = 0;
  for (let i = 0; i < runs; i++) {
    await reset(1);
    id = crypto.randomUUID();
    await Promise.all([send("/api/move-unsafe", id + "-a", -1, "Aisha", { pause_ms: 0 }), send("/api/move-unsafe", id + "-b", -1, "Bilal", { pause_ms: 0 })]);
    if ((await stock()).applied === 2) wrong++;
  }
  console.log(`obvious way with no added pause: handed out 2 of 1 in ${wrong} of ${runs} runs`);
}

await reset(1);
console.log(`${ours} checks on our API, ${controls} on the obvious way (expected to go wrong); ${failed} failed`);
process.exit(failed ? 1 : 0);
