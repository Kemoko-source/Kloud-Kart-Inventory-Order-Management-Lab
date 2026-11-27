-- report_naive.sql
-- The Monday report written the way it usually grows in a spreadsheet-minded
-- workflow: for each customer, a sub-query per figure and per month. That is
-- 26 scans of orders per customer (total, count, 12 monthly spends, 12 running
-- totals). This is the "before" in benchmarks/run_report_benchmark.sh.
--
-- Statuses are normalised inline so the same text runs on the raw extract and
-- on the cleaned database. psql variables:
--   :sample_customers  how many customers to run for (timing is extrapolated)

\set window_start '2025-09-01'
\set window_end   '2026-09-01'

SELECT rank() OVER (ORDER BY r.total_spent DESC NULLS LAST) AS spend_rank, r.*
FROM (
    SELECT c.customer_id,
           c.full_name,
           (SELECT sum(o.total_amount) FROM orders o
            WHERE o.customer_id = c.customer_id
              AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
              AND o.order_date < :'window_end') AS total_spent,
           (SELECT count(*) FROM orders o
            WHERE o.customer_id = c.customer_id
              AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
              AND o.order_date < :'window_end') AS order_count,
           ARRAY(
               SELECT (SELECT coalesce(sum(o.total_amount), 0) FROM orders o
                       WHERE o.customer_id = c.customer_id
                         AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
                         AND o.order_date >= m AND o.order_date < m + interval '1 month')
               FROM generate_series(:'window_start'::date, :'window_end'::date - 1, interval '1 month') AS m
               ORDER BY m) AS monthly_spend,
           ARRAY(
               SELECT (SELECT coalesce(sum(o.total_amount), 0) FROM orders o
                       WHERE o.customer_id = c.customer_id
                         AND lower(trim(o.status)) IN ('completed', 'complete', 'shipped')
                         AND o.order_date < m + interval '1 month')
               FROM generate_series(:'window_start'::date, :'window_end'::date - 1, interval '1 month') AS m
               ORDER BY m) AS running_total
    FROM customers c
    ORDER BY c.customer_id
    LIMIT :sample_customers
) r;
