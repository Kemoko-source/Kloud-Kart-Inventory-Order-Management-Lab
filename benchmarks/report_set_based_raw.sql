-- report_set_based_raw.sql
-- The same set-based logic as monday_customer_report() in sql/70, written
-- inline so it can run on the raw extract (no functions, no indexes, messy
-- statuses normalised on the fly). It separates the effect of rewriting the
-- query from the effect of the schema work.

\set window_start '2025-09-01'
\set window_end   '2026-09-01'

WITH counted AS (
    SELECT customer_id, order_date, total_amount
    FROM orders
    WHERE lower(trim(status)) IN ('completed', 'complete', 'shipped')
      AND order_date < :'window_end'
),
before_window AS (
    SELECT customer_id, count(*) AS orders, sum(total_amount) AS spend
    FROM counted WHERE order_date < :'window_start'
    GROUP BY customer_id
),
in_window AS (
    SELECT customer_id, date_trunc('month', order_date)::date AS month,
           count(*) AS orders, sum(total_amount) AS spend
    FROM counted WHERE order_date >= :'window_start'
    GROUP BY customer_id, date_trunc('month', order_date)
),
months AS (
    SELECT (:'window_start'::date + make_interval(months => n))::date AS month
    FROM generate_series(0, 11) AS n
),
monthly AS (
    SELECT cu.customer_id, m.month,
           coalesce(w.spend, 0) AS spend,
           coalesce(bw.orders, 0) + sum(coalesce(w.orders, 0)) OVER (PARTITION BY cu.customer_id ORDER BY m.month) AS running_orders,
           coalesce(bw.spend, 0)  + sum(coalesce(w.spend, 0))  OVER (PARTITION BY cu.customer_id ORDER BY m.month) AS running_total
    FROM customers cu
    CROSS JOIN months m
    LEFT JOIN in_window w      ON w.customer_id = cu.customer_id AND w.month = m.month
    LEFT JOIN before_window bw ON bw.customer_id = cu.customer_id
),
per_customer AS (
    SELECT customer_id, max(running_total) AS total_spent, max(running_orders) AS order_count,
           array_agg(spend ORDER BY month) AS monthly_spend,
           array_agg(running_total ORDER BY month) AS running_total
    FROM monthly
    GROUP BY customer_id
)
SELECT count(*) AS customers, count(*) FILTER (WHERE spend_rank <= 100) AS top_100_rows
FROM (
    SELECT rank() OVER (ORDER BY total_spent DESC) AS spend_rank
    FROM per_customer
) ranked;
