-- place_order_test.sql
-- Single-session behaviour of place_order() and the audit trail, the cases
-- race_test.py does not cover. Concurrency itself is race_test.py's job.
-- Runs in one transaction that is rolled back.
--
--     docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/tests/place_order_test.sql

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

BEGIN;

-- A function, not a procedure: CALL arguments may not contain subqueries.
CREATE FUNCTION pg_temp.check(test_name text, condition boolean)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF condition IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL  %', test_name;
    END IF;
    RAISE NOTICE 'ok    %', test_name;
END
$$;

INSERT INTO products (product_name, price, stock_quantity)
VALUES ('PLACE ORDER TEST PRODUCT', 25.50, 3)
RETURNING product_id AS pid \gset

SELECT min(customer_id) AS cid FROM customers \gset

-- A successful order writes order, line and movement, all linked.
SELECT success, order_id AS oid, message FROM place_order(:cid, :pid, 2) \gset

SELECT pg_temp.check('success returns true and an order id',
    :'success'::boolean AND :'oid' <> '');
SELECT pg_temp.check('stock taken: 3 - 2 = 1',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 1);
SELECT pg_temp.check('order written as pending with total = price x quantity',
    (SELECT status = 'pending' AND total_amount = 51.00 FROM orders WHERE order_id = :oid));
SELECT pg_temp.check('line written at the price paid',
    (SELECT quantity = 2 AND unit_price = 25.50 FROM order_items WHERE order_id = :oid AND product_id = :pid));
SELECT pg_temp.check('sale movement written and linked to the order',
    (SELECT count(*) = 1 FROM inventory_log
     WHERE order_id = :oid AND product_id = :pid AND change_qty = -2 AND reason = 'sale'));
SELECT pg_temp.check('order and movement share one timestamp',
    (SELECT o.order_date = l.created_at FROM orders o JOIN inventory_log l USING (order_id) WHERE o.order_id = :oid));

-- Refusals: success = false, no order id, nothing written.
SELECT count(*) AS orders_before FROM orders \gset

-- \gset leaves a variable unset for a NULL column, so test NULL inside the query.
SELECT success, order_id IS NULL AS no_order_id, message FROM place_order(:cid, :pid, 5) \gset
SELECT pg_temp.check('more than available: refused with "out of stock" and no order id',
    NOT :'success'::boolean AND :'no_order_id'::boolean AND :'message' ILIKE '%out of stock%');

SELECT success, message FROM place_order(:cid, :pid, 0) \gset
SELECT pg_temp.check('zero quantity refused', NOT :'success'::boolean AND :'message' ILIKE '%quantity%');

SELECT success, message FROM place_order(:cid, :pid, -1) \gset
SELECT pg_temp.check('negative quantity refused', NOT :'success'::boolean);

SELECT success, message FROM place_order(-1, :pid, 1) \gset
SELECT pg_temp.check('unknown customer refused', NOT :'success'::boolean AND :'message' ILIKE '%customer%');

SELECT success, message FROM place_order(:cid, -1, 1) \gset
SELECT pg_temp.check('unknown product refused', NOT :'success'::boolean AND :'message' ILIKE '%product%');

SELECT pg_temp.check('refusals wrote no orders',
    (SELECT count(*) FROM orders) = :orders_before);
SELECT pg_temp.check('refusals left stock untouched',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 1);

-- Selling the last unit leaves exactly zero.
SELECT success FROM place_order(:cid, :pid, 1) \gset
SELECT pg_temp.check('last unit sold, stock exactly 0',
    :'success'::boolean AND (SELECT stock_quantity FROM products WHERE product_id = :pid) = 0);

-- The ledger is append-only.
SAVEPOINT before_update;
DO $$
BEGIN
    UPDATE inventory_log SET change_qty = -1 WHERE log_id = (SELECT max(log_id) FROM inventory_log);
    RAISE EXCEPTION 'FAIL  inventory_log accepted an UPDATE';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok    inventory_log refuses UPDATE';
END
$$;
ROLLBACK TO SAVEPOINT before_update;

SELECT max(log_id) AS last_log FROM inventory_log \gset
DELETE FROM inventory_log WHERE log_id = :last_log;
SELECT pg_temp.check('deleted movement is archived with who and when',
    (SELECT count(*) = 1 FROM inventory_log_deleted
     WHERE log_id = :last_log AND deleted_by = current_user AND row_data ->> 'reason' = 'sale'));

-- Historical sales were linked to their orders.
SELECT pg_temp.check('every historical sale of a live order is linked to it',
    NOT EXISTS (SELECT 1 FROM inventory_log l
                JOIN order_items i ON i.product_id = l.product_id
                JOIN orders o ON o.order_id = i.order_id AND o.order_date = l.created_at
                WHERE l.reason = 'sale' AND l.order_id IS NULL));

ROLLBACK;

\echo 'PASSED: all place_order and audit trail tests'
