-- monday_report_test.sql
-- The Monday report's numbers agree with a direct count of the orders, its
-- definitions (what counts as spent, where the window starts and ends) hold
-- at the boundaries, and the summary agrees with the monthly detail.
-- Runs in one transaction that is rolled back.
--
--     docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/tests/monday_report_test.sql

\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

\set as_of        '2026-09-07'
\set window_start '2025-09-01'
\set window_end   '2026-09-01'

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

-- Snapshot the report and its monthly detail once; the checks read the
-- snapshots. Autovacuum never analyzes temp tables, and without statistics the
-- planner re-ran the detail function once per customer (40,420 times).
CREATE TEMP TABLE report AS SELECT * FROM monday_customer_report(:'as_of');
CREATE TEMP TABLE detail AS
    SELECT customer_id, array_agg(spend ORDER BY month) AS spends
    FROM customer_monthly_spend(:'as_of')
    GROUP BY customer_id;
ANALYZE report;
ANALYZE detail;

SELECT pg_temp.check('every customer appears exactly once',
    (SELECT count(*) = count(DISTINCT customer_id) AND count(*) = (SELECT count(*) FROM customers) FROM report));

-- Joins of two 40k-row inputs are checked with count(*) = 0, not NOT EXISTS:
-- inside EXISTS the planner hopes to stop at the first row and picks a nested
-- loop, which compares all 1.6 billion pairs when (as here) nothing differs.
SELECT pg_temp.check('total spent and order count match a direct count, customer by customer',
    0 = (
        SELECT count(*)
        FROM report r
        LEFT JOIN (SELECT customer_id, sum(total_amount) AS spent, count(*) AS n
                   FROM orders
                   WHERE status IN ('completed', 'shipped') AND order_date < :'window_end'
                   GROUP BY customer_id) d USING (customer_id)
        WHERE r.total_spent <> coalesce(d.spent, 0) OR r.order_count <> coalesce(d.n, 0)));

SELECT pg_temp.check('12 months, starting at the window start',
    NOT EXISTS (SELECT 1 FROM report
                WHERE cardinality(monthly_spend) <> 12 OR cardinality(running_total) <> 12
                   OR window_start <> :'window_start'::date));

SELECT pg_temp.check('the 12 monthly spends add up to spend_last_12_months',
    NOT EXISTS (SELECT 1 FROM report r
                WHERE (SELECT sum(x) FROM unnest(r.monthly_spend) x) <> r.spend_last_12_months));

SELECT pg_temp.check('running total ends at total spent, and each step adds that month''s spend',
    NOT EXISTS (SELECT 1 FROM report r
                WHERE r.running_total[12] <> r.total_spent
                   OR EXISTS (SELECT 1 FROM generate_series(2, 12) k
                              WHERE r.running_total[k] - r.running_total[k - 1] <> r.monthly_spend[k])));

SELECT pg_temp.check('rank 1 is the biggest spender and ranks follow spend',
    (SELECT bool_and(ok) FROM (
        SELECT total_spent >= lead(total_spent) OVER (ORDER BY spend_rank, customer_id) IS NOT FALSE AS ok
        FROM report) x)
    AND (SELECT total_spent FROM report WHERE spend_rank = 1 LIMIT 1) = (SELECT max(total_spent) FROM report));

SELECT pg_temp.check('top-100 filter returns at least 100 customers (ties share a rank)',
    (SELECT count(*) >= 100 FROM report WHERE spend_rank <= 100));

SELECT pg_temp.check('summary agrees with the monthly detail',
    0 = (
        SELECT count(*)
        FROM report r
        JOIN detail d USING (customer_id)
        WHERE d.spends <> r.monthly_spend));

SELECT pg_temp.check('people with two accounts are flagged',
    (SELECT bool_and(accounts_sharing_email >= 1) FROM report
     WHERE email IN (SELECT email FROM customers GROUP BY email HAVING count(*) > 1)));

-- Definitions at the boundaries, on a brand-new customer with no history.
INSERT INTO customers (full_name, email) VALUES ('Report Test Customer', 'report.test@example.invalid')
RETURNING customer_id AS cid \gset

INSERT INTO orders (customer_id, order_date, status, total_amount) VALUES
    (:cid, '2025-06-15 10:00', 'completed', 1000),   -- before the window: total only
    (:cid, '2025-09-01 00:00', 'completed',  100),   -- first instant of the window: month 1
    (:cid, '2026-08-31 23:59', 'shipped',     10),   -- last minute of the window: month 12
    (:cid, '2026-09-01 00:00', 'completed', 5000),   -- first instant after the window: excluded
    (:cid, '2026-03-10 12:00', 'pending',    700),   -- pending: excluded
    (:cid, '2026-03-11 12:00', 'cancelled',  800),   -- cancelled: excluded
    (:cid, '2026-03-12 12:00', 'refunded',   900);   -- refunded: excluded

SELECT total_spent, order_count, spend_last_12_months,
       monthly_spend[1] AS m1, monthly_spend[12] AS m12, running_total[1] AS r1
FROM monday_customer_report(:'as_of') WHERE customer_id = :cid \gset

SELECT pg_temp.check('only completed and shipped orders count as spent',
    :total_spent = 1110 AND :order_count = 3);
SELECT pg_temp.check('an order before the window counts in the total but not in the 12 months',
    :spend_last_12_months = 110);
SELECT pg_temp.check('window start is inclusive (month 1), window end exclusive',
    :m1 = 100 AND :m12 = 10);
SELECT pg_temp.check('running total includes spend from before the window',
    :r1 = 1100);

ROLLBACK;

\echo 'PASSED: all Monday report tests'
