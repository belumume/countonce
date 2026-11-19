-- How many units to order when an item falls to its reorder point.
ALTER TABLE items ADD COLUMN reorder_qty INTEGER NOT NULL DEFAULT 0;
UPDATE items SET reorder_qty = 20 WHERE id = 'BOX-A4';
UPDATE items SET reorder_qty = 5 WHERE id = 'TONER-K';
UPDATE items SET reorder_qty = 12 WHERE id = 'GLOVE-M';

-- Supplier orders, raised by the second Node-RED flow through the API.
-- request_id is UNIQUE for the same reason as in movements: a repeated message is not a new order.
CREATE TABLE orders (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id  TEXT NOT NULL UNIQUE,
  item_id     TEXT NOT NULL REFERENCES items(id),
  qty         INTEGER NOT NULL CHECK (qty > 0),
  raised_by   TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'received')),
  created_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  received_at TEXT
);

-- At most one open order per item, so one shortage is never ordered twice.
CREATE UNIQUE INDEX one_open_order_per_item ON orders (item_id) WHERE status = 'open';
