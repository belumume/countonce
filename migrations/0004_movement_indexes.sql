-- The dashboard's movement list skips demonstration rows. Without these indexes every stock read
-- scanned the whole ledger, and D1 counts every row it reads against the daily allowance.
-- Real movements, newest first: the partial index holds only rows that are not demonstration rows.
CREATE INDEX movements_real ON movements (id) WHERE item_id NOT LIKE 'DEMO-%';
-- One item's movements (its history, and a demonstration item's own list).
CREATE INDEX movements_item ON movements (item_id, id);
