-- Kloud Kart data diagnosis: the evidence behind docs/01_data_diagnosis.md.
--
-- Run against a FRESH load (before any sql/ solution script), read-only:
--     docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/diagnosis/diagnosis_checks.sql
--
-- Check IDs (D1, D2, ...) match the rows of the diagnosis document.
-- Every query is set-based: on the unindexed raw schema a per-row correlated
-- subquery over inventory_log takes minutes; these finish in seconds.

\pset pager off
\timing on

\echo '== D1  Overselling already happened: negative stock, no guard in the schema'
SELECT count(*)            AS products_below_zero,
       -sum(stock_quantity) AS units_oversold
FROM products
WHERE stock_quantity < 0;

\echo '== D2  Order status is free text: spellings, and what an exact filter misses'
SELECT status AS raw_status, count(*) AS orders
FROM orders
GROUP BY status
ORDER BY orders DESC;

SELECT count(*) FILTER (WHERE status = 'completed')                          AS exact_completed,
       count(*) FILTER (WHERE lower(trim(status)) IN ('completed', 'complete')) AS all_completed
FROM orders;

\echo '== D3a Stock counter disagrees with the movement ledger (sum of inventory_log)'
WITH ledger AS (
    SELECT product_id, sum(change_qty) AS net_movement
    FROM inventory_log
    GROUP BY product_id
)
SELECT sign(p.stock_quantity - l.net_movement)          AS direction,
       count(*)                                         AS products,
       sum(p.stock_quantity - l.net_movement)           AS units_of_drift
FROM products p
JOIN ledger l USING (product_id)
WHERE p.stock_quantity <> l.net_movement
GROUP BY 1;

\echo '== D3b Fulfilled order lines with no matching sale movement (matched on product + timestamp)'
-- Sale rows are written at the order's timestamp with the line's quantity, so
-- (product_id, order_date) is the join key. Pending, cancelled and refunded
-- orders never have one: stock moves at fulfilment, which is by design.
WITH sold AS (
    SELECT i.product_id, o.order_date AS ts, lower(trim(o.status)) AS status, sum(i.quantity) AS units
    FROM order_items i
    JOIN orders o USING (order_id)
    GROUP BY 1, 2, 3
), logged AS (
    SELECT product_id, created_at AS ts, sum(-change_qty) AS units
    FROM inventory_log
    WHERE reason = 'sale'
    GROUP BY 1, 2
)
SELECT s.status,
       count(*)                                  AS product_moments,
       count(*) FILTER (WHERE l.units IS NULL)   AS without_movement,
       count(*) FILTER (WHERE l.units = s.units) AS fully_logged
FROM sold s
LEFT JOIN logged l USING (product_id, ts)
GROUP BY s.status
ORDER BY product_moments DESC;

\echo '== D3c Corrections whose note says they cannot be trusted'
SELECT note, count(*) AS rows, sum(change_qty) AS net_units
FROM inventory_log
WHERE note IS NOT NULL
GROUP BY note
ORDER BY rows DESC;

\echo '== D4a Category tree: cycles (a naive recursive rollup never terminates on these)'
WITH RECURSIVE walk (category_id, path, is_cycle) AS (
    SELECT category_id, ARRAY[category_id], false
    FROM categories
    UNION ALL
    SELECT c.parent_id, w.path || c.parent_id, c.parent_id = ANY (w.path)
    FROM walk w
    JOIN categories c ON c.category_id = w.category_id
    WHERE c.parent_id IS NOT NULL AND NOT w.is_cycle
)
SELECT path AS cycle_path FROM walk WHERE is_cycle;

\echo '== D4b Category with a parent that does not exist; products with no category'
SELECT c.category_id, c.category_name, c.parent_id
FROM categories c
WHERE c.parent_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id);

SELECT count(*) AS products_without_category, sum(stock_quantity) AS units_invisible_to_rollup
FROM products
WHERE category_id IS NULL;

