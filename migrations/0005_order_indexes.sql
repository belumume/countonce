-- Every stock read lists the open orders and the last five received. Visitors' practice items raise
-- orders too, so without these indexes each read would scan every order ever raised, demo ones included.
-- Real orders, by status, newest first: the partial index holds only orders for items that are not demo items.
CREATE INDEX orders_real ON orders (status, id) WHERE item_id NOT LIKE 'DEMO-%';
-- One item's orders (a visitor's items, a demonstration item, and the sweep of old demo items).
CREATE INDEX orders_item ON orders (item_id, id);
