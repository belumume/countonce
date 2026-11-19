-- Clearing out day-old demonstration items.
-- Demo items by age: the partial index holds only demo ids, so the sweep reads only the old ones.
-- Every demo item gets a time; the few made before created_at existed count as old.
UPDATE items SET created_at = '2000-01-01 00:00:00' WHERE id >= 'DEMO-' AND id < 'DEMO.' AND created_at IS NULL;
CREATE INDEX IF NOT EXISTS items_demo_age ON items (created_at) WHERE id >= 'DEMO-' AND id < 'DEMO.';
-- When the sweep last ran. It runs at most once every 10 minutes, not on every visit.
CREATE TABLE IF NOT EXISTS sweep_clock (id INTEGER PRIMARY KEY CHECK (id = 1), swept_at TEXT NOT NULL);
INSERT OR IGNORE INTO sweep_clock (id, swept_at) VALUES (1, '2000-01-01 00:00:00');
