-- 50_place_order.sql
-- Nana's first ask: two customers racing for the last unit, exactly one gets
-- it, the other gets an instant, clear "out of stock", every time. Built for
-- flash-sale spikes of ~400 orders in ten seconds on one product.
--
-- Contract (fixed by race_test.py, which stands in for the application):
--     place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer)
--     RETURNS TABLE (success boolean, order_id bigint, message text)
--
-- How it cannot oversell
-- ----------------------
-- Stock is taken with ONE conditional statement:
--
--     UPDATE products SET stock_quantity = stock_quantity - qty
--     WHERE product_id = ... AND stock_quantity >= qty
--
-- Under READ COMMITTED, a second buyer's UPDATE on the same row waits for the
-- first buyer's row lock. When the first commits, PostgreSQL re-reads the
-- now-current row and re-checks the WHERE clause. If the stock is gone, the
-- UPDATE matches nothing and the caller is told "out of stock". The check and
-- the decrement are one atomic step, so no interleaving can sell a unit twice,
-- and there is no serialization failure to retry. The CHECK
-- (stock_quantity >= 0) from 30_constraints.sql stays as a backstop for any
-- other code path.
--
-- One unit of work: the stock decrement, the order, its line and the sale
-- movement are written in the single transaction of the calling statement. If
-- any part fails, all of it rolls back.

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION place_order(
    p_customer_id bigint,
    p_product_id  bigint,
    p_quantity    integer
)
RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql
VOLATILE
SET search_path = public, pg_temp     -- callers cannot redirect table names to their own objects
AS $$
#variable_conflict use_column
DECLARE
    v_unit_price  numeric(12, 2);
    v_available   integer;
    v_order_id    bigint;
    v_placed_at   timestamp := localtimestamp;   -- one timestamp for the order and its movement
BEGIN
    -- Refusals that need no lock are answered before touching stock.
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Invalid quantity: order at least 1 unit';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, format('Unknown customer %s', p_customer_id);
        RETURN;
    END IF;

    -- Fast refusal. A plain read takes no lock, so when a flash sale has
    -- already sold out, the hundreds of late buyers are answered at once
    -- instead of queueing behind the row lock only to be refused. This read
    -- can only refuse early, never sell: every sale still goes through the
    -- atomic UPDATE below, so a stale value here cannot cause an oversell.
    SELECT p.stock_quantity INTO v_available
    FROM products p
    WHERE p.product_id = p_product_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::bigint, format('Unknown product %s', p_product_id);
        RETURN;
    END IF;

    IF v_available < p_quantity THEN
        RETURN QUERY SELECT false, NULL::bigint,
            format('Out of stock: %s requested, %s available', p_quantity, v_available);
        RETURN;
    END IF;

    -- The check and the decrement in one atomic statement (see header).
    UPDATE products p
    SET stock_quantity = p.stock_quantity - p_quantity
    WHERE p.product_id = p_product_id
      AND p.stock_quantity >= p_quantity
    RETURNING p.price INTO v_unit_price;

    IF NOT FOUND THEN
        -- Lost the race: the stock went while this buyer waited for the lock.
        SELECT p.stock_quantity INTO v_available
        FROM products p
        WHERE p.product_id = p_product_id;

        RETURN QUERY SELECT false, NULL::bigint,
            format('Out of stock: %s requested, %s available', p_quantity, v_available);
        RETURN;
    END IF;

    -- New orders reserve stock at checkout, so they start as 'pending'
    -- (awaiting fulfilment) with the stock already taken.
    INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (p_customer_id, v_placed_at, 'pending', v_unit_price * p_quantity)
    RETURNING order_id INTO v_order_id;

    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_unit_price);

    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, order_id)
    VALUES (p_product_id, -p_quantity, 'sale', v_placed_at, v_order_id);

    RETURN QUERY SELECT true, v_order_id, format('Order %s placed: %s unit(s)', v_order_id, p_quantity);
END
$$;

COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'Places a single-product order atomically: takes stock, writes order, line and sale movement, or reports out of stock. Never oversells.';
