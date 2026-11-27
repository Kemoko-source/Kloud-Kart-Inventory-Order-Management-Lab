-- 80_cancel_order.sql
-- Improvement beyond the brief: cancelling an order gives its stock back.
--
-- Why it is needed. place_order() takes stock at checkout (decisions/ADR-002-atomic-stock-decrement-at-checkout.md), so
-- a pending order holds real units. Without a cancellation path, every
-- cancelled order would keep its units off the shelf forever, and the stock
-- figures would drift back to the untrustworthy state Nana started from.
--
-- What it returns. Exactly what the ledger says this order took and has not
-- yet given back, per product: the sum of the order's movements in
-- inventory_log. NOT the order's line quantities. The 15,983 historical
-- pending orders never took stock (stock used to move at shipping), so
-- returning their line quantities would invent up to 53,223 phantom units.
-- Driving it from the ledger also makes a repeated cancellation return nothing.
--
-- Concurrency. The status change is one conditional UPDATE (pending ->
-- cancelled), the same pattern as place_order(): of two simultaneous
-- cancellations, exactly one changes the row and returns stock. Products are
-- locked in product_id order so two cancellations sharing products cannot
-- deadlock.

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- A distinct movement reason: an auditor must be able to tell an order that
-- never left the warehouse ('cancellation') from goods a customer handed back
-- ('return').
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_log
    DROP CONSTRAINT inventory_log_reason_valid,
    DROP CONSTRAINT inventory_log_sign_matches_reason;

ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_reason_valid
        CHECK (reason IN ('sale', 'restock', 'return', 'cancellation', 'damage', 'correction', 'stock_take')),
    ADD CONSTRAINT inventory_log_sign_matches_reason
        CHECK (   (reason IN ('sale', 'damage')                   AND change_qty < 0)
               OR (reason IN ('restock', 'return', 'cancellation') AND change_qty > 0)
               OR (reason = 'correction'                          AND change_qty <> 0)
               OR (reason = 'stock_take'                          AND change_qty = 0));

CREATE OR REPLACE FUNCTION cancel_order(
    p_order_id bigint,
    p_note     text DEFAULT NULL
)
RETURNS TABLE (success boolean, units_returned integer, message text)
LANGUAGE plpgsql
VOLATILE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_status        text;
    v_units         integer;
    v_cancelled_at  timestamp := localtimestamp;
BEGIN
    -- The status check and change in one atomic statement.
    UPDATE orders o
    SET status = 'cancelled'
    WHERE o.order_id = p_order_id
      AND o.status = 'pending';

    IF NOT FOUND THEN
        SELECT o.status INTO v_status FROM orders o WHERE o.order_id = p_order_id;

        IF NOT FOUND THEN
            RETURN QUERY SELECT false, 0, format('Unknown order %s', p_order_id);
        ELSIF v_status = 'cancelled' THEN
            RETURN QUERY SELECT false, 0, format('Order %s is already cancelled', p_order_id);
        ELSE
            RETURN QUERY SELECT false, 0,
                format('Order %s is %s; only pending orders can be cancelled', p_order_id, v_status);
        END IF;
        RETURN;
    END IF;

    -- Lock the products this order still holds stock of, in a fixed order.
    PERFORM 1
    FROM products p
    WHERE p.product_id IN (SELECT l.product_id FROM inventory_log l WHERE l.order_id = p_order_id)
    ORDER BY p.product_id
    FOR NO KEY UPDATE;

    -- Give back, per product, whatever the ledger says is still out.
    WITH still_out AS (
        SELECT l.product_id, -sum(l.change_qty)::integer AS units
        FROM inventory_log l
        WHERE l.order_id = p_order_id
        GROUP BY l.product_id
        HAVING sum(l.change_qty) < 0
    ),
    restocked AS (
        UPDATE products p
        SET stock_quantity = p.stock_quantity + s.units
        FROM still_out s
        WHERE p.product_id = s.product_id
        RETURNING p.product_id, s.units
    ),
    logged AS (
        INSERT INTO inventory_log (product_id, change_qty, reason, created_at, order_id, note)
        SELECT r.product_id, r.units, 'cancellation', v_cancelled_at, p_order_id, p_note
        FROM restocked r
        RETURNING change_qty
    )
    SELECT coalesce(sum(change_qty), 0)::integer INTO v_units FROM logged;

    RETURN QUERY SELECT true, v_units,
        CASE WHEN v_units > 0
             THEN format('Order %s cancelled; %s unit(s) returned to stock', p_order_id, v_units)
             ELSE format('Order %s cancelled; it had not reserved any stock', p_order_id)
        END;
END
$$;

COMMENT ON FUNCTION cancel_order(bigint, text) IS
    'Cancels a pending order and returns exactly the stock the ledger says it took, with a cancellation movement.';

COMMIT;
