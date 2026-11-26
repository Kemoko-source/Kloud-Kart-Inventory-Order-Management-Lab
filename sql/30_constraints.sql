-- 30_constraints.sql
-- Make the database refuse the problems 20_clean.sql removed, so they cannot
-- come back through the application, a script or a tired human.
--
-- Status and movement reasons use CHECK lists rather than lookup tables: the
-- vocabularies are small and stable, the movement rule needs a CHECK anyway
-- (sign depends on reason), and adding a value is one ALTER, documented in
-- docs/02_design_decisions.md.

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Required values
-- ---------------------------------------------------------------------------
ALTER TABLE categories
    ALTER COLUMN category_name SET NOT NULL;

ALTER TABLE products
    ALTER COLUMN product_name   SET NOT NULL,
    ALTER COLUMN price          SET NOT NULL,
    ALTER COLUMN stock_quantity SET NOT NULL,
    ALTER COLUMN created_at     SET DEFAULT localtimestamp;

ALTER TABLE customers
    ALTER COLUMN full_name     SET NOT NULL,
    ALTER COLUMN email         SET NOT NULL,
    ALTER COLUMN registered_at SET DEFAULT localtimestamp;

ALTER TABLE orders
    ALTER COLUMN customer_id  SET NOT NULL,
    ALTER COLUMN order_date   SET NOT NULL,
    ALTER COLUMN order_date   SET DEFAULT localtimestamp,
    ALTER COLUMN status       SET NOT NULL,
    ALTER COLUMN status       SET DEFAULT 'pending',
    ALTER COLUMN total_amount SET NOT NULL;

-- unit_price stays nullable: 148 historical lines have no recorded price and
-- inventing one would falsify revenue. New lines always carry one (place_order).
ALTER TABLE order_items
    ALTER COLUMN order_id   SET NOT NULL,
    ALTER COLUMN product_id SET NOT NULL,
    ALTER COLUMN quantity   SET NOT NULL;

ALTER TABLE inventory_log
    ALTER COLUMN product_id SET NOT NULL,
    ALTER COLUMN change_qty SET NOT NULL,
    ALTER COLUMN reason     SET NOT NULL,
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN created_at SET DEFAULT localtimestamp;

-- ---------------------------------------------------------------------------
-- Business rules
-- ---------------------------------------------------------------------------
ALTER TABLE products
    ADD CONSTRAINT products_stock_not_negative CHECK (stock_quantity >= 0),   -- the last line of defence against overselling
    ADD CONSTRAINT products_price_not_negative CHECK (price >= 0);

ALTER TABLE orders
    ADD CONSTRAINT orders_status_valid
        CHECK (status IN ('pending', 'shipped', 'completed', 'cancelled', 'refunded')),
    ADD CONSTRAINT orders_total_not_negative CHECK (total_amount >= 0);

ALTER TABLE order_items
    ADD CONSTRAINT order_items_quantity_positive      CHECK (quantity > 0),
    ADD CONSTRAINT order_items_unit_price_not_negative CHECK (unit_price >= 0);

-- A movement's sign must agree with its reason: sales and damage take stock
-- out, restocks and returns put it in, a stock-take records a count with no
-- change, and only a correction may go either way (and must change something).
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_reason_valid
        CHECK (reason IN ('sale', 'restock', 'return', 'damage', 'correction', 'stock_take')),
    ADD CONSTRAINT inventory_log_sign_matches_reason
        CHECK (   (reason IN ('sale', 'damage')     AND change_qty < 0)
               OR (reason IN ('restock', 'return')  AND change_qty > 0)
               OR (reason = 'correction'            AND change_qty <> 0)
               OR (reason = 'stock_take'            AND change_qty = 0));

ALTER TABLE categories
    ADD CONSTRAINT categories_not_own_parent CHECK (parent_id <> category_id);

-- ---------------------------------------------------------------------------
-- Foreign keys, each with the index PostgreSQL does not create for you.
-- Without these indexes every join from parent to child, and every delete of
-- a parent, scans the whole child table.
-- ---------------------------------------------------------------------------
ALTER TABLE categories
    ADD CONSTRAINT categories_parent_fk FOREIGN KEY (parent_id) REFERENCES categories (category_id);
CREATE INDEX categories_parent_id_idx ON categories (parent_id);

ALTER TABLE products
    ADD CONSTRAINT products_category_fk FOREIGN KEY (category_id) REFERENCES categories (category_id);
CREATE INDEX products_category_id_idx ON products (category_id);

ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (customer_id);
CREATE INDEX orders_customer_id_idx ON orders (customer_id);

ALTER TABLE order_items
    ADD CONSTRAINT order_items_order_fk   FOREIGN KEY (order_id)   REFERENCES orders (order_id),
    ADD CONSTRAINT order_items_product_fk FOREIGN KEY (product_id) REFERENCES products (product_id);
CREATE INDEX order_items_order_id_idx   ON order_items (order_id);
CREATE INDEX order_items_product_id_idx ON order_items (product_id);

ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_product_fk FOREIGN KEY (product_id) REFERENCES products (product_id);
CREATE INDEX inventory_log_product_time_idx ON inventory_log (product_id, created_at);

-- Duplicate accounts (diagnosis #9) are not merged, so email cannot be
-- UNIQUE yet; this index makes finding an account by email fast meanwhile.
CREATE INDEX customers_email_idx ON customers (email);

-- ---------------------------------------------------------------------------
-- Category tree guard. A foreign key cannot stop A -> B -> A, and a loop makes
-- every recursive rollup run forever (diagnosis D4). This trigger walks up
-- from the proposed parent and refuses the change if it reaches the row
-- itself. A transaction-level advisory lock serialises tree edits so two
-- concurrent edits cannot each pass the check and together close a loop.
-- (Upgrading the table lock instead would deadlock two such edits.) Category
-- edits are rare admin actions, so the serialisation costs nothing in practice.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION categories_prevent_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('categories_tree'));

    IF EXISTS (
        WITH RECURSIVE ancestors (category_id, path) AS (
            SELECT c.category_id, ARRAY[c.category_id]
            FROM categories c
            WHERE c.category_id = NEW.parent_id
            UNION ALL
            SELECT c.parent_id, a.path || c.parent_id
            FROM ancestors a
            JOIN categories c ON c.category_id = a.category_id
            WHERE c.parent_id IS NOT NULL
              AND NOT c.parent_id = ANY (a.path)
        )
        SELECT 1 FROM ancestors WHERE category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION 'category % cannot have parent %: that would create a loop in the category tree',
                        NEW.category_id, NEW.parent_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS categories_prevent_cycle ON categories;
CREATE TRIGGER categories_prevent_cycle
    BEFORE INSERT OR UPDATE OF parent_id ON categories
    FOR EACH ROW
    EXECUTE FUNCTION categories_prevent_cycle();

COMMIT;

ANALYZE;
