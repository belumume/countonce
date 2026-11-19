-- When a demonstration item was made, so old ones can be cleared out.
ALTER TABLE items ADD COLUMN created_at TEXT;
