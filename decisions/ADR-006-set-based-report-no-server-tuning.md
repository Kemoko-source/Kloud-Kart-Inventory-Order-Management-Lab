# ADR-006: Make the report fast by rewriting it as one set-based query, not with a bigger server or tuned settings

- **Status:** Accepted
- **Date:** 2026-11-27
- **Decision owner:** Kemoko Foumba Traore

## Context

Adwoa's report takes about 40 minutes and some Mondays does not finish.
Someone has already priced a bigger server. The brief allows no new
infrastructure or monthly bill, and wants the report "in seconds on an
ordinary laptop".

## Decision

The report is two SQL functions: `customer_monthly_spend()` reads `orders`
once, groups it per customer and month, and uses window functions for the
running totals; `monday_customer_report()` builds the summary and ranking from
it. Three plan problems found with `EXPLAIN ANALYZE` were fixed in the query
itself. Server settings are left at their defaults.

## Alternatives considered

### Alternative A: A bigger server

- **How it would work:** More CPU and memory for the same query.
- **Why it is attractive:** No code change.
- **Why rejected:** The naive query re-reads `orders` 26 times per customer; on
  the extract as delivered that is about **3 hours**. A faster machine shortens
  it by a constant factor; the rewrite took the same unindexed data to
  **1.1–1.5 s**. More memory even made it slower: `work_mem` of 32 MB or 64 MB
  took the 10× test from 5.3–5.7 s to 6.3–11.6 s.

### Alternative B: Indexes only

- **How it would work:** Index `orders.customer_id` and keep the per-customer sub-queries.
- **Why it is attractive:** Small change; today it gets the naive query to 7.5 s.
- **Why rejected:** It still issues about a million lookups per run (26 for each
  customer), a number that grows with every customer. The set-based query's
  cost follows the number of orders.

### Alternative C: Tune JIT compilation or memory

- **How it would work:** Turn off JIT or raise `work_mem` server-wide.
- **Why it is attractive:** JIT spends about 0.57 s compiling this query.
- **Why rejected:** Measured: with JIT on or off, results were within run-to-run
  noise (JIT wins back what it spends), and more memory was slower. A setting
  with no measurable gain is one more thing for Kloud Kart's team to maintain.

### Alternative D: A summary table updated as orders arrive

- **How it would work:** Keep each customer's monthly spend in a table, updated on every order.
- **Why it is attractive:** The report would read 12 small rows per customer.
- **Why rejected (for now):** It adds a write to every order, including during
  flash sales, to save seconds nobody is waiting for yet.

## Consequences

- **What this buys:** 1.5–2.0 s for all 40,420 customers, every column, on a laptop.
- **What this costs:** Three non-obvious query details that must survive future
  edits, each explained in a code comment: tables are schema-qualified instead
  of `SET search_path` (so the function can be inlined); the 12 months come from
  an integer series (estimated exactly, where a date series is estimated at
  1,000 rows); and months are joined on an integer index (a computed date key
  made one join re-read 9.3 million rows at 10× volume).
- **What it costs the client if I am wrong:** A slower Monday, not a wrong one.
  Correctness is tested separately.
- **What would make me revisit this:** Volume several times beyond 10× today's;
  then Alternative D.

## What this survives

About 10× today's volume, roughly a year at the brief's 4,000 orders a day
(1.6M orders, 100,420 customers): **5.1–8.4 s** across two measurement sessions
(median 6.3 s in the latest, worst 8.4 s), inside 10 s but with the least
headroom of any figure here. Method and runs are in
[`measurements/monday_report.md`](../measurements/monday_report.md).
