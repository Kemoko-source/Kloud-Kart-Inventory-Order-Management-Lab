-- cancel_order_test.sql
-- Single-session behaviour of cancel_order(). Concurrency is covered by
-- tests/cancel_race_test.py. Runs in one transaction that is rolled back.
--
--     docker compose exec -T db psql -f /workspace/tests/cancel_order_test.sql

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

BEGIN;

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

-- Stock counter equals the sum of the product's movements.
CREATE FUNCTION pg_temp.ledger_matches(p_product_id bigint)
RETURNS boolean
LANGUAGE sql
AS $$
    SELECT p.stock_quantity = coalesce((SELECT sum(change_qty) FROM inventory_log l WHERE l.product_id = p.product_id), 0)
    FROM products p WHERE p.product_id = p_product_id
$$;

SELECT min(customer_id) AS cid FROM customers \gset

-- Seed the product through a restock movement so the ledger starts level.
INSERT INTO products (product_name, price, stock_quantity)
VALUES ('CANCEL TEST PRODUCT', 40, 5)
RETURNING product_id AS pid \gset
INSERT INTO inventory_log (product_id, change_qty, reason) VALUES (:pid, 5, 'restock');

-- Place, then cancel.
SELECT order_id AS oid FROM place_order(:cid, :pid, 3) \gset
SELECT success, units_returned, message FROM cancel_order(:oid, 'customer changed their mind') \gset

SELECT pg_temp.check('cancelling a new order succeeds and returns its 3 units',
    :'success'::boolean AND :units_returned = 3);
SELECT pg_temp.check('stock is back to 5',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 5);
SELECT pg_temp.check('order is now cancelled',
    (SELECT status FROM orders WHERE order_id = :oid) = 'cancelled');
SELECT pg_temp.check('a cancellation movement is linked to the order, with the note',
    (SELECT count(*) = 1 FROM inventory_log
     WHERE order_id = :oid AND reason = 'cancellation' AND change_qty = 3
       AND note = 'customer changed their mind'));
SELECT pg_temp.check('stock counter still equals the ledger',
    pg_temp.ledger_matches(:pid));

-- A second cancellation is refused and returns nothing.
SELECT success, units_returned, message FROM cancel_order(:oid) \gset
SELECT pg_temp.check('cancelling twice is refused: "already cancelled"',
    NOT :'success'::boolean AND :units_returned = 0 AND :'message' ILIKE '%already cancelled%');
SELECT pg_temp.check('... and stock is not returned twice',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 5);

-- Orders that are not pending cannot be cancelled.
SELECT order_id AS shipped_oid FROM place_order(:cid, :pid, 1) \gset
UPDATE orders SET status = 'shipped' WHERE order_id = :shipped_oid;
SELECT success, message FROM cancel_order(:shipped_oid) \gset
SELECT pg_temp.check('a shipped order cannot be cancelled',
    NOT :'success'::boolean AND :'message' ILIKE '%shipped%');
SELECT pg_temp.check('... and its stock stays sold',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 4);

SELECT success, message FROM cancel_order(-1) \gset
SELECT pg_temp.check('an unknown order is refused',
    NOT :'success'::boolean AND :'message' ILIKE '%unknown order%');

-- A historical pending order never took stock: cancelling it returns nothing.
SELECT o.order_id AS old_oid, i.product_id AS old_pid, p.stock_quantity AS old_stock
FROM orders o
JOIN order_items i USING (order_id)
JOIN products p ON p.product_id = i.product_id
WHERE o.status = 'pending'
  AND NOT EXISTS (SELECT 1 FROM inventory_log l WHERE l.order_id = o.order_id)
ORDER BY o.order_id
LIMIT 1 \gset

SELECT success, units_returned FROM cancel_order(:old_oid) \gset
SELECT pg_temp.check('a historical pending order is cancelled ...',
    :'success'::boolean AND (SELECT status FROM orders WHERE order_id = :old_oid) = 'cancelled');
SELECT pg_temp.check('... but returns no stock, because it never took any',
    :units_returned = 0
    AND (SELECT stock_quantity FROM products WHERE product_id = :old_pid) = :old_stock);

-- A multi-product order gets every product back.
INSERT INTO products (product_name, price, stock_quantity)
VALUES ('CANCEL TEST PRODUCT B', 10, 8)
RETURNING product_id AS pid_b \gset
INSERT INTO inventory_log (product_id, change_qty, reason) VALUES (:pid_b, 10, 'restock'), (:pid_b, -2, 'sale');

INSERT INTO orders (customer_id, status, total_amount) VALUES (:cid, 'pending', 80)
RETURNING order_id AS multi_oid \gset
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (:multi_oid, :pid, 1, 40), (:multi_oid, :pid_b, 4, 10);
UPDATE products SET stock_quantity = stock_quantity - 1 WHERE product_id = :pid;
UPDATE products SET stock_quantity = stock_quantity - 4 WHERE product_id = :pid_b;
INSERT INTO inventory_log (product_id, change_qty, reason, order_id) VALUES
    (:pid, -1, 'sale', :multi_oid), (:pid_b, -4, 'sale', :multi_oid);

SELECT units_returned FROM cancel_order(:multi_oid) \gset
SELECT pg_temp.check('a two-product order returns every unit (1 + 4)',
    :units_returned = 5);
SELECT pg_temp.check('both products are back where they started, ledger level',
    (SELECT stock_quantity FROM products WHERE product_id = :pid) = 4
    AND (SELECT stock_quantity FROM products WHERE product_id = :pid_b) = 8
    AND pg_temp.ledger_matches(:pid) AND pg_temp.ledger_matches(:pid_b));

-- The new reason obeys the sign rule like every other.
SAVEPOINT before_bad_sign;
DO $$
BEGIN
    INSERT INTO inventory_log (product_id, change_qty, reason)
    VALUES ((SELECT min(product_id) FROM products), -1, 'cancellation');
    RAISE EXCEPTION 'FAIL  a negative cancellation movement was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'ok    a cancellation movement must add stock';
END
$$;
ROLLBACK TO SAVEPOINT before_bad_sign;

ROLLBACK;

\echo 'PASSED: all cancel_order tests'
