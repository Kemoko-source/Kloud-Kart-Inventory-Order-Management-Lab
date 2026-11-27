-- 60_low_stock.sql
-- Nana's third ask: low-stock visibility at a glance, rolled up through the
-- nested category tree (Electronics -> Phones -> Phone Accessories -> Cases),
-- in a couple of seconds. The tree's depth is never assumed.
--
-- What "low" means (the brief leaves it open; see decisions/ADR-004-low-stock-rollup.md):
--   out of stock   stock_quantity = 0
--   low            0 < stock_quantity <= reorder_level
-- reorder_level is per product and starts at two weeks of that product's own
-- recent sales. A flat threshold of 10 units would flag 48% of the catalogue,
-- because fast and slow sellers need very different buffers.

\set ON_ERROR_STOP on

-- Demand window used to seed reorder levels.
\set demand_weeks 8
\set cover_weeks  2

BEGIN;

-- ---------------------------------------------------------------------------
-- Reorder level per product
-- Default 10 for new products = two weeks at the median product's sales rate
-- (about 4.6 units a week in the extract).
-- ---------------------------------------------------------------------------
ALTER TABLE products
    ADD COLUMN reorder_level integer NOT NULL DEFAULT 10
        CONSTRAINT products_reorder_level_not_negative CHECK (reorder_level >= 0);

COMMENT ON COLUMN products.reorder_level IS
    'Stock at or below this is "low". Seeded as two weeks of recent sales; owned and adjusted by operations.';

-- The window ends at the last order in the cleaned data, not at today's date:
-- the extract stops in August 2026, so "the last 8 weeks before today" would
-- contain no sales at all.
WITH window_end AS (
    SELECT max(order_date) AS last_order FROM orders
), demand AS (
    SELECT l.product_id, sum(-l.change_qty)::numeric / :demand_weeks AS weekly_units
    FROM inventory_log l
    CROSS JOIN window_end w
    WHERE l.reason = 'sale'
      AND l.created_at >  w.last_order - make_interval(weeks => :demand_weeks)
      AND l.created_at <= w.last_order
    GROUP BY l.product_id
)
UPDATE products p
SET reorder_level = greatest(ceil(d.weekly_units * :cover_weeks), 1)
FROM demand d
WHERE d.product_id = p.product_id;

-- ---------------------------------------------------------------------------
-- category_tree: every category with its depth and full path, from the roots
-- down, however deep. The CYCLE clause stops the walk if a loop ever appears
-- (the trigger in 30_constraints.sql already refuses them; this is the second
-- line of defence, so the view can never hang).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW category_tree AS
WITH RECURSIVE tree AS (
    SELECT c.category_id, c.category_name, c.parent_id,
           1 AS depth,
           c.category_name::text AS path
    FROM categories c
    WHERE c.parent_id IS NULL
    UNION ALL
    SELECT c.category_id, c.category_name, c.parent_id,
           t.depth + 1,
           t.path || ' > ' || c.category_name
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
) CYCLE category_id SET is_cycle USING visited
SELECT category_id, category_name, parent_id, depth, path
FROM tree
WHERE NOT is_cycle;

COMMENT ON VIEW category_tree IS 'Each category with its depth and full path from the root; depth is not limited.';

-- ---------------------------------------------------------------------------
-- low_stock_by_category: for every category, the stock picture of its whole
-- subtree (itself plus every descendant, at any depth), plus one
-- "(Uncategorised)" row so products without a category are never invisible.
--
-- Products are aggregated per category FIRST (one row per category), and only
-- those small totals are rolled up the tree. Joining products to every
-- ancestor instead copies each product once per level: at 50x today's size
-- that was 1.2M rows and 3.7 s, against well under a second this way
-- (benchmarks/low_stock_at_scale.sql).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW low_stock_by_category AS
WITH RECURSIVE subtree (ancestor_id, category_id) AS (
    SELECT category_id, category_id
    FROM categories
    UNION ALL
    SELECT s.ancestor_id, c.category_id
    FROM subtree s
    JOIN categories c ON c.parent_id = s.category_id
) CYCLE category_id SET is_cycle USING visited,
per_category AS (
    SELECT category_id,
           count(*)                                                                    AS products,
           count(*) FILTER (WHERE stock_quantity = 0)                                  AS out_of_stock,
           count(*) FILTER (WHERE stock_quantity > 0 AND stock_quantity <= reorder_level) AS low_stock,
           sum(stock_quantity)                                                         AS units_on_hand
    FROM products
    WHERE category_id IS NOT NULL
    GROUP BY category_id
)
SELECT t.category_id,
       t.depth,
       t.path,
       coalesce(sum(pc.products), 0)::bigint      AS products,
       coalesce(sum(pc.out_of_stock), 0)::bigint  AS out_of_stock,
       coalesce(sum(pc.low_stock), 0)::bigint     AS low_stock,
       coalesce(sum(pc.units_on_hand), 0)::bigint AS units_on_hand
FROM subtree s
JOIN category_tree t           ON t.category_id = s.ancestor_id
LEFT JOIN per_category pc      ON pc.category_id = s.category_id
WHERE NOT s.is_cycle
GROUP BY t.category_id, t.depth, t.path
UNION ALL
SELECT NULL, 1, '(Uncategorised)',
       count(*),
       count(*) FILTER (WHERE stock_quantity = 0),
       count(*) FILTER (WHERE stock_quantity > 0 AND stock_quantity <= reorder_level),
       coalesce(sum(stock_quantity), 0)::bigint
FROM products
WHERE category_id IS NULL;

COMMENT ON VIEW low_stock_by_category IS
    'Out-of-stock and low-stock counts for each category''s whole subtree, any depth. Sort by path to read as a tree.';

-- ---------------------------------------------------------------------------
-- low_stock_products: the drill-down. Every product that is out or low, most
-- urgent first, with the category path so a buyer knows where it sits.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW low_stock_products AS
SELECT p.product_id,
       p.product_name,
       coalesce(t.path, '(Uncategorised)')              AS category_path,
       p.stock_quantity,
       p.reorder_level,
       CASE WHEN p.stock_quantity = 0 THEN 'out of stock' ELSE 'low' END AS stock_status,
       p.reorder_level - p.stock_quantity               AS units_below_reorder_level
FROM products p
LEFT JOIN category_tree t ON t.category_id = p.category_id
WHERE p.stock_quantity <= p.reorder_level;

COMMENT ON VIEW low_stock_products IS
    'Products at or below their reorder level. Order by units_below_reorder_level DESC for most urgent first.';

COMMIT;

ANALYZE products;
