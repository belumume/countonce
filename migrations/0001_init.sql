-- Current stock: one row per item.
CREATE TABLE items (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  qty           INTEGER NOT NULL CHECK (qty >= 0),
  reorder_point INTEGER NOT NULL DEFAULT 0
);

-- The ledger: one row per stock movement.
-- request_id is UNIQUE, so the same request can never be written twice.
CREATE TABLE movements (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL UNIQUE,
  item_id    TEXT NOT NULL REFERENCES items(id),
  delta      INTEGER NOT NULL,
  staff      TEXT NOT NULL,
  outcome    TEXT NOT NULL CHECK (outcome IN ('applied', 'refused')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO items (id, name, qty, reorder_point) VALUES
  ('BOX-A4', 'A4 paper, box of 5 reams', 40, 10),
  ('TONER-K', 'Black toner cartridge', 1, 2),
  ('GLOVE-M', 'Work gloves, medium', 12, 6);
