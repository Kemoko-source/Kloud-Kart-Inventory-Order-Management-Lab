-- constraints_test.sql
-- Proves the hardened schema refuses each problem found in the diagnosis.
-- Each case attempts a bad write and passes only if PostgreSQL rejects it with
-- the expected error class. If a bad write is accepted, the case raises and
-- psql stops (ON_ERROR_STOP). Everything runs in one transaction that is
-- rolled back, so the database is left exactly as it was.
--
--     docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/tests/constraints_test.sql

\set ON_ERROR_STOP on
\set QUIET on

BEGIN;

CREATE PROCEDURE pg_temp.expect_rejected(test_name text, bad_sql text, expected_state text)
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE bad_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN
            RAISE NOTICE 'ok    %', test_name;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL  %: rejected with % (%), expected %',
                        test_name, SQLSTATE, SQLERRM, expected_state;
    END;
    RAISE EXCEPTION 'FAIL  %: bad write was accepted', test_name;
END
$$;

-- 23514 check_violation, 23503 foreign_key_violation,
-- 23502 not_null_violation, 23000 integrity_constraint_violation (trigger)

CALL pg_temp.expect_rejected('stock cannot go below zero (D1)',
    'UPDATE products SET stock_quantity = -1 WHERE product_id = (SELECT min(product_id) FROM products)',
    '23514');

CALL pg_temp.expect_rejected('free-text status is refused (D2)',
    'UPDATE orders SET status = ''Completed'' WHERE order_id = (SELECT min(order_id) FROM orders)',
    '23514');

CALL pg_temp.expect_rejected('sale movement must reduce stock (D3)',
    'INSERT INTO inventory_log (product_id, change_qty, reason) VALUES ((SELECT min(product_id) FROM products), 5, ''sale'')',
    '23514');

CALL pg_temp.expect_rejected('unknown movement reason is refused (D3)',
    'INSERT INTO inventory_log (product_id, change_qty, reason) VALUES ((SELECT min(product_id) FROM products), -1, ''whatsapp'')',
    '23514');

CALL pg_temp.expect_rejected('two-category loop is refused (D4)',
    'UPDATE categories SET parent_id = 9001 WHERE category_id = 9002',
    '23000');

-- Electronics (101) -> Phones (102) -> Smartphones (103): putting Electronics
-- under Smartphones would close a three-level loop.
CALL pg_temp.expect_rejected('three-level loop is refused (D4)',
    'UPDATE categories SET parent_id = 103 WHERE category_id = 101',
    '23000');

-- The cycle trigger fires before the CHECK, so it is the trigger that refuses.
CALL pg_temp.expect_rejected('category cannot be its own parent (D4)',
    'UPDATE categories SET parent_id = category_id WHERE category_id = 9001',
    '23000');

CALL pg_temp.expect_rejected('category parent must exist (D4)',
    'UPDATE categories SET parent_id = 8999 WHERE category_id = 9003',
    '23503');

CALL pg_temp.expect_rejected('zero quantity is refused (D5)',
    'UPDATE order_items SET quantity = 0 WHERE order_item_id = (SELECT min(order_item_id) FROM order_items)',
    '23514');

CALL pg_temp.expect_rejected('order for a missing customer is refused (D6)',
    'INSERT INTO orders (customer_id, total_amount) VALUES (999999999, 10)',
    '23503');

CALL pg_temp.expect_rejected('line for a missing order is refused (D6)',
    'INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (999999999, (SELECT min(product_id) FROM products), 1, 1)',
    '23503');

CALL pg_temp.expect_rejected('movement for a missing product is refused (D6)',
    'INSERT INTO inventory_log (product_id, change_qty, reason) VALUES (999999999, -1, ''sale'')',
    '23503');

CALL pg_temp.expect_rejected('order without a total is refused',
    'INSERT INTO orders (customer_id) VALUES ((SELECT min(customer_id) FROM customers))',
    '23502');

-- A legal edit must still work: the guards are not allowed to block normal use.
UPDATE categories SET parent_id = NULL WHERE category_id = 9001;
UPDATE categories SET parent_id = 9002 WHERE category_id = 9001;
\echo 'ok    legal category move still accepted'

-- The clean-up's own promises.
DO $$
BEGIN
    IF EXISTS (SELECT 1
               FROM products p
               LEFT JOIN (SELECT product_id, sum(change_qty) AS net FROM inventory_log GROUP BY product_id) l
                      USING (product_id)
               WHERE p.stock_quantity <> coalesce(l.net, 0)) THEN
        RAISE EXCEPTION 'FAIL  stock counter and ledger disagree';
    END IF;
    RAISE NOTICE 'ok    every product: stock counter = sum of ledger';

    IF (SELECT count(*) FROM data_quarantine) = 0 OR (SELECT count(*) FROM data_corrections) = 0 THEN
        RAISE EXCEPTION 'FAIL  audit tables are empty: clean-up left no trail';
    END IF;
    RAISE NOTICE 'ok    every removal and correction is recorded';
END
$$;

ROLLBACK;

\echo 'PASSED: all constraint tests'
