# Kloud Kart — Inventory & Order Management

Kloud Kart Ltd. (Accra, ~4,000 orders a day) runs on a single PostgreSQL server
with a schema that was never redesigned. This repository answers the four
things operations lead Nana Adjei asked for, on that same server with no new
infrastructure:

1. **No overselling**: two buyers racing for the last unit, exactly one wins,
   the other gets an instant "out of stock".
2. **A fast Monday report**: per-customer spend, order count, trailing-12-month
   monthly spend, running total and top-100 ranking, in seconds.
3. **Low-stock visibility** rolled up through a category tree of any depth.
4. **An audit trail** of every stock movement.

## Deliverables

| Brief asks for | Where |
|---|---|
| Written diagnosis of the data, ranked by danger | [`data_findings.md`](data_findings.md), evidence in [`diagnosis/diagnosis_checks.sql`](diagnosis/diagnosis_checks.sql) |
| Working SQL solution, top to bottom from a fresh load | [`sql/`](sql/), applied by [`scripts/rebuild.sh`](scripts/rebuild.sh) |
| Explanation of key decisions | [`decisions/`](decisions/): six ADRs |
| One-page memo to Nana | [`client_memo.md`](client_memo.md) |
| One improvement beyond the brief, built | [`improvement.md`](improvement.md) and [`sql/80_cancel_order.sql`](sql/80_cancel_order.sql) |
| Performance backed by before/after measurement | [`measurements/`](measurements/): order placement, low-stock rollup, Monday report |

## Prerequisites

- Docker Desktop, running
- Git Bash or any POSIX shell, for the scripts

You do not need `psql` or Python on the host: both run inside containers.

**Git Bash on Windows:** commands below that pass a path *inside* a container
(starting `/workspace/`, `/tests/` or `/benchmarks/`) need `MSYS_NO_PATHCONV=1`
in front, or Git Bash rewrites the path into a Windows one and the file is "not
found". For example:
`MSYS_NO_PATHCONV=1 docker compose exec -T db psql -f /workspace/diagnosis/diagnosis_checks.sql`.
The scripts in `scripts/` set it themselves, and PowerShell is not affected.

## Setup

```bash
cp .env.example .env              # then set your own POSTGRES_PASSWORD
./scripts/rebuild.sh              # starts PostgreSQL 18, waits until ready, fresh load + all solution scripts
./scripts/run_tests.sh            # every test, including the unmodified race_test.py
```

The first run downloads the PostgreSQL and Python images; after that a
rebuild takes about 15 seconds.

`rebuild.sh` refuses to run unless `SHOW max_connections` returns at least 500:
`race_test.py` opens 400 connections at once, and on PostgreSQL's default of 100
its flash-sale test hangs. If you already run the course's `kloudkart`
container on port 5432, stop it or set `POSTGRES_PORT` in `.env` to a free port.

## Repository layout

| Path | Contents |
|---|---|
| `M03_Resources/` | The data bundle exactly as provided: schema, load script, CSVs and `race_test.py`, all unmodified |
| `sql/` | Solution scripts, applied in numeric order after a fresh load |
| `tests/` | SQL tests (each in a rolled-back transaction), a concurrency test for cancellations, and the test container definition |
| `diagnosis/` | Read-only checks behind every number in `data_findings.md` |
| `decisions/` | Architecture decision records |
| `measurements/` | Measurement reports against the brief's targets |
| `benchmarks/` | Queries used by the measurements (naive "before" versions, synthetic scale-ups) |
| `experiments/` | The triggers-only design, used to test whether triggers would have fixed overselling |
| `evidence/` | Captured output of the benchmark and experiment scripts |
| `scripts/` | Rebuild, test, benchmark and experiment runners |

## Solution scripts

| Script | What it does |
|---|---|
| `sql/10_foundations.sql` | Audit tables (`data_quarantine`, `data_corrections`) and identity columns for safe ID generation |
| `sql/20_clean.sql` | Fixes the findings in one transaction, recording every removal and correction, then checks invariants; creates the `products_to_recount` view |
| `sql/30_constraints.sql` | Foreign keys with their indexes, CHECK rules, NOT NULLs, and a trigger that refuses category loops |
| `sql/40_audit_trail.sql` | Links each sale movement to its order; makes `inventory_log` append-only and archives any deletion |
| `sql/50_place_order.sql` | `place_order()`: atomic, oversell-proof order placement with a clean "out of stock" |
| `sql/60_low_stock.sql` | Per-product `reorder_level`; views `category_tree`, `low_stock_by_category` (rollup at any depth) and `low_stock_products` (drill-down) |
| `sql/70_monday_report.sql` | `monday_customer_report()` and the monthly detail behind it, `customer_monthly_spend()` |
| `sql/80_cancel_order.sql` | Improvement beyond the brief: `cancel_order()` returns exactly the stock a pending order took |

