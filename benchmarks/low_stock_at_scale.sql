-- low_stock_at_scale.sql
-- Does the low-stock rollup stay within Nana's "couple of seconds" when
-- marketing keeps adding subcategories? Builds a synthetic tree far larger
-- and deeper than today's, times the views, and rolls everything back.
--
--     docker compose exec -T db psql -f /workspace/benchmarks/low_stock_at_scale.sql

\set ON_ERROR_STOP on
\set levels                  10
\set categories_per_level    500
\set products                200000

\timing off
BEGIN;

-- Level 1 hangs under a new root; each later level's categories pick a random
-- parent from the level above, so the tree is ragged like a real one.
INSERT INTO categories (category_id, category_name, parent_id)
VALUES (8000000, 'Scale Test Root', NULL);

-- psql variables are not visible inside a DO block, so pass them as settings.
SET LOCAL bench.levels    = :levels;
SET LOCAL bench.per_level = :categories_per_level;

DO $$
DECLARE
    levels    constant integer := current_setting('bench.levels')::integer;
    per_level constant integer := current_setting('bench.per_level')::integer;
BEGIN
    FOR lvl IN 1 .. levels LOOP
        INSERT INTO categories (category_id, category_name, parent_id)
        SELECT 8000000 + lvl * 10000 + n,
               format('Scale L%s-%s', lvl, n),
               CASE WHEN lvl = 1 THEN 8000000
                    ELSE 8000000 + (lvl - 1) * 10000 + 1 + floor(random() * per_level)::integer
               END
        FROM generate_series(1, per_level) AS n;
    END LOOP;
END
$$;

INSERT INTO products (product_name, category_id, price, stock_quantity, reorder_level)
SELECT 'Scale product ' || n,
       8000000 + (1 + floor(random() * :levels)::integer) * 10000 + 1 + floor(random() * :categories_per_level)::integer,
       10,
       floor(random() * 40)::integer,
       10
FROM generate_series(1, :products) AS n;

ANALYZE categories;
ANALYZE products;

\echo
\echo '== Synthetic size'
SELECT (SELECT count(*) FROM categories)          AS categories,
       (SELECT max(depth) FROM category_tree)     AS max_depth,
       (SELECT count(*) FROM products)            AS products;

\timing on
\echo
\echo '== Full rollup (every category, every level)'
SELECT count(*) AS rollup_rows, sum(out_of_stock) FILTER (WHERE depth = 1) AS out_at_roots
FROM low_stock_by_category;

\echo
\echo '== Top of the tree only (what a dashboard opens on)'
SELECT path, products, out_of_stock, low_stock
FROM low_stock_by_category
WHERE depth = 1
ORDER BY out_of_stock DESC
LIMIT 5;

\echo
\echo '== Drill-down: 50 most urgent products'
SELECT count(*) FROM (
    SELECT product_id FROM low_stock_products ORDER BY units_below_reorder_level DESC LIMIT 50
) urgent;
\timing off

ROLLBACK;

-- ANALYZE's row-count estimates survive a ROLLBACK. Without this, the planner
-- keeps believing the synthetic 5,000-category tree exists, overestimates the
-- real rollup, switches on JIT compilation and turns an 8 ms query into 600 ms.
ANALYZE categories;
ANALYZE products;
