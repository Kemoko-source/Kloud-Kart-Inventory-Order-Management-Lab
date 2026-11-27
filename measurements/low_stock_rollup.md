# Low-stock rollup report

## Target

From the brief: low-stock visibility at a glance, rolled up through the nested
category tree, **"in a couple of seconds"**, without hard-coding the depth.
Read as: the full rollup (every category, whole subtree) **returns in 2 seconds
or less**, today and as marketing adds subcategories.

## Method

- **Hardware / container spec:** Docker Desktop on Windows 11, Linux VM with 8
  CPUs and 16 GB RAM; PostgreSQL 18.7, default settings except
  `max_connections = 500`.
- **What was timed, from which event to which event:** psql's `\timing`, from
  sending the statement to receiving the full result (the rows are fetched and
  discarded):
  - *Full rollup:* `SELECT * FROM low_stock_by_category`.
  - *Drill-down:* the 50 most urgent products from `low_stock_products`.
  - *At scale:* `benchmarks/low_stock_at_scale.sql` builds, inside a rolled-back
    transaction, a ragged tree of 5,095 categories, 11 levels deep, with 204,023
    products (50× today's size), then times the full rollup.
- **Runs, warm or cold, and which figure is reported:** today's data: one run in
  a fresh session (reported separately), then 10 warm runs in another session;
  median, p95 and worst of the warm runs. At scale: 3 runs, each in a fresh
  transaction.
- **How to reproduce:** `./scripts/rebuild.sh && ./scripts/run_measurements.sh`.
  Raw output: [`evidence/measurements.txt`](../evidence/measurements.txt).

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Full rollup, today (94 categories, 4,023 products) | 10 warm | 3.3 ms | 3.9 ms | 3.9 ms | **Yes** |
| Same, first run in a fresh session | 1 | | | 6.1 ms | Yes |
| Drill-down, 50 most urgent products, today | 10 warm | 2.3 ms | 2.4 ms | 2.4 ms | **Yes** |
| Same, first run in a fresh session | 1 | | | 5.6 ms | Yes |
| Full rollup, 50× today's size (5,095 categories, 11 levels, 204,023 products) | 3 | 175 ms | 307 ms | 307 ms | **Yes**: 6× under budget |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Full rollup at 50× scale: first version joined each product to every ancestor, then counted (about 1.2M intermediate rows) | 3.66 s (1 run during development) | 175 ms median (3 runs) | About 20× faster; the first version missed the target |
| Full rollup, today's data, same two versions | 17 ms | 3.3 ms | About 5× faster |
| Full rollup, today, after the scale test left stale planner statistics behind | about 600 ms (576 ms of it compiling the query) | 8 ms after re-analysing | The benchmark now re-analyses after its rollback |

The change between versions was the order of work: count products once per
category, then roll up only those totals
([ADR-004](../decisions/ADR-004-low-stock-rollup.md)). Both versions return the
same rows; `tests/low_stock_test.sql` checks the arithmetic at every node.

## Caveats

- **The "before" at 50× scale is a single run** from development, before this
  measurement script existed. It was 3.66 s against today's 0.18 s median, a gap
  far larger than run-to-run variation.
- **Statistics matter more than size here.** Stale row estimates once made an
  8 ms query take 600 ms. In normal operation the database refreshes them
  automatically; the worst case observed still met the target.
- **Only the read is timed.** The tree is walked on every read, so no refresh or
  background job is hidden from these figures.
- **This is a laptop VM, not Kloud Kart's server.**