## Using it

```bash
docker compose exec db psql
```

**Placing and cancelling orders**

```sql
-- Sample output; your order_id will differ.
SELECT * FROM place_order(p_customer_id => 100001, p_product_id => 5001, p_quantity => 2);
--  success | order_id | message
--  t       |  1000123 | Order 1000123 placed: 2 unit(s)

SELECT * FROM cancel_order(p_order_id => 1000123, p_note => 'customer changed their mind');
--  success | units_returned | message
--  t       |              2 | Order 1000123 cancelled; 2 unit(s) returned to stock
```

**The Monday report**

```sql
-- Top 100, as of a given Monday (defaults to today). The function also returns
-- each customer's email; leave it out of anything shared beyond the team.
SELECT spend_rank, customer_id, full_name, total_spent, order_count, spend_last_12_months, monthly_spend
FROM monday_customer_report('2026-09-07')
WHERE spend_rank <= 100
ORDER BY spend_rank;

-- One customer's month-by-month spend and running total
SELECT month, orders, spend, running_total
FROM customer_monthly_spend('2026-09-07')
WHERE customer_id = 116661
ORDER BY month;
```

`monthly_spend[1]` is the oldest of the 12 months (`window_start`) and
`monthly_spend[12]` the most recent.

**Low stock**

```sql
-- At a glance: the tree, each category covering its whole subtree
SELECT path, products, out_of_stock, low_stock FROM low_stock_by_category ORDER BY path;

-- Drill down: most urgent first
SELECT product_name, category_path, stock_quantity, reorder_level, stock_status
FROM low_stock_products ORDER BY units_below_reorder_level DESC LIMIT 50;

-- Shelves to count first: figures reconciled or inferred during the clean-up
SELECT product_id, product_name, stock_quantity, reasons FROM products_to_recount;
```

## Tests

`./scripts/run_tests.sh` runs:

- `tests/constraints_test.sql`: the schema refuses each finding
- `tests/place_order_test.sql`: refusals, linked writes, append-only ledger
- `tests/low_stock_test.sql`: rollup arithmetic at every node, any depth, still answers with a loop in the tree
- `tests/monday_report_test.sql`: report totals against a direct count, and each definition at its boundary
- `tests/cancel_order_test.sql`: cancellations return exactly the ledger's stock
- `race_test.py`, unmodified: order placement under contention
- `tests/cancel_race_test.py`: simultaneous cancellations, cancelling during a flash sale, no deadlocks

Each SQL test has a 2-minute statement timeout, so a bad query plan fails
instead of hanging. The SQL tests share one helper, `tests/test_helpers.sql`.
Test fixtures are named after the test that creates them, and any email
address uses the reserved `.invalid` domain, so no fixture can reach a real
customer.

To run the provided concurrency test on its own:

```bash
docker compose run --rm racetest              # all four tests
docker compose run --rm racetest --test 2     # flash sale only
```

The container gets `DATABASE_URL` from `.env` automatically. To run
`race_test.py` or `tests/cancel_race_test.py` directly with Python on the host
instead (needs `pip install psycopg2-binary`), set it first:

```bash
# bash / Git Bash
export DATABASE_URL="postgresql://kloudkart:$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2)@localhost:5432/kloudkart"
```

```powershell
# PowerShell
$pw = (Select-String -Path .env -Pattern '^POSTGRES_PASSWORD=(.*)$').Matches[0].Groups[1].Value
$env:DATABASE_URL = "postgresql://kloudkart:$pw@localhost:5432/kloudkart"
```

Then `python M03_Resources/race_test.py`. These read the password from `.env`
without displaying it; the variable lasts only for that terminal. If you
changed `POSTGRES_USER`, `POSTGRES_DB` or `POSTGRES_PORT` in `.env`, adjust the
URL to match.

## Measurements, benchmarks and the triggers experiment

```bash
./scripts/run_measurements.sh       # repeated runs behind measurements/, written to evidence/
./scripts/run_report_benchmark.sh   # Monday report: raw extract + naive query vs final
./scripts/run_trigger_experiment.sh # race_test.py against a triggers-only design, in a throwaway database

# Synthetic scale-ups, rolled back afterwards
docker compose exec -T db psql -f /workspace/benchmarks/low_stock_at_scale.sql
docker compose exec -T db psql -f /workspace/benchmarks/report_at_scale.sql
```
