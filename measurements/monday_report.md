# Monday report report

## Target

From the brief: Adwoa's weekly customer-spending report (for every customer:
total spent, order count, monthly spend for the trailing 12 months, a running
total and a top-100 ranking) **"all in seconds on an ordinary laptop"**. Today it
takes about 40 minutes, and some Mondays it does not finish.

Read as: **the full report for every customer returns in under 10 seconds**,
today and at the order volume the brief describes (about 4,000 orders a day,
roughly 10× the extract over a year). The 10-second line is my interpretation of
"in seconds".

## Method

- **Hardware / container spec:** Docker Desktop on Windows 11, Linux VM with 8
  CPUs and 16 GB RAM; PostgreSQL 18.7, default settings except
  `max_connections = 500`.
- **What was timed, from which event to which event:** psql's `\timing`, from
  sending the statement to receiving every row (rows fetched and discarded).
  - *Full report:* `SELECT * FROM monday_customer_report('2026-09-07')`, which is
    every column for all 40,420 customers.
  - *Top 100:* the same with `WHERE spend_rank <= 100`.
  - *At scale:* `benchmarks/report_at_scale.sql` adds 60,000 customers and a year
    of orders at 4,000 a day (1.6M orders in total) inside a rolled-back
    transaction, then times the full report twice.
  - *Before:* `scripts/run_report_benchmark.sh` loads the extract exactly as
    delivered into a separate database and times the report written the usual
    naive way: sub-queries per customer and per month, 26 reads of `orders` per
    customer (`benchmarks/report_naive.sql`).
- **Runs, warm or cold, and which figure is reported:** today's data: one run in
  a fresh session (reported separately), then 10 warm runs; median, p95 (nearest
  rank) and worst of the warm runs. At scale: 3 runs × 2 timings. Before: a
  20-customer sample, extrapolated (see caveats).
- **How to reproduce:** `./scripts/rebuild.sh`, then `./scripts/run_measurements.sh`
  and `./scripts/run_report_benchmark.sh`. Raw output:
  [`evidence/measurements.txt`](../evidence/measurements.txt) and
  [`evidence/report_benchmark.txt`](../evidence/report_benchmark.txt).

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Full report, every customer, today (40,420 customers, 159,150 orders) | 10 warm | 1.59 s | 2.04 s | 2.04 s | **Yes** |
| Same, first run in a fresh session | 1 | | | 1.99 s | Yes |
| Top 100 only, today | 10 warm | 1.38 s | 1.58 s | 1.58 s | **Yes** |
| Full report, ~10× volume (100,420 customers, 1.6M orders) | 6 | 6.31 s | 8.44 s | 8.44 s | **Yes, with the least margin**; see caveats |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Whole report, extract as delivered: naive sub-queries → set-based query, **no indexes** | ≈ 3.1 hours (278 ms per customer × 40,420) | 1.07–1.22 s (3 runs) | About 10,000× faster from the rewrite alone |
| Same naive query, on the cleaned and **indexed** database | 7.5 s | — | Indexes alone also help, but still about a million lookups per run |
| Final function, cleaned and indexed database, every column | — | 1.47–1.95 s (3 runs); 1.59 s median over 10 | The answer in production |
| Function wrapper (`SET search_path` stopped inlining; 485,040 rows stored and re-read) | 1.84 s | about 1.6 s with tables schema-qualified instead | Development measurement |
| One join at 10× volume (computed month key: 9.3M rows read to produce 1.2M) | 7.2 s | 5.6 s with an integer month key | Development measurement |
| More memory per sort (`work_mem` 32 or 64 MB instead of 4 MB), 10× volume | 5.3–5.7 s | 6.3–11.6 s | **Slower**: not adopted |

Why the rewrite wins and the server settings were left alone:
[ADR-006](../decisions/ADR-006-set-based-report-no-server-tuning.md).

## Caveats

- **The "before" is extrapolated, not timed in full.** It would take about three
  hours, so 20 customers were timed (5.2–5.6 s across two sessions) and scaled
  linearly to 40,420. Linear is fair: each customer costs the same 26 reads of
  `orders`. The brief's "about 40 minutes" comes from Adwoa's own method on her
  machine, which I have not seen.
- **The 10× figure varies with the laptop's load.** An earlier session measured
  5.1–5.7 s; this one 6.3 s median and 8.4 s worst. Both are inside 10 s, but
  this is where the design has least headroom. Cost grows roughly in line with
  orders and customers. At several times this volume, the next step is a monthly
  spend table updated as orders arrive (ADR-006, Alternative D).
- **Synthetic orders at scale** are spread evenly over the year with random
  amounts; real traffic is lumpier, which affects aggregation little.
- **The report's arithmetic is not the same as its truth.** It is tested against
  a direct count (`tests/monday_report_test.sql`), but all of the top 100 bought
  at least one of 116 products with suspect prices (`data_findings.md`, F-03).
- **This is a laptop VM, not Kloud Kart's server.**
