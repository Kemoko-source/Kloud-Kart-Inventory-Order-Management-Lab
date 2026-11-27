# Kloud Kart — Inventory & Order Management

Kloud Kart Ltd. (Accra, ~4,000 orders/day) runs on a single PostgreSQL server
with a schema that was never redesigned. This repository answers the four
things operations lead Nana Adjei asked for:

1. **No overselling**: two buyers racing for the last unit, exactly one wins,
   the other gets an instant "out of stock".
2. **A fast Monday report**: per-customer spend, order count, trailing-12-month
   monthly spend, running total and top-100 ranking, in seconds.
3. **Low-stock visibility** rolled up through a category tree of any depth.
4. **An audit trail** of every stock movement.

Everything runs on plain PostgreSQL: no new infrastructure.

## Repository layout

| Path | Contents |
|---|---|
| `M03_Resources/` | The data bundle exactly as provided: schema, load script, CSVs and `race_test.py` (unmodified) |
| `sql/` | Solution scripts, applied in numeric order after a fresh load |
| `diagnosis/` | Read-only SQL checks behind every number in the diagnosis |
| `docs/` | Data diagnosis, design decisions, memo to Nana |
| `scripts/rebuild.sh` | Fresh load plus every solution script, top to bottom |
| `tests/` | Container definition for running `race_test.py` |

## Prerequisites

- Docker Desktop (running)
- Git Bash or any POSIX shell, for `scripts/rebuild.sh`

You do not need `psql` or Python on the host: both run inside containers.

## Setup

```bash
cp .env.example .env              # then set your own POSTGRES_PASSWORD
docker compose up -d db           # PostgreSQL 18 with max_connections=500
./scripts/rebuild.sh              # fresh load + all solution scripts
```

`rebuild.sh` refuses to run unless `SHOW max_connections` returns at least 500.
`race_test.py` opens 400 connections at once, and on PostgreSQL's default of
100 its flash-sale test hangs.

If you already run the course's `kloudkart` container on port 5432, stop it
(`docker stop kloudkart`) or set `POSTGRES_PORT` in `.env` to a free port.

## Data diagnosis

Ranked findings are in [`docs/01_data_diagnosis.md`](docs/01_data_diagnosis.md).
Reproduce every number from a fresh load (read-only, about 5 seconds):

```bash
docker compose exec -T db psql -U kloudkart -d kloudkart \
    -f /workspace/diagnosis/diagnosis_checks.sql
```

## Solution scripts

Applied in order by `scripts/rebuild.sh` after the fresh load. Design
reasoning is in [`docs/02_design_decisions.md`](docs/02_design_decisions.md).

| Script | What it does |
|---|---|
| `sql/10_foundations.sql` | Audit tables (`data_quarantine`, `data_corrections`) and identity columns for safe ID generation |
| `sql/20_clean.sql` | Fixes the diagnosed problems in one transaction, recording every removal and correction, then checks invariants; creates the `products_to_recount` view |
| `sql/30_constraints.sql` | Foreign keys with their indexes, CHECK rules, NOT NULLs, and a trigger that refuses category loops |
| `sql/40_audit_trail.sql` | Links each sale movement to its order; makes `inventory_log` append-only and archives any deletion |
| `sql/50_place_order.sql` | `place_order()`: atomic, oversell-proof order placement with a clean "out of stock" |
| `sql/60_low_stock.sql` | Per-product `reorder_level`; views `category_tree`, `low_stock_by_category` (rollup at any depth) and `low_stock_products` (drill-down) |
| `sql/70_monday_report.sql` | `monday_customer_report()` and the monthly detail behind it, `customer_monthly_spend()` |

## Running the Monday report

```sql
-- Top 100, as of a given Monday (defaults to today)
SELECT spend_rank, full_name, email, total_spent, order_count, spend_last_12_months, monthly_spend
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

## Using the low-stock views

```sql
-- At a glance: the tree, each category covering its whole subtree
SELECT path, products, out_of_stock, low_stock FROM low_stock_by_category ORDER BY path;

-- Drill down: most urgent first
SELECT product_name, category_path, stock_quantity, reorder_level, stock_status
FROM low_stock_products ORDER BY units_below_reorder_level DESC LIMIT 50;
```

## Tests

```bash
./scripts/run_tests.sh
```

This runs:

- `tests/constraints_test.sql`: the schema refuses each diagnosed problem
- `tests/place_order_test.sql`: refusals, linked writes, append-only ledger
- `tests/low_stock_test.sql`: rollup arithmetic at every node, any depth, still answers with a loop in the tree
- `tests/monday_report_test.sql`: report totals against a direct count, and each definition at its boundary
- `race_test.py`, unmodified: concurrency under contention

The SQL tests run in rolled-back transactions and leave no trace.

To run the concurrency test on its own:

```bash
docker compose run --rm racetest              # all four tests
docker compose run --rm racetest --test 2     # flash sale only
```

## Benchmarks

```bash
# Low-stock rollup on a synthetic tree 50x today's size (rolled back afterwards)
docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/benchmarks/low_stock_at_scale.sql

# Monday report: raw extract + naive query vs final (writes docs/evidence/report_benchmark.txt)
./scripts/run_report_benchmark.sh

# Monday report at about 10x today's order volume (rolled back afterwards)
docker compose exec -T db psql -U kloudkart -d kloudkart -f /workspace/benchmarks/report_at_scale.sql
```

## Experiment: would triggers alone have fixed overselling?

```bash
./scripts/run_trigger_experiment.sh
```

This runs the unmodified `race_test.py` against a triggers-only design, in a
throwaway copy of the database. Results are written to `docs/evidence/`, and
are discussed in section 2.3 of the design decisions.

## Connecting manually

```bash
docker compose exec db psql -U kloudkart -d kloudkart
```
