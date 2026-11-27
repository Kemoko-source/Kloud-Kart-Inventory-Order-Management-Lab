-- 20_clean.sql
-- Fixes the findings in data_findings.md that threaten Nana's numbers.
--
-- One transaction: either every fix lands and every invariant at the bottom
-- holds, or nothing changes. Every removed row goes to data_quarantine and
-- every changed value to data_corrections (see 10_foundations.sql).
--
-- Deliberately NOT changed (see data_findings.md, "Looked wrong, is not wrong"):
-- historical unit prices, duplicate product names, order timestamps' time
-- zone, totals that are exact percentage adjustments of their lines, and
-- customer name capitalisation.

\set ON_ERROR_STOP on

-- Quantities at or above this are treated as keystroke errors. Evidence: the
-- 99.9th percentile of order_items.quantity is 10; the six lines above it are
-- 999 or 9,999 (F-06).
\set implausible_qty 100

-- Last moment of normal trading in the extract. Evidence: about 400 orders a
-- day up to 2026-08-31, then a gap, then 24 isolated orders into 2027, all
-- with whole-minute timestamps against 1.68% of normal orders (F-12).
\set extract_end '2026-08-31 23:59:59'

BEGIN;

SELECT set_config('kloudkart.implausible_qty', :'implausible_qty', true);

-- ===========================================================================
-- F-02  Order status: 15 spellings -> 5 statuses
-- ===========================================================================
CREATE TEMP TABLE status_map ON COMMIT DROP AS
SELECT DISTINCT status AS raw_status,
       CASE lower(trim(status))
           WHEN 'complete' THEN 'completed'
           WHEN 'canceled' THEN 'cancelled'
           ELSE lower(trim(status))
       END AS canonical_status
FROM orders;

INSERT INTO data_corrections (table_name, column_name, old_value, new_value, rows_affected, reason_code, detail)
SELECT 'orders', 'status', m.raw_status, m.canonical_status, count(*), 'status_spelling',
       'Free-text status mapped to one of: pending, shipped, completed, cancelled, refunded'
FROM orders o
JOIN status_map m ON m.raw_status = o.status
WHERE m.raw_status <> m.canonical_status
GROUP BY m.raw_status, m.canonical_status;

UPDATE orders o
SET status = m.canonical_status
FROM status_map m
WHERE m.raw_status = o.status
  AND m.raw_status <> m.canonical_status;

-- ===========================================================================
-- F-13 Contact data: trimmed lower-case emails, one phone format, one city spelling.
-- Logged as one summary row per column; per-row history would be noise.
-- Names are left as entered (cosmetic, F-14).
-- ===========================================================================
CREATE TEMP TABLE contact_fix ON COMMIT DROP AS
SELECT customer_id,
       lower(trim(email))  AS new_email,
       initcap(trim(city)) AS new_city,
       CASE
           WHEN regexp_replace(phone, '\D', '', 'g') ~ '^233\d{9}$'
               THEN '+' || regexp_replace(phone, '\D', '', 'g')
           WHEN regexp_replace(phone, '\D', '', 'g') ~ '^0\d{9}$'
               THEN '+233' || substr(regexp_replace(phone, '\D', '', 'g'), 2)
           ELSE phone                       -- unrecognised: left as entered
       END AS new_phone
FROM customers;

INSERT INTO data_corrections (table_name, column_name, old_value, new_value, rows_affected, reason_code, detail)
SELECT 'customers', col, NULL, rule, n, 'contact_format', detail
FROM (
    SELECT 'email' AS col, 'lower(trim(email))' AS rule,
           count(*) FILTER (WHERE c.email <> f.new_email) AS n,
           'Surrounding spaces made the address undeliverable; case varied between duplicate accounts' AS detail
    FROM customers c JOIN contact_fix f USING (customer_id)
    UNION ALL
    SELECT 'city', 'initcap(trim(city))',
           count(*) FILTER (WHERE c.city <> f.new_city),
           'Same city spelled several ways (Accra, accra, ACCRA, "Accra ")'
    FROM customers c JOIN contact_fix f USING (customer_id)
    UNION ALL
    SELECT 'phone', '+233 followed by 9 digits',
           count(*) FILTER (WHERE c.phone <> f.new_phone),
           'Four formats (+233.., 233.., 0.., spaced) unified to E.164'
    FROM customers c JOIN contact_fix f USING (customer_id)
) summary
WHERE n > 0;

UPDATE customers c
SET email = f.new_email,
    city  = f.new_city,
    phone = f.new_phone
