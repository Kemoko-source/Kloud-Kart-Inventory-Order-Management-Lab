-- report_at_scale.sql
-- Will the Monday report still run in seconds a year from now? The brief puts
-- Kloud Kart at ~4,000 orders a day, which is about 1.46 million orders a year:
-- roughly 10x the extract. This adds synthetic customers and a year of orders
-- at that rate inside a transaction, times the report, and rolls back.
--
--     docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/benchmarks/report_at_scale.sql

\set ON_ERROR_STOP on
\set extra_customers  60000
\set orders_per_day   4000
\set as_of            '2026-09-07'

BEGIN;

INSERT INTO customers (full_name, email, phone, city)
SELECT 'Scale Customer ' || n, 'scale' || n || '@example.invalid', '+233200000000', 'Accra'
FROM generate_series(1, :extra_customers) AS n;

-- One year of orders before the report date, spread evenly, random customers
-- (old and new), 80% completed or shipped like the real mix.
-- Customer IDs are not contiguous (new ones start above every ID the extract
-- ever referenced), so pick from the real list rather than a numeric range.
INSERT INTO orders (customer_id, order_date, status, total_amount)
SELECT ids.all_ids[1 + floor(random() * cardinality(ids.all_ids))::int],
       timestamp :'as_of' - interval '365 days' + random() * interval '365 days',
       (ARRAY['completed', 'completed', 'completed', 'shipped', 'pending'])[1 + floor(random() * 5)::int],
       round((random() * 2000)::numeric, 2)
FROM (SELECT array_agg(customer_id) AS all_ids FROM customers) ids
CROSS JOIN generate_series(1, :orders_per_day * 365);

ANALYZE customers;
ANALYZE orders;

\echo
\echo '== Synthetic size'
SELECT (SELECT count(*) FROM customers) AS customers, (SELECT count(*) FROM orders) AS orders;

\timing on
\echo
\echo '== Full report, every customer (x2)'
SELECT * FROM monday_customer_report(:'as_of') \g /dev/null
SELECT * FROM monday_customer_report(:'as_of') \g /dev/null

\echo
\echo '== Top 100 only'
SELECT * FROM monday_customer_report(:'as_of') WHERE spend_rank <= 100 \g /dev/null
\timing off

ROLLBACK;

-- ANALYZE estimates survive ROLLBACK; restore them for the real tables.
ANALYZE customers;
ANALYZE orders;
