// CountOnce stock API. Clients never touch the database; they call this.
//
// Two rules it must never break:
//   1. Never hand out stock that is not there.
//   2. Never count the same movement twice.
// Supplier orders follow the same second rule, and one more:
//   3. Never order the same shortage twice: at most one open order per item.

interface Env {
  DB: D1Database;
  STAFF_KEY?: string; // a secret set on Cloudflare; when set, changing real stock needs it
}

interface MoveRequest {
  request_id: string; // made up by the sender, one per scan
  item_id: string;
  delta: number; // -1 takes one unit out, +5 puts five in
  staff: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Items whose id starts with DEMO- are throwaway items for the demonstration page.
// The reset and "obvious way" endpoints only work on them, so real stock changes only
// through move() and a received supplier order.
const isDemoItem = (id: unknown): id is string => typeof id === "string" && /^DEMO-[A-Z0-9]{4,12}$/.test(id);

// Request ids that start with "order-" are kept for the ledger rows of received orders.
const isRequestId = (id: unknown): id is string =>
  typeof id === "string" && id.trim().length >= 8 && id.length <= 100 && !id.trim().startsWith("order-");

// Changing real stock (a movement, a supplier order, a delivery) needs the staff key in the
// x-staff-key header, once STAFF_KEY is set. Demonstration items stay open, so anyone can try the page.
// The length check comes first because timingSafeEqual needs equal lengths; it gives away only the length.
function keyOk(request: Request, env: Env, itemId: string): boolean {
  if (!env.STAFF_KEY || isDemoItem(itemId)) return true;
  const given = new TextEncoder().encode(request.headers.get("x-staff-key") ?? "");
  const key = new TextEncoder().encode(env.STAFF_KEY);
  return given.byteLength === key.byteLength && crypto.subtle.timingSafeEqual(given, key);
}
const noKey = () => json({ error: "staff key needed" }, 401);

function readMove(body: any): MoveRequest | null {
  if (
    !isRequestId(body?.request_id) ||
    typeof body?.item_id !== "string" ||
    !Number.isInteger(body?.delta) ||
    body.delta === 0 ||
    Math.abs(body.delta) > 1000
  ) {
    return null;
  }
  return {
    request_id: body.request_id.trim(),
    item_id: body.item_id,
    delta: body.delta,
    staff: typeof body.staff === "string" ? body.staff.slice(0, 40) : "unknown",
  };
}

// The real path. Two statements, sent to the database as one unit (a transaction):
//   A. write the ledger row, marked applied or refused by the stock at that moment
//   B. change the stock, with the same check inside the UPDATE
// The database runs one unit at a time, so no other request can get in between A and B.
// If the same request_id arrives again, statement A breaks the UNIQUE rule, the whole
// unit is undone, and we send back the result of the first time.
async function move(env: Env, m: MoveRequest): Promise<Response> {
  const writeLedger = env.DB.prepare(
    `INSERT INTO movements (request_id, item_id, delta, staff, outcome)
     SELECT ?1, id, ?3, ?4, CASE WHEN qty + ?3 >= 0 THEN 'applied' ELSE 'refused' END
     FROM items WHERE id = ?2
     RETURNING outcome`,
  ).bind(m.request_id, m.item_id, m.delta, m.staff);

  const changeStock = env.DB.prepare(
    `UPDATE items SET qty = qty + ?1
     WHERE id = ?2 AND qty + ?1 >= 0
     RETURNING qty`,
  ).bind(m.delta, m.item_id);

  try {
    const [ledger, stock] = await env.DB.batch<{ outcome?: string; qty?: number }>([
      writeLedger,
      changeStock,
    ]);
    const outcome = ledger.results[0]?.outcome;
    if (!outcome) return json({ error: "no such item" }, 404);
    if (outcome === "refused") {
      return json({ outcome, repeated: false, reason: "not enough stock" }, 409);
    }
    if (stock.results.length !== 1) throw new Error("ledger says applied but stock did not change");
    return json({ outcome, repeated: false, qty: stock.results[0].qty });
  } catch (err) {
    if (!String(err).includes("UNIQUE")) throw err;
    return repeatOf(env, m);
  }
}

// A request_id we have seen before: send back what happened the first time.
async function repeatOf(env: Env, m: MoveRequest): Promise<Response> {
  const first = await env.DB.prepare(
    `SELECT m.item_id, m.delta, m.outcome, i.qty
     FROM movements m JOIN items i ON i.id = m.item_id
     WHERE m.request_id = ?1`,
  )
    .bind(m.request_id)
    .first<{ item_id: string; delta: number; outcome: string; qty: number }>();
  if (!first || first.item_id !== m.item_id || first.delta !== m.delta) {
    return json({ error: "request id already used for a different movement" }, 409);
  }
  return json(
    { outcome: first.outcome, repeated: true, qty: first.qty },
    first.outcome === "applied" ? 200 : 409,
  );
}

// The obvious way, kept only so the demonstration can show it going wrong.
// It reads the stock, decides, then writes. Two requests can both read "1 left"
// before either writes, and a repeated request is simply done again.
// It shares the real ledger table, so it adds a random suffix to the request id;
// otherwise the UNIQUE rule would save it.
async function moveUnsafe(env: Env, m: MoveRequest, pauseMs: number): Promise<Response> {
  const row = await env.DB.prepare("SELECT qty FROM items WHERE id = ?1")
    .bind(m.item_id)
    .first<{ qty: number }>();
  if (!row) return json({ error: "no such item" }, 404);
  if (row.qty + m.delta < 0) {
    return json({ outcome: "refused", repeated: false, reason: "not enough stock" }, 409);
  }
  await sleep(pauseMs); // a slow network or a busy server; widens the gap so it shows every time
  const qty = row.qty + m.delta;
  await env.DB.batch([
    env.DB.prepare("UPDATE items SET qty = ?1 WHERE id = ?2").bind(qty, m.item_id),
    env.DB.prepare(
      `INSERT INTO movements (request_id, item_id, delta, staff, outcome)
       VALUES (?1, ?2, ?3, ?4, 'applied')`,
    ).bind(`${m.request_id}#${crypto.randomUUID()}`, m.item_id, m.delta, m.staff),
  ]);
  return json({ outcome: "applied", repeated: false, qty });
}

// A visitor to the public playground gets three practice items of their own, named after the real
// items and with the same reorder settings. Their ids are DEMO- ids, so they need no staff key and
// never appear in the real stock list. The visitor id is made by the visitor's browser or phone.
const isVisitor = (id: unknown): id is string => typeof id === "string" && /^[A-Z0-9]{8}$/.test(id);
const VISITOR_ITEMS: { real: string; suffix: string; qty: number }[] = [
  { real: "BOX-A4", suffix: "P", qty: 40 },
  { real: "GLOVE-M", suffix: "G", qty: 12 },
  { real: "TONER-K", suffix: "T", qty: 3 },
];
const visitorIds = (visitor: string) => VISITOR_ITEMS.map((v) => `DEMO-${visitor}${v.suffix}`);

// Demonstration items not used for a day are cleared out as we go. Demo ids are matched as a key range
// ('DEMO-' up to 'DEMO.', the next character after '-'), which the primary key index can serve; LIKE cannot,
// because it ignores case and the index does not, so LIKE would read every item on every call.
const DEMO_RANGE = `id >= 'DEMO-' AND id < 'DEMO.'`;
const NOT_DEMO = `(id < 'DEMO-' OR id >= 'DEMO.')`;
// Old demo items are found through the partial index items_demo_age (migration 0006), so the sweep reads only
// the rows it deletes. Every demo item has a created_at (migration 0006 filled in the few that had none).
const OLD_DEMO_IDS = `SELECT id FROM items INDEXED BY items_demo_age
  WHERE ${DEMO_RANGE} AND created_at < datetime('now', '-1 day')`;
// The sweep runs at most once every 10 minutes: the UPDATE claims the turn
// (only one caller can move the clock), and only the caller that claimed it sweeps.
// It is housekeeping: the caller's own work is already written, so a failed sweep is logged, never returned.
async function sweepOld(env: Env): Promise<void> {
  try {
    const turn = await env.DB.prepare(
      `UPDATE sweep_clock SET swept_at = datetime('now') WHERE id = 1 AND swept_at < datetime('now', '-10 minutes') RETURNING id`,
    ).all();
    if (!turn.results.length) return;
    await env.DB.batch([
      env.DB.prepare(`DELETE FROM orders WHERE item_id IN (${OLD_DEMO_IDS})`),
      env.DB.prepare(`DELETE FROM movements WHERE item_id IN (${OLD_DEMO_IDS})`),
      env.DB.prepare(`DELETE FROM items WHERE id IN (${OLD_DEMO_IDS})`),
    ]);
  } catch (err) {
    console.error("sweep of old demo items failed", err);
  }
}

// Creates the visitor's items if they do not exist yet. Items that exist keep their stock, so a reload or a
// second tab does not undo what the visitor did; only their clock moves, so items opened again within a day
// are kept (a tab left open for more than a day without a reload starts again with fresh items).
async function startVisitor(env: Env, body: any): Promise<Response> {
  if (!isVisitor(body?.visitor)) return json({ error: "visitor must be 8 capital letters or digits" }, 400);
  const visitor: string = body.visitor;
  await env.DB.batch([
    ...VISITOR_ITEMS.map((v) =>
      env.DB.prepare(
        `INSERT INTO items (id, name, qty, reorder_point, reorder_qty, created_at)
         SELECT ?1, name, ?2, reorder_point, reorder_qty, datetime('now') FROM items WHERE id = ?3
         ON CONFLICT (id) DO UPDATE SET created_at = datetime('now')`,
      ).bind(`DEMO-${visitor}${v.suffix}`, v.qty, v.real),
    ),
  ]);
  await sweepOld(env);
  return visitorState(env, visitor);
}

// The same shape as state(), for one visitor's items only.
async function visitorState(env: Env, visitor: string): Promise<Response> {
  const [a, b, c] = visitorIds(visitor);
  const orderColumns = "id, item_id, qty, raised_by, status, created_at, received_at";
  const [items, movements, open, received] = await env.DB.batch([
    env.DB.prepare(`SELECT id, name, qty, reorder_point, reorder_qty FROM items WHERE id IN (?1, ?2, ?3) ORDER BY id`).bind(a, b, c),
    env.DB.prepare(
      `SELECT id, request_id, item_id, delta, staff, outcome, created_at FROM movements
       WHERE item_id IN (?1, ?2, ?3) ORDER BY id DESC LIMIT 20`,
    ).bind(a, b, c),
    env.DB.prepare(`SELECT ${orderColumns} FROM orders WHERE item_id IN (?1, ?2, ?3) AND status = 'open' ORDER BY id DESC`).bind(a, b, c),
    env.DB.prepare(
      `SELECT ${orderColumns} FROM orders WHERE item_id IN (?1, ?2, ?3) AND status = 'received' ORDER BY id DESC LIMIT 5`,
    ).bind(a, b, c),
  ]);
  return json({ items: items.results, movements: movements.results, orders: [...open.results, ...received.results] });
}

// Real items, plus the caller's own demonstration item and its ledger rows if it asks for one.
// Orders: every open one, and the last five that were received.
async function state(env: Env, demoItem: string | null): Promise<Response> {
  const own = isDemoItem(demoItem) ? demoItem : "";
  const orderColumns = "id, item_id, qty, raised_by, status, created_at, received_at";
  const [items, movements, open, received, ownOrders] = await env.DB.batch([
    env.DB.prepare(
      `SELECT id, name, qty, reorder_point, reorder_qty FROM items
       WHERE ${NOT_DEMO} OR id = ?1 ORDER BY id LIKE 'DEMO-%' DESC, id`,
    ).bind(own),
    // Two forms, so each reads only the rows it returns, through its own index (migration 0004). One WHERE
    // covering both cases could use neither index, and read the whole ledger on every call.
    own
      ? env.DB.prepare(
          `SELECT id, request_id, item_id, delta, staff, outcome, created_at FROM movements
           WHERE item_id = ?1 ORDER BY id DESC LIMIT 20`,
        ).bind(own)
      : env.DB.prepare(
          `SELECT id, request_id, item_id, delta, staff, outcome, created_at FROM movements
           WHERE item_id NOT LIKE 'DEMO-%' ORDER BY id DESC LIMIT 20`,
        ),
    // Real orders through the partial index orders_real, the caller's own item's through orders_item (migration 0005).
    env.DB.prepare(
      `SELECT ${orderColumns} FROM orders
       WHERE item_id NOT LIKE 'DEMO-%' AND status = 'open' ORDER BY id DESC`,
    ),
    env.DB.prepare(
      `SELECT ${orderColumns} FROM orders
       WHERE item_id NOT LIKE 'DEMO-%' AND status = 'received' ORDER BY id DESC LIMIT 5`,
    ),
    env.DB.prepare(`SELECT ${orderColumns} FROM orders WHERE item_id = ?1 ORDER BY id DESC LIMIT 6`).bind(own),
  ]);
  // The same list as before the split: every open order, then the last five received, newest first.
  type Row = { id: number; status: string };
  const mine = ownOrders.results as Row[];
  const newest = (a: Row, b: Row) => b.id - a.id;
  const orders = [
    ...[...mine.filter((o) => o.status === "open"), ...(open.results as Row[])].sort(newest),
    ...[...mine.filter((o) => o.status === "received"), ...(received.results as Row[])].sort(newest).slice(0, 5),
  ];
  return json({ items: items.results, movements: movements.results, orders });
}

const isCount = (n: unknown): n is number => Number.isInteger(n) && (n as number) >= 0 && (n as number) <= 1000;

// One item's movements, newest first, with the stock left after each one.
// The stock after a movement is today's stock minus every applied change that came later.
async function history(env: Env, itemId: string | null): Promise<Response> {
  // One batch, so the stock, the rows and the counts all come from the same moment.
  const [items, rows, counts] = await env.DB.batch([
    env.DB.prepare("SELECT id, name, qty, reorder_point FROM items WHERE id = ?1").bind(itemId ?? ""),
    env.DB.prepare(
      `SELECT id, delta, staff, outcome, created_at,
         (SELECT qty FROM items WHERE id = ?1) - COALESCE(SUM(CASE WHEN outcome = 'applied' THEN delta ELSE 0 END)
           OVER (ORDER BY id DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS qty_after
       FROM movements WHERE item_id = ?1 ORDER BY id DESC LIMIT 50`,
    ).bind(itemId ?? ""),
    // Every ledger row of the item, not only the last 50: the load simulator compares these with its scans.
    env.DB.prepare(
      `SELECT COUNT(*) FILTER (WHERE outcome = 'applied') AS applied, COUNT(*) FILTER (WHERE outcome = 'refused') AS refused
       FROM movements WHERE item_id = ?1`,
    ).bind(itemId ?? ""),
  ]);
  const item = items.results[0];
  if (!item) return json({ error: "no such item" }, 404);
  return json({ item, movements: rows.results, ledger: counts.results[0] });
}

// Creates a demonstration item, or puts it back to a known state and clears its ledger rows and orders.
// The reorder point and reorder quantity are optional and default to 0 (never reordered).
async function reset(env: Env, body: any): Promise<Response> {
  if (!isDemoItem(body?.item_id)) return json({ error: "only DEMO- items can be reset" }, 403);
  const point = body?.reorder_point ?? 0;
  const reorder = body?.reorder_qty ?? 0;
  if (!isCount(body?.qty) || !isCount(point) || !isCount(reorder)) {
    return json({ error: "qty, reorder_point and reorder_qty must be whole numbers from 0 to 1000" }, 400);
  }
  // The item being reset counts as new again, so the sweep never deletes it.
  await env.DB.batch([
    env.DB.prepare(`UPDATE items SET created_at = datetime('now') WHERE id = ?1`).bind(body.item_id),
    env.DB.prepare("DELETE FROM orders WHERE item_id = ?1").bind(body.item_id),
    env.DB.prepare("DELETE FROM movements WHERE item_id = ?1").bind(body.item_id),
    env.DB.prepare(
      `INSERT INTO items (id, name, qty, reorder_point, reorder_qty, created_at)
       VALUES (?1, 'Demonstration item', ?2, ?3, ?4, datetime('now'))
       ON CONFLICT (id) DO UPDATE SET qty = excluded.qty, reorder_point = excluded.reorder_point,
         reorder_qty = excluded.reorder_qty`,
    ).bind(body.item_id, body.qty, point, reorder),
  ]);
  await sweepOld(env);
  return state(env, body.item_id);
}

interface OrderRequest {
  request_id: string; // made up by the sender, one per shortage message
  item_id: string;
  raised_by: string;
}

function readOrder(body: any): OrderRequest | null {
  if (!isRequestId(body?.request_id) || typeof body?.item_id !== "string") return null;
  return {
    request_id: body.request_id.trim(),
    item_id: body.item_id,
    raised_by: typeof body.raised_by === "string" ? body.raised_by.slice(0, 40) : "unknown",
  };
}

type Order = { id: number; item_id: string; qty: number; raised_by: string; status: string; request_id: string };
type Stock = { id: string; name: string; qty: number; reorder_point: number; reorder_qty: number };
const ORDER_COLUMNS = "id, request_id, item_id, qty, raised_by, status, created_at, received_at";

// Raises a supplier order. The caller only names the item; the API decides the rest:
//   - the item must be at or below its reorder point right now, so a stale or forged
//     message cannot order stock that is not needed
//   - the quantity is the item's own reorder quantity, never a number from the message
//   - a request_id seen before breaks its UNIQUE rule: we send back that first order (rule 2)
//   - a second open order for the same item breaks the one_open_order_per_item index:
//     we send back the order that is already open (rule 3)
// All of it is one INSERT, so the database checks it in a single step.
async function raiseOrder(env: Env, o: OrderRequest): Promise<Response> {
  const item = await env.DB.prepare("SELECT id, name, qty, reorder_point, reorder_qty FROM items WHERE id = ?1")
    .bind(o.item_id)
    .first<Stock>();
  if (!item) return json({ error: "no such item" }, 404);
  try {
    const order = await env.DB.prepare(
      `INSERT INTO orders (request_id, item_id, qty, raised_by)
       SELECT ?1, id, reorder_qty, ?3 FROM items
       WHERE id = ?2 AND reorder_qty > 0 AND qty <= reorder_point
       RETURNING ${ORDER_COLUMNS}`,
    )
      .bind(o.request_id, o.item_id, o.raised_by)
      .first<Order>();
    if (order) return json({ outcome: "ordered", repeated: false, order, item }, 201);
  } catch (err) {
    if (!String(err).includes("UNIQUE")) throw err;
  }
  const first = await env.DB.prepare(`SELECT ${ORDER_COLUMNS} FROM orders WHERE request_id = ?1`)
    .bind(o.request_id)
    .first<Order>();
  if (first) {
    if (first.item_id !== o.item_id) return json({ error: "request id already used for a different order" }, 409);
    return json({ outcome: "ordered", repeated: true, order: first, item });
  }
  const open = await env.DB.prepare(`SELECT ${ORDER_COLUMNS} FROM orders WHERE item_id = ?1 AND status = 'open'`)
    .bind(o.item_id)
    .first<Order>();
  if (open) return json({ outcome: "already open", repeated: false, order: open, item });
  // Nothing was inserted and no order is open: read the item again to say why.
  const now = (await env.DB.prepare("SELECT id, name, qty, reorder_point, reorder_qty FROM items WHERE id = ?1")
    .bind(o.item_id)
    .first<Stock>())!;
  if (now.reorder_qty <= 0) {
    return json({ outcome: "not set up", reason: "this item has no reorder quantity", item: now }, 409);
  }
  if (now.qty > now.reorder_point) {
    return json({ outcome: "not needed", reason: "stock is above the reorder point", item: now }, 409);
  }
  // Low, set up, and no order: an open order was received between our statements. Let the caller retry.
  return json({ error: "stock changed while ordering, try again" }, 503);
}

// The supplier's delivery arrives. Three statements, sent as one unit (a transaction):
//   A. a ledger row for the delivery, with a request id made from the order id
//   B. the stock goes up by the order's quantity
//   C. the order is marked received
// Each one only acts on an order that is still open, so a second "received" for the
// same order changes nothing, and stock goes up once.
async function receiveOrder(env: Env, orderId: number): Promise<Response> {
  const open = `SELECT id FROM orders WHERE id = ?1 AND status = 'open'`;
  const [, stock, marked] = await env.DB.batch<{ qty?: number; id?: number }>([
    env.DB.prepare(
      `INSERT INTO movements (request_id, item_id, delta, staff, outcome)
       SELECT 'order-' || id || '-received', item_id, qty, 'Supplier delivery', 'applied'
       FROM orders WHERE id = ?1 AND status = 'open'`,
    ).bind(orderId),
    env.DB.prepare(
      `UPDATE items SET qty = qty + (SELECT qty FROM orders WHERE id = ?1)
       WHERE id = (SELECT item_id FROM orders WHERE id = ?1) AND EXISTS (${open})
       RETURNING qty`,
    ).bind(orderId),
    env.DB.prepare(
      `UPDATE orders SET status = 'received', received_at = CURRENT_TIMESTAMP
       WHERE id = ?1 AND status = 'open'
       RETURNING id`,
    ).bind(orderId),
  ]);
  const order = await env.DB.prepare(`SELECT ${ORDER_COLUMNS} FROM orders WHERE id = ?1`).bind(orderId).first<Order>();
  if (!order) return json({ error: "no such order" }, 404);
  if (marked.results.length === 1) {
    return json({ outcome: "received", repeated: false, order, qty: stock.results[0]?.qty });
  }
  const qty = (await env.DB.prepare("SELECT qty FROM items WHERE id = ?1").bind(order.item_id).first<{ qty: number }>())?.qty;
  return json({ outcome: "received", repeated: true, order, qty });
}

export default {
  // Any failure we did not expect still gets a JSON answer, so a client can always read it.
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (err) {
      console.error(err);
      return json({ error: "server error" }, 500);
    }
  },
};

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const { pathname } = url;
  if (request.method === "GET" && pathname === "/api/state") {
    const visitor = url.searchParams.get("visitor");
    if (visitor !== null) return isVisitor(visitor) ? visitorState(env, visitor) : json({ error: "bad visitor id" }, 400);
    return state(env, url.searchParams.get("item"));
  }
  if (request.method === "GET" && pathname === "/api/history") {
    return history(env, url.searchParams.get("item"));
  }
  if (request.method !== "POST") return json({ error: "not found" }, 404);

  const body: any = await request.json().catch(() => null);
  if (pathname === "/api/reset") return reset(env, body);
  if (pathname === "/api/visitor") return startVisitor(env, body);
  if (pathname === "/api/order") {
    const o = readOrder(body);
    if (!o) return json({ error: "bad request" }, 400);
    return keyOk(request, env, o.item_id) ? raiseOrder(env, o) : noKey();
  }
  if (pathname === "/api/order/received") {
    if (!Number.isInteger(body?.order_id) || body.order_id <= 0) return json({ error: "bad request" }, 400);
    // Read here only to know whose stock it is, for the key check; receiveOrder() works on the order itself.
    const order = await env.DB.prepare("SELECT item_id FROM orders WHERE id = ?1").bind(body.order_id).first<{ item_id: string }>();
    if (!order) return json({ error: "no such order" }, 404);
    return keyOk(request, env, order.item_id) ? receiveOrder(env, body.order_id) : noKey();
  }

  const m = readMove(body);
  if (pathname === "/api/move") {
    if (!m) return json({ error: "bad request" }, 400);
    return keyOk(request, env, m.item_id) ? move(env, m) : noKey();
  }
  if (pathname === "/api/move-unsafe") {
    if (!m) return json({ error: "bad request" }, 400);
    if (!isDemoItem(m.item_id)) return json({ error: "only DEMO- items" }, 403);
    const pause = Number.isInteger(body.pause_ms) ? Math.min(Math.max(body.pause_ms, 0), 1000) : 200;
    return moveUnsafe(env, m, pause);
  }
  return json({ error: "not found" }, 404);
}