FROM contact_fix f
WHERE f.customer_id = c.customer_id
  AND (c.email, c.city, c.phone) IS DISTINCT FROM (f.new_email, f.new_city, f.new_phone);

-- ===========================================================================
-- F-05  Category tree: break the 9001 <-> 9002 loop, root the dangling branch.
-- Promotions (9002) is the general category and Seasonal Promotions (9001)
-- the specific one, so 9001 stays under 9002 and 9002 becomes a root.
-- ===========================================================================
WITH fixed AS (
    UPDATE categories
    SET parent_id = NULL
    WHERE category_id = 9002 AND parent_id = 9001
    RETURNING category_id, old.parent_id AS old_parent_id
)
INSERT INTO data_corrections (table_name, row_id, column_name, old_value, new_value, reason_code, detail)
SELECT 'categories', category_id, 'parent_id', old_parent_id::text, NULL, 'category_cycle',
       'Promotions (9002) and Seasonal Promotions (9001) were each other''s parent; Promotions made a root'
FROM fixed;

WITH fixed AS (
    UPDATE categories c
    SET parent_id = NULL
    WHERE c.parent_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id)
    RETURNING c.category_id, old.parent_id AS old_parent_id
)
INSERT INTO data_corrections (table_name, row_id, column_name, old_value, new_value, reason_code, detail)
SELECT 'categories', category_id, 'parent_id', old_parent_id::text, NULL, 'category_missing_parent',
       format('Parent %s does not exist; made a root rather than guess where it belongs', old_parent_id)
FROM fixed;

