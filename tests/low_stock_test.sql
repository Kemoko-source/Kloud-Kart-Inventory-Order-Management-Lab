-- low_stock_test.sql
-- The category rollup counts every product exactly once at every level, works
-- at any depth, and cannot hang even if a loop gets into the tree.
-- Runs in one transaction that is rolled back.
--
--     docker compose exec -T db psql -f /workspace/tests/low_stock_test.sql

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

BEGIN;

\ir test_helpers.sql

-- Every product is counted once: roots plus "(Uncategorised)" = all products.
SELECT pg_temp.check('roots + uncategorised account for every product exactly once',
    (SELECT sum(r.products) FROM low_stock_by_category r
     WHERE r.category_id IS NULL
        OR r.category_id IN (SELECT category_id FROM categories WHERE parent_id IS NULL))
    = (SELECT count(*) FROM products));

-- Rollup arithmetic holds at every node: own products + children's subtrees.
SELECT pg_temp.check('each category = its own products + its children''s subtrees',
    NOT EXISTS (
        SELECT 1
        FROM categories c
        JOIN low_stock_by_category r ON r.category_id = c.category_id
        WHERE r.products <>
              (SELECT count(*) FROM products p WHERE p.category_id = c.category_id)
            + coalesce((SELECT sum(rc.products) FROM categories ch
                        JOIN low_stock_by_category rc ON rc.category_id = ch.category_id
                        WHERE ch.parent_id = c.category_id), 0)));

SELECT pg_temp.check('out-of-stock and low counts at the top match a direct count of products',
    (SELECT sum(out_of_stock) = (SELECT count(*) FROM products WHERE stock_quantity = 0)
        AND sum(low_stock)    = (SELECT count(*) FROM products
                                 WHERE stock_quantity > 0 AND stock_quantity <= reorder_level)
     FROM low_stock_by_category
     WHERE category_id IS NULL
        OR category_id IN (SELECT category_id FROM categories WHERE parent_id IS NULL)));

SELECT pg_temp.check('drill-down lists exactly the out + low products',
    (SELECT count(*) FROM low_stock_products)
    = (SELECT count(*) FROM products WHERE stock_quantity <= reorder_level));

-- Depth is not hard-coded: hang three new levels under Cases (depth 4).
SELECT out_of_stock AS cases_out_before FROM low_stock_by_category WHERE category_id = 106 \gset
SELECT out_of_stock AS electronics_out_before FROM low_stock_by_category WHERE category_id = 101 \gset

INSERT INTO categories (category_id, category_name, parent_id) VALUES
    (990001, 'Test Level 5', 106),
    (990002, 'Test Level 6', 990001),
    (990003, 'Test Level 7', 990002);
INSERT INTO products (product_name, category_id, price, stock_quantity)
VALUES ('LOW STOCK TEST PRODUCT', 990003, 10, 0);

SELECT pg_temp.check('a 7-level path is built with no depth limit',
    (SELECT depth = 7 AND path = 'Electronics > Phones > Phone Accessories > Cases > Test Level 5 > Test Level 6 > Test Level 7'
     FROM category_tree WHERE category_id = 990003));
SELECT pg_temp.check('a product at depth 7 rolls up into Cases (depth 4)',
    (SELECT out_of_stock = :cases_out_before + 1 FROM low_stock_by_category WHERE category_id = 106));
SELECT pg_temp.check('... and all the way to Electronics (depth 1)',
    (SELECT out_of_stock = :electronics_out_before + 1 FROM low_stock_by_category WHERE category_id = 101));
SELECT pg_temp.check('the out-of-stock product appears in the drill-down with its full path',
    (SELECT category_path LIKE '%> Test Level 7' FROM low_stock_products WHERE product_name = 'LOW STOCK TEST PRODUCT'));

-- Restocking above the reorder level takes it off the list.
UPDATE products SET stock_quantity = reorder_level + 1 WHERE product_name = 'LOW STOCK TEST PRODUCT';
SELECT pg_temp.check('restocked product leaves the drill-down',
    NOT EXISTS (SELECT 1 FROM low_stock_products WHERE product_name = 'LOW STOCK TEST PRODUCT'));

-- A loop cannot hang the views. Bypass the guard trigger (owner-only, inside
-- this rolled-back transaction) to force Electronics under Smartphones.
ALTER TABLE categories DISABLE TRIGGER categories_prevent_cycle;
UPDATE categories SET parent_id = 103 WHERE category_id = 101;
SET LOCAL statement_timeout = '5s';

-- Returning at all proves termination; the checks below prove it did not
-- return garbage: no category listed twice, never more rows than categories
-- (+1 for "(Uncategorised)"), and the drill-down still lists every low product.
SELECT count(*)                     AS rows_with_loop,
       count(DISTINCT category_id)  AS distinct_categories_with_loop,
       count(*) FILTER (WHERE category_id IS NULL) AS uncategorised_rows
FROM low_stock_by_category \gset
SELECT pg_temp.check('rollup still returns, in under 5 s, with a loop in the tree',
    :rows_with_loop > 0);
SELECT pg_temp.check('... and lists each category at most once, within the number of categories',
    :rows_with_loop = :distinct_categories_with_loop + :uncategorised_rows
    AND :uncategorised_rows = 1
    AND :rows_with_loop <= (SELECT count(*) FROM categories) + 1);
SELECT count(*) AS products_with_loop FROM low_stock_products \gset
SELECT pg_temp.check('drill-down still returns, listing every low or out-of-stock product exactly once',
    :products_with_loop = (SELECT count(*) FROM products WHERE stock_quantity <= reorder_level));

ROLLBACK;

\echo 'PASSED: all low-stock rollup tests'