\echo '== D4c Tree depth reachable from the roots (brief: do not hard-code it)'
WITH RECURSIVE tree AS (
    SELECT category_id, 1 AS depth, ARRAY[category_id] AS path
    FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.depth + 1, t.path || c.category_id
    FROM categories c JOIN tree t ON c.parent_id = t.category_id
    WHERE NOT c.category_id = ANY (t.path)
)
SELECT max(depth) AS max_depth, count(*) AS reachable, (SELECT count(*) FROM categories) AS total
FROM tree;

\echo '== D5  Implausible quantities (999 / 9999 look like placeholder keystrokes)'
SELECT order_item_id, order_id, product_id, quantity, unit_price, quantity * unit_price AS line_value
FROM order_items
WHERE quantity >= 100
ORDER BY quantity DESC;

\echo '== D6  Orphans: rows pointing at parents that do not exist (note the ID ranges)'
SELECT 'orders -> customers' AS relation, count(*) AS rows, min(customer_id) AS min_ref, max(customer_id) AS max_ref,
       round(sum(total_amount)) AS ghs_value
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)
UNION ALL
SELECT 'order_items -> orders', count(*), min(order_id), max(order_id), round(sum(quantity * unit_price))
FROM order_items i
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = i.order_id)
UNION ALL
SELECT 'inventory_log -> products', count(*), min(product_id), max(product_id), NULL
FROM inventory_log l
WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id);

\echo '== D7  Duplicate order lines (same order, same product): double inserts?'
WITH line_dupes AS (
    SELECT a.order_id
    FROM order_items a
    JOIN order_items b
      ON a.order_id = b.order_id AND a.product_id = b.product_id AND a.order_item_id < b.order_item_id
), all_lines AS (
    SELECT order_id, sum(quantity * unit_price) AS items_value
    FROM order_items WHERE order_id IN (SELECT order_id FROM line_dupes) GROUP BY order_id
), first_lines AS (
    SELECT order_id, sum(quantity * unit_price) AS items_value
    FROM (SELECT DISTINCT ON (order_id, product_id) order_id, quantity, unit_price
          FROM order_items WHERE order_id IN (SELECT order_id FROM line_dupes)
          ORDER BY order_id, product_id, order_item_id) x
    GROUP BY order_id
)
SELECT count(*)                                                                AS orders_with_dupes,
       count(*) FILTER (WHERE abs(o.total_amount - a.items_value) < 0.01)      AS total_matches_with_dupe,
       count(*) FILTER (WHERE abs(o.total_amount - f.items_value) < 0.01)      AS total_matches_without_dupe
FROM orders o
JOIN all_lines a USING (order_id)
JOIN first_lines f USING (order_id);

\echo '== D8  total_amount vs sum of lines: exact-percentage adjustments vs real errors'
WITH clean_orders AS (
    SELECT order_id, sum(quantity * unit_price) AS items_value
    FROM order_items
    GROUP BY order_id
    HAVING count(*) FILTER (WHERE unit_price IS NULL OR unit_price = 0 OR quantity >= 100) = 0
)
SELECT round(o.total_amount / c.items_value, 2) AS total_to_items_ratio, count(*) AS orders
FROM orders o
JOIN clean_orders c USING (order_id)
WHERE abs(o.total_amount - c.items_value) > 0.01
GROUP BY 1
ORDER BY orders DESC
LIMIT 10;

SELECT count(*) FILTER (WHERE unit_price IS NULL) AS lines_null_price,
       count(*) FILTER (WHERE unit_price = 0)     AS lines_zero_price
FROM order_items;

\echo '== D9  Same person, several customer accounts (email equal after trim + lower)'
SELECT accounts_per_email, count(*) AS people,
       count(*) FILTER (WHERE distinct_names = 1) AS same_name
FROM (
    SELECT lower(trim(email)) AS email_key, count(*) AS accounts_per_email,
           count(DISTINCT lower(trim(full_name))) AS distinct_names
    FROM customers
    GROUP BY 1
    HAVING count(*) > 1
) dupes
GROUP BY accounts_per_email;

\echo '== D10 Orders dated after the extract ends (normal traffic stops 2026-08-31)'
SELECT count(*) AS orders, min(order_date), max(order_date), round(sum(total_amount)) AS ghs_value,
       count(*) FILTER (WHERE extract(second FROM order_date) = 0) AS whole_minute_timestamps
