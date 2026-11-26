-- trigger_only.sql
-- Experiment: "would triggers have fixed the overselling?"
--
-- Builds what that advice usually means in practice, in a THROWAWAY copy of
-- the database (scripts/run_trigger_experiment.sh creates and drops it):
--
--   * the application keeps its existing flow: read the stock, and if there
--     is enough, write the order and its line;
--   * a trigger on order_items takes the stock and writes the sale movement,
--     so "nobody can forget to update stock".
--
-- place_order() below plays the application, so the unmodified race_test.py
-- can drive it. Variant (psql variable :variant):
--   no_check    the stock >= 0 CHECK is dropped: triggers are the only guard
--   with_check  the CHECK from 30_constraints.sql stays in place

\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS place_order(bigint, bigint, integer);

SELECT :'variant' = 'no_check' AS drop_check \gset
\if :drop_check
    ALTER TABLE products DROP CONSTRAINT products_stock_not_negative;
\endif

CREATE FUNCTION order_items_take_stock()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE products
    SET stock_quantity = stock_quantity - NEW.quantity
    WHERE product_id = NEW.product_id;

    INSERT INTO inventory_log (product_id, change_qty, reason, order_id)
    VALUES (NEW.product_id, -NEW.quantity, 'sale', NEW.order_id);

    RETURN NULL;
END
$$;

CREATE TRIGGER order_items_take_stock
    AFTER INSERT ON order_items
    FOR EACH ROW
    EXECUTE FUNCTION order_items_take_stock();

-- The application's flow: check, then write. The trigger does the rest.
CREATE FUNCTION place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer)
RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_stock    integer;
    v_price    numeric(12, 2);
    v_order_id bigint;
BEGIN
    SELECT stock_quantity, price INTO v_stock, v_price
    FROM products WHERE product_id = p_product_id;

    IF v_stock < p_quantity THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Out of stock';
        RETURN;
    END IF;

    INSERT INTO orders (customer_id, total_amount)
    VALUES (p_customer_id, v_price * p_quantity)
    RETURNING order_id INTO v_order_id;

    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    RETURN QUERY SELECT true, v_order_id, 'Order placed';
END
$$;
