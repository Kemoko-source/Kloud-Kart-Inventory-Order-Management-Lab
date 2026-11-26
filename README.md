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

## Tests

```bash
./scripts/run_tests.sh
```

This runs:

- `tests/constraints_test.sql`: the schema refuses each diagnosed problem
- `tests/place_order_test.sql`: refusals, linked writes, append-only ledger
- `race_test.py`, unmodified: concurrency under contention

The SQL tests run in rolled-back transactions and leave no trace.

To run the concurrency test on its own:

```bash
docker compose run --rm racetest              # all four tests
docker compose run --rm racetest --test 2     # flash sale only
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