FROM orders
WHERE order_date > '2026-08-31 23:59:59';

\echo '== D11 Contact data: padded emails, phone formats, city spellings'
SELECT count(*) FILTER (WHERE email <> trim(email)) AS padded_emails,
       count(*) FILTER (WHERE phone ~ '^\+233\d{9}$') AS phone_plus233,
       count(*) FILTER (WHERE phone ~ '^233\d{9}$')   AS phone_233,
       count(*) FILTER (WHERE phone ~ '^0\d{9}$')     AS phone_local,
       count(*) FILTER (WHERE phone ~ ' ')            AS phone_with_spaces,
       count(DISTINCT city)                           AS raw_cities,
       count(DISTINCT initcap(trim(city)))            AS real_cities
FROM customers;

\echo '== D12 Products priced 50x or more above their category median (unverified pricing error)'
-- Found while building the Monday report: the top-ranked customers all bought
-- everyday goods (oil, kids clothing, fans) priced at GHS 16,000-22,000.
WITH category_median AS (
    SELECT category_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY price) AS median_price
    FROM products
    GROUP BY category_id
), suspect AS (
    SELECT p.product_id
    FROM products p
    JOIN category_median m USING (category_id)
    WHERE p.price >= 50 * m.median_price
)
SELECT (SELECT count(*) FROM suspect) AS suspect_products,
       round(sum(i.quantity * i.unit_price) FILTER (WHERE i.product_id IN (SELECT product_id FROM suspect))) AS suspect_line_value,
       round(100.0 * sum(i.quantity * i.unit_price) FILTER (WHERE i.product_id IN (SELECT product_id FROM suspect))
                   / sum(i.quantity * i.unit_price), 1) AS pct_of_all_line_value
FROM order_items i;

\echo '== D13 "Pending" orders are as old as completed ones: stuck, not in progress'
SELECT lower(trim(status)) AS status, count(*) AS orders, round(sum(total_amount)) AS ghs_value,
       round(avg(extract(epoch FROM (timestamp '2026-08-31 23:59:59' - order_date)) / 86400)) AS avg_age_days
FROM orders
WHERE order_date <= '2026-08-31 23:59:59'
GROUP BY 1
ORDER BY orders DESC;

\echo '== N1 NOT a problem: order-line price differs from today''s product price (price at time of sale)'
SELECT CASE WHEN i.unit_price = 0 THEN 'zero'
            WHEN i.unit_price < 0.9 * p.price THEN 'below current price'
            ELSE 'about current price' END AS bucket,
       count(*) AS lines
FROM order_items i
JOIN products p USING (product_id)
WHERE i.unit_price IS NOT NULL
GROUP BY 1;

\echo '== N2 NOT a problem: duplicate product names are distinct variants (own price and stock)'
SELECT product_name, count(*) AS products, min(price) AS min_price, max(price) AS max_price
FROM products
GROUP BY product_name
HAVING count(*) > 1
ORDER BY products DESC
LIMIT 5;

\echo '== N3 NOT a problem: timestamps without time zone are local Accra time (UTC+0); traffic peaks at 13:00'
SELECT extract(hour FROM order_date)::int AS hour_of_day, count(*) AS orders
FROM orders
GROUP BY 1
ORDER BY 1;

\echo '== Schema  No foreign keys, no CHECK constraints, no secondary indexes, no ID generators'
-- pg_constraint rather than information_schema: PostgreSQL 18 reports each
-- primary key's NOT NULL as a CHECK there, which would overstate the guards.
SELECT count(*) FILTER (WHERE contype = 'p') AS primary_keys,
       count(*) FILTER (WHERE contype = 'f') AS foreign_keys,
       count(*) FILTER (WHERE contype = 'c') AS check_constraints,
       count(*) FILTER (WHERE contype = 'u') AS unique_constraints
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace;

SELECT count(*) AS non_pk_indexes
FROM pg_indexes
WHERE schemaname = 'public' AND indexname NOT LIKE '%_pkey';

SELECT count(*) AS sequences FROM information_schema.sequences WHERE sequence_schema = 'public';