-- ===========================================================================
-- F-06  Implausible quantities. None of these lines is included in its order's
-- total_amount, so the true quantity is recoverable where
--     (total_amount - value of the order's other lines) / unit_price
-- is a whole number. Recoverable lines are corrected; the rest quarantined.
-- ===========================================================================
CREATE TEMP TABLE implausible_lines ON COMMIT DROP AS
SELECT i.order_item_id,
       (o.total_amount - coalesce(others.line_value, 0)) / i.unit_price AS implied_qty,
       others.unpriced_lines
FROM order_items i
JOIN orders o USING (order_id)
CROSS JOIN LATERAL (
    SELECT sum(x.quantity * x.unit_price)               AS line_value,
           count(*) FILTER (WHERE x.unit_price IS NULL) AS unpriced_lines
    FROM order_items x
    WHERE x.order_id = i.order_id AND x.order_item_id <> i.order_item_id
) others
WHERE i.quantity >= :implausible_qty
  AND i.unit_price > 0;

WITH fixed AS (
    UPDATE order_items i
    SET quantity = l.implied_qty
    FROM implausible_lines l
    WHERE i.order_item_id = l.order_item_id
      AND l.unpriced_lines = 0
      AND l.implied_qty = round(l.implied_qty)
      AND l.implied_qty BETWEEN 1 AND :implausible_qty - 1
    RETURNING i.order_item_id, old.quantity AS old_qty, new.quantity AS new_qty
)
INSERT INTO data_corrections (table_name, row_id, column_name, old_value, new_value, reason_code, detail)
SELECT 'order_items', order_item_id, 'quantity', old_qty::text, new_qty::text, 'implausible_quantity',
       'Recovered from the order total: (total_amount - other lines) / unit_price is a whole number'
FROM fixed;

WITH moved AS (
    DELETE FROM order_items i
    WHERE i.quantity >= :implausible_qty
    RETURNING i.*
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'order_items', order_item_id, 'implausible_quantity',
       format('Quantity %s not supported by the order total; true quantity unrecoverable', quantity),
       to_jsonb(moved)
FROM moved;

-- ===========================================================================
-- F-08  Duplicate order lines. Quarantine a later exact copy of a line only
-- where the order total proves the copy was never charged.
-- ===========================================================================
CREATE TEMP TABLE duplicate_lines ON COMMIT DROP AS
SELECT DISTINCT b.order_item_id, b.order_id
FROM order_items a
JOIN order_items b
  ON  a.order_id   = b.order_id
  AND a.product_id = b.product_id
  AND a.quantity   = b.quantity
  AND a.unit_price = b.unit_price
  AND a.order_item_id < b.order_item_id;

CREATE TEMP TABLE confirmed_duplicates ON COMMIT DROP AS
WITH order_value AS (
    SELECT order_id, sum(quantity * unit_price) AS all_lines
    FROM order_items
    WHERE order_id IN (SELECT order_id FROM duplicate_lines)
    GROUP BY order_id
), copy_value AS (
    SELECT d.order_id, sum(i.quantity * i.unit_price) AS copies
    FROM duplicate_lines d
    JOIN order_items i USING (order_item_id)
    GROUP BY d.order_id
)
SELECT d.order_item_id
FROM duplicate_lines d
JOIN order_value v USING (order_id)
JOIN copy_value  c USING (order_id)
JOIN orders      o USING (order_id)
WHERE abs(o.total_amount - (v.all_lines - c.copies)) < 0.01;

WITH moved AS (
    DELETE FROM order_items i
    WHERE i.order_item_id IN (SELECT order_item_id FROM confirmed_duplicates)
    RETURNING i.*
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'order_items', order_item_id, 'duplicate_line',
       'Exact copy of an earlier line in the same order; order total matches only without it',
       to_jsonb(moved)
FROM moved;

-- ===========================================================================
-- F-07  Orphans. Each sits in an ID range outside the real one (test or
-- migration residue). Children move with their parent order.
-- ===========================================================================
WITH moved AS (
    DELETE FROM order_items i
    WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = i.order_id)
    RETURNING i.*
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'order_items', order_item_id, 'orphan_order',
       format('order_id %s does not exist', order_id), to_jsonb(moved)
FROM moved;

CREATE TEMP TABLE quarantined_orders ON COMMIT DROP AS
SELECT o.order_id, 'orphan_customer' AS reason_code,
       format('customer_id %s does not exist', o.customer_id) AS detail
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)
UNION ALL
-- F-12 Orders dated after the extract ends: their real date is unknowable.
SELECT o.order_id, 'date_after_extract',
       format('order_date %s is after the extract ends (%s)', o.order_date, :'extract_end')
FROM orders o
WHERE o.order_date > :'extract_end'::timestamp
  AND EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id);

WITH moved AS (
    DELETE FROM order_items i
    USING quarantined_orders q
    WHERE q.order_id = i.order_id
    RETURNING i.*, q.reason_code AS q_reason
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'order_items', order_item_id, q_reason,
       format('Line of quarantined order %s', order_id),
       to_jsonb(moved) - 'q_reason'
FROM moved;

WITH moved AS (
    DELETE FROM orders o
    USING quarantined_orders q
    WHERE q.order_id = o.order_id
    RETURNING o.*, q.reason_code AS q_reason, q.detail AS q_detail
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'orders', order_id, q_reason, q_detail, to_jsonb(moved) - 'q_reason' - 'q_detail'
FROM moved;

WITH moved AS (
    DELETE FROM inventory_log l
    WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id)
    RETURNING l.*
)
INSERT INTO data_quarantine (source_table, source_id, reason_code, detail, row_data)
SELECT 'inventory_log', log_id, 'orphan_product',
       format('product_id %s does not exist', product_id), to_jsonb(moved)
FROM moved;

-- ===========================================================================
-- F-04  Stock counter vs ledger. The counter is kept: for 42 of the drifting
-- products the gap equals exactly the units sold with no movement row, i.e.
-- the counter moved and the ledger write was lost. One labelled correction
-- per product brings the ledger level with the counter, so from here on
-- "stock = sum of movements" holds for every product and can be enforced.
-- ===========================================================================
CREATE TEMP TABLE stock_drift ON COMMIT DROP AS
SELECT p.product_id,
       p.stock_quantity,
       coalesce(l.net_movement, 0)                    AS ledger_net,
       p.stock_quantity - coalesce(l.net_movement, 0) AS drift
FROM products p
LEFT JOIN (
    SELECT product_id, sum(change_qty) AS net_movement
    FROM inventory_log
    GROUP BY product_id
) l USING (product_id)
WHERE p.stock_quantity <> coalesce(l.net_movement, 0);

INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
SELECT product_id, drift, 'correction', localtimestamp,
       format('Migration reconciliation: counter %s, ledger %s. Counter kept; physical count recommended',
              stock_quantity, ledger_net)
FROM stock_drift;

INSERT INTO data_corrections (table_name, row_id, column_name, old_value, new_value, reason_code, detail)
SELECT 'products', product_id, 'stock_quantity', ledger_net::text, stock_quantity::text, 'stock_ledger_drift',
       format('Ledger said %s, counter said %s; correction movement of %s added to inventory_log',
              ledger_net, stock_quantity, drift)
FROM stock_drift;

-- ===========================================================================
-- F-01  Negative stock: units that were sold but never existed. The shelf
-- cannot hold less than nothing, so stock goes to 0 through a movement the
-- auditor can see, and the product joins the recount list.
-- ===========================================================================
WITH reset AS (
    UPDATE products
    SET stock_quantity = 0
    WHERE stock_quantity < 0
    RETURNING product_id, old.stock_quantity AS old_stock
), movement AS (
    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
    SELECT product_id, -old_stock, 'correction', localtimestamp,
           format('Oversold before migration: %s units sold that did not exist; stock reset to 0', -old_stock)
    FROM reset
)
INSERT INTO data_corrections (table_name, row_id, column_name, old_value, new_value, reason_code, detail)
SELECT 'products', product_id, 'stock_quantity', old_stock::text, '0', 'oversold_negative_stock',
       format('%s units oversold before migration', -old_stock)
FROM reset;

-- ===========================================================================
-- Invariants. If any fails, the whole transaction rolls back.
-- ===========================================================================
DO $$
DECLARE
    bad bigint;
BEGIN
    SELECT count(*) INTO bad FROM orders
    WHERE status NOT IN ('pending', 'shipped', 'completed', 'cancelled', 'refunded');
    IF bad > 0 THEN RAISE EXCEPTION '% orders still have a non-canonical status', bad; END IF;

    SELECT count(*) INTO bad FROM products WHERE stock_quantity < 0;
    IF bad > 0 THEN RAISE EXCEPTION '% products still have negative stock', bad; END IF;

    SELECT count(*) INTO bad
    FROM products p
    LEFT JOIN (SELECT product_id, sum(change_qty) AS net FROM inventory_log GROUP BY product_id) l
           USING (product_id)
    WHERE p.stock_quantity <> coalesce(l.net, 0);
    IF bad > 0 THEN RAISE EXCEPTION '% products: stock counter <> sum of ledger', bad; END IF;

    SELECT count(*) INTO bad FROM order_items
    WHERE quantity >= current_setting('kloudkart.implausible_qty')::int;
    IF bad > 0 THEN RAISE EXCEPTION '% order lines still have implausible quantities', bad; END IF;

    SELECT count(*) INTO bad FROM categories c
    WHERE c.parent_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id);
    IF bad > 0 THEN RAISE EXCEPTION '% categories point to a missing parent', bad; END IF;

    WITH RECURSIVE walk (category_id, path, is_cycle) AS (
        SELECT category_id, ARRAY[category_id], false FROM categories
        UNION ALL
        SELECT c.parent_id, w.path || c.parent_id, c.parent_id = ANY (w.path)
        FROM walk w JOIN categories c ON c.category_id = w.category_id
        WHERE c.parent_id IS NOT NULL AND NOT w.is_cycle
    )
    SELECT count(*) INTO bad FROM walk WHERE is_cycle;
    IF bad > 0 THEN RAISE EXCEPTION 'category tree still contains a cycle'; END IF;

    SELECT (SELECT count(*) FROM orders o
            WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id))
         + (SELECT count(*) FROM order_items i
            WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = i.order_id))
         + (SELECT count(*) FROM inventory_log l
            WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id))
    INTO bad;
    IF bad > 0 THEN RAISE EXCEPTION '% orphan rows remain', bad; END IF;
