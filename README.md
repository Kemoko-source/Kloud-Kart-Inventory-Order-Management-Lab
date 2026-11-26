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

## Running the concurrency test

```bash
docker compose run --rm racetest              # all four tests
docker compose run --rm racetest --test 2     # flash sale only
```

## Connecting manually

```bash
docker compose exec db psql -U kloudkart -d kloudkart
```
