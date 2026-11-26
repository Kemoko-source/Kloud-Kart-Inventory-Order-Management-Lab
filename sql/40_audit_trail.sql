-- 40_audit_trail.sql
-- Nana's fourth ask: "a trail of every stock movement, sale, restock,
-- correction, that an auditor could walk through after the fact."
--
-- 1. Every sale movement points at the order that caused it (it used to be
--    linkable only by matching timestamps).
-- 2. The ledger is append-only: a movement can never be edited, and any
--    deletion is itself recorded with who did it and when.

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Link movements to orders
-- ---------------------------------------------------------------------------
ALTER TABLE inventory_log ADD COLUMN order_id bigint;

COMMENT ON COLUMN inventory_log.order_id IS
    'Order that caused this movement (sales). NULL for restocks, corrections, and for sales whose order is in data_quarantine.';

-- A historical sale row is written at its order's timestamp with the line's
-- product, so (product_id, order_date) identifies the order. Verified before
-- writing this: 261,574 sale rows match exactly one order, none match two,
-- and the 394 that match none all belong to quarantined orders.
UPDATE inventory_log l
SET order_id = m.order_id
FROM (
    SELECT l2.log_id, min(o.order_id) AS order_id
    FROM inventory_log l2
    JOIN order_items i ON i.product_id = l2.product_id
    JOIN orders o      ON o.order_id = i.order_id AND o.order_date = l2.created_at
    WHERE l2.reason = 'sale'
    GROUP BY l2.log_id
    HAVING count(DISTINCT o.order_id) = 1
) m
WHERE m.log_id = l.log_id;

-- DEFERRABLE INITIALLY DEFERRED: checked at commit, not per statement, so a
-- transaction may remove an order and its movements in either order. (The
-- provided race_test.py cleans up orders before their movements.)
ALTER TABLE inventory_log
    ADD CONSTRAINT inventory_log_order_fk FOREIGN KEY (order_id) REFERENCES orders (order_id)
        DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX inventory_log_order_id_idx ON inventory_log (order_id);

-- ---------------------------------------------------------------------------
-- 2. Append-only ledger
-- UPDATE and TRUNCATE are refused outright: a wrong movement is fixed by
-- adding a correction, never by rewriting history. DELETE is allowed (test
-- fixtures and data-protection requests need it) but every deleted row is
-- copied to inventory_log_deleted first, with the database user and time.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS inventory_log_deleted;

CREATE TABLE inventory_log_deleted (
    log_id      bigint      NOT NULL,
    row_data    jsonb       NOT NULL,
    deleted_by  text        NOT NULL DEFAULT current_user,
    deleted_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX inventory_log_deleted_log_id_idx ON inventory_log_deleted (log_id);

COMMENT ON TABLE inventory_log_deleted IS
    'Every row ever deleted from inventory_log, with who deleted it and when.';

CREATE OR REPLACE FUNCTION inventory_log_refuse_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'inventory_log is append-only: % is not allowed; record a correction movement instead', TG_OP
        USING ERRCODE = 'insufficient_privilege',
              HINT    = 'INSERT a row with reason = ''correction'' and a note explaining it.';
END
$$;

CREATE OR REPLACE FUNCTION inventory_log_archive_deleted()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO inventory_log_deleted (log_id, row_data)
    SELECT d.log_id, to_jsonb(d)
    FROM deleted_rows d;
    RETURN NULL;
END
$$;

CREATE TRIGGER inventory_log_no_update
    BEFORE UPDATE ON inventory_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION inventory_log_refuse_change();

CREATE TRIGGER inventory_log_no_truncate
    BEFORE TRUNCATE ON inventory_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION inventory_log_refuse_change();

-- Statement-level with a transition table: one INSERT per DELETE statement,
-- however many rows it removes.
CREATE TRIGGER inventory_log_archive_deleted
    AFTER DELETE ON inventory_log
    REFERENCING OLD TABLE AS deleted_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION inventory_log_archive_deleted();

COMMIT;