END
$$;

COMMIT;

-- ===========================================================================
-- Products whose physical stock should be counted before anyone trusts the
-- figure: drift, overselling, or a duplicate line that drained stock twice.
-- ===========================================================================
CREATE OR REPLACE VIEW products_to_recount AS
SELECT p.product_id,
       p.product_name,
       p.stock_quantity,
       string_agg(DISTINCT r.reason_code, ', ' ORDER BY r.reason_code) AS reasons
FROM (
    SELECT row_id AS product_id, reason_code
    FROM data_corrections
    WHERE table_name = 'products' AND column_name = 'stock_quantity'
    UNION ALL
    SELECT (row_data ->> 'product_id')::bigint, reason_code
    FROM data_quarantine
    WHERE source_table = 'order_items' AND reason_code = 'duplicate_line'
) r
JOIN products p USING (product_id)
GROUP BY p.product_id, p.product_name, p.stock_quantity;

COMMENT ON VIEW products_to_recount IS
    'Products whose stock figure was reconciled or inferred during the clean-up; count these shelves first.';

-- Summary of what the clean-up did.
SELECT 'quarantined' AS action, source_table AS target, reason_code, count(*) AS rows
FROM data_quarantine GROUP BY source_table, reason_code
UNION ALL
SELECT 'corrected', table_name || '.' || column_name, reason_code, sum(rows_affected)
FROM data_corrections GROUP BY table_name, column_name, reason_code
ORDER BY action, target, reason_code;
