-- 70_monday_report.sql
-- Nana's second ask: Adwoa's weekly customer-spending report, in seconds on
-- an ordinary laptop. For every customer: total spent, order count, monthly
-- spend for the trailing 12 months, a running per-customer total and a top-100
-- ranking. (Today it takes about 40 minutes and some Mondays never finishes.)
--
-- Definitions (the brief leaves these open; see decisions/ADR-005-monday-report-definitions.md):
--   spent             total_amount of orders with status completed or shipped.
--                     Pending orders are excluded: they average 110 days old,
--                     the same as completed ones, so "pending" means stuck,
--                     not about to ship. Cancelled and refunded are excluded.
--   trailing 12 mo.   the 12 complete calendar months before the month of
--                     p_as_of. Run on Monday 2026-09-07: Sep 2025 to Aug 2026.
--   running total     the customer's cumulative spend at the end of each month,
--                     including everything before the 12-month window.
--   ranking           RANK() by total spent; tied customers share a rank.
--
-- Both functions read only orders and customers, in one pass each, and leave
-- the heavy lifting (grouping, running sums, ranking) to aggregates and window
-- functions, instead of one sub-query per customer per month.

\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS monday_customer_report(date);
DROP FUNCTION IF EXISTS customer_monthly_spend(date);

-- ---------------------------------------------------------------------------
-- customer_monthly_spend: one row per customer per month of the window, with
-- that month's spend and the running total. This is the detail behind the
-- summary, and replaces the running total Adwoa keeps by hand.
-- ---------------------------------------------------------------------------
CREATE FUNCTION customer_monthly_spend(p_as_of date DEFAULT current_date)
RETURNS TABLE (
    customer_id         bigint,
    month               date,
    orders              bigint,
    spend               numeric,
    running_orders      bigint,
    running_total       numeric
)
LANGUAGE sql
STABLE
AS $$
    WITH bounds AS (
        SELECT (date_trunc('month', p_as_of) - interval '12 months')::date AS window_start,
               date_trunc('month', p_as_of)::date                          AS window_end,  -- exclusive
               -- months since year 0 of the window's first month, for month_index below
               (extract(year FROM p_as_of)::int * 12 + extract(month FROM p_as_of)::int - 1) - 12
                                                                           AS first_month_number
    ),
    counted AS (
        SELECT o.customer_id, o.order_date, o.total_amount
        FROM public.orders o
        CROSS JOIN bounds b
        WHERE o.status IN ('completed', 'shipped')
          AND o.order_date < b.window_end
    ),
    before_window AS (
        SELECT c.customer_id, count(*) AS orders, sum(c.total_amount) AS spend
        FROM counted c
        CROSS JOIN bounds b
        WHERE c.order_date < b.window_start
        GROUP BY c.customer_id
    ),
    -- Months are keyed by an integer 0..11 rather than a date. With two plain
    -- keys, (customer_id, month_index), the grid below joins to the monthly
    -- totals in a single pass; joining on a computed date made PostgreSQL
    -- merge on customer only and re-read each customer's months twelve times
    -- (9.3 million rows read for 1.2 million produced at 10x volume).
    in_window AS (
        SELECT c.customer_id,
               (extract(year FROM c.order_date)::int * 12 + extract(month FROM c.order_date)::int - 1)
                 - b.first_month_number AS month_index,
               count(*)            AS orders,
               sum(c.total_amount) AS spend
        FROM counted c
        CROSS JOIN bounds b
        WHERE c.order_date >= b.window_start
        GROUP BY 1, 2
    ),
    -- An integer series, not generate_series over dates: the planner knows an
    -- integer series has exactly 12 rows, but guesses 1,000 for a date series,
    -- which inflated the report's estimate from 485 thousand rows to 40 million
    -- and skewed every join choice built on it.
    months AS (
        SELECT n AS month_index,
               (b.window_start + make_interval(months => n))::date AS month
        FROM bounds b
        CROSS JOIN generate_series(0, 11) AS n
    )
    SELECT cu.customer_id,
           m.month,
           coalesce(w.orders, 0)                                                        AS orders,
           coalesce(w.spend, 0)                                                         AS spend,
           coalesce(bw.orders, 0)
             + sum(coalesce(w.orders, 0)) OVER (PARTITION BY cu.customer_id ORDER BY m.month_index)::bigint AS running_orders,
           coalesce(bw.spend, 0)
             + sum(coalesce(w.spend, 0))  OVER (PARTITION BY cu.customer_id ORDER BY m.month_index)         AS running_total
    FROM public.customers cu
    CROSS JOIN months m
    LEFT JOIN in_window w      ON w.customer_id = cu.customer_id AND w.month_index = m.month_index
    LEFT JOIN before_window bw ON bw.customer_id = cu.customer_id
$$;

COMMENT ON FUNCTION customer_monthly_spend(date) IS
    'Per customer, per month of the trailing 12 complete months before p_as_of: orders, spend and running totals.';

-- ---------------------------------------------------------------------------
-- monday_customer_report: Adwoa's report, one row per customer.
-- monthly_spend[1] is the oldest month (window_start), [12] the most recent.
-- accounts_sharing_email flags people with several accounts (F-10),
-- whose spend is split across rows; they are not merged automatically.
-- ---------------------------------------------------------------------------
CREATE FUNCTION monday_customer_report(p_as_of date DEFAULT current_date)
RETURNS TABLE (
    spend_rank              bigint,
    customer_id             bigint,
    full_name               text,
    email                   text,
    total_spent             numeric,
    order_count             bigint,
    spend_last_12_months    numeric,
    window_start            date,
    monthly_spend           numeric[],
    running_total           numeric[],
    accounts_sharing_email  bigint
)
LANGUAGE sql
STABLE
AS $$
    WITH per_customer AS (
        SELECT s.customer_id,
               max(s.running_total)                     AS total_spent,     -- running totals never decrease
               max(s.running_orders)                    AS order_count,
               sum(s.spend)                             AS spend_last_12_months,
               min(s.month)                             AS window_start,
               array_agg(s.spend         ORDER BY s.month) AS monthly_spend,
               array_agg(s.running_total ORDER BY s.month) AS running_total
        FROM public.customer_monthly_spend(p_as_of) s
        GROUP BY s.customer_id
    )
    SELECT rank() OVER (ORDER BY p.total_spent DESC) AS spend_rank,
           p.customer_id,
           c.full_name,
           c.email,
           p.total_spent,
           p.order_count,
           p.spend_last_12_months,
           p.window_start,
           p.monthly_spend,
           p.running_total,
           count(*) OVER (PARTITION BY c.email) - 1 AS accounts_sharing_email
    FROM per_customer p
    JOIN public.customers c ON c.customer_id = p.customer_id
$$;

COMMENT ON FUNCTION monday_customer_report(date) IS
    'Weekly customer-spending report: rank, total spent, order count, 12 monthly spends and running totals per customer.';
