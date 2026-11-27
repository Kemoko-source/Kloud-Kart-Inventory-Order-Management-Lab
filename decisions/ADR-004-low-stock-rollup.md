# ADR-004: Define low stock per product, and roll it up the tree with a loop-safe recursive query that aggregates per category first

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Kemoko Foumba Traore

## Context

Nana wants low stock "at a glance", rolled up through a category tree that is 4
levels deep today and to which marketing keeps adding subcategories, in "a
couple of seconds". The brief does not say what "low" means, forbids
hard-coding the depth, and the extract's tree contained a loop (F-05) that makes
a naive recursive query run forever. Median stock is only 12 units, and
products sell a median of about 4.6 units a week.

## Decision

- **Low is per product.** Each product has a stored `reorder_level`, seeded as
  two weeks of its own average weekly sales over the last 8 weeks of trading
  (minimum 1; new products default to 10). A product is "out of stock" at 0 and
  "low" when `0 < stock ≤ reorder_level`. Operations owns the level.
- **Rolled up at read time.** `category_tree` gives each category's full path;
  `low_stock_by_category` gives each category's whole subtree at any depth, plus
  an "(Uncategorised)" row; `low_stock_products` is the drill-down, most urgent
  first. Products are counted once per category first, and only those totals
  are rolled up. Both recursive views use the standard `CYCLE` clause, so a loop
  ends the walk instead of hanging it.

## Alternatives considered

### Alternative A: One threshold for every product (for example 10 units)

- **How it would work:** `stock <= 10` is low.
- **Why it is attractive:** Simple to explain.
- **Why rejected:** It flags **1,949 of 4,023 products (48%)**, which is not "at a
  glance", and treats a product selling 1 a month like one selling 20 a week.

### Alternative B: Fixed self-joins (category → parent → grandparent …)

- **How it would work:** One join per level.
- **Why it is attractive:** Fast and obvious.
- **Why rejected:** It hard-codes the depth, which the brief forbids, and breaks
  the day a fifth level is added.

### Alternative C: Join each product to every ancestor, then aggregate (my first version)

- **How it would work:** Expand ancestor–descendant pairs, join products, count.
- **Why it is attractive:** One straightforward query.
- **Why rejected:** Measured. Each product is copied once per level, about 1.2
  million rows on a tree 50× today's size, which took **3.66 s**. Aggregating
  first takes **0.16–0.24 s** for the same answer.

### Alternative D: A closure table, or a materialised view refreshed on a schedule

- **How it would work:** Store every ancestor–descendant pair and keep it in sync
  on each edit; or precompute the rollup every N minutes.
- **Why it is attractive:** The fastest reads.
- **Why rejected:** A closure table is a second copy of the tree to keep in sync,
  for speed that is not needed. A scheduled refresh is stale between runs, which
  is wrong for a stock screen during a flash sale.

## Consequences

- **What this buys:** A ranked list operations can tune, correct at any depth,
  that cannot hang. Tests hang three new levels under Cases, and force a loop
  with the guard trigger disabled; both views still answer.
- **What this costs:** The tree is walked on every read (8 ms today). Reorder
  levels go stale as demand changes unless someone adjusts them.
- **What it costs the client if I am wrong:** Two weeks of cover is a judgement;
  supplier lead times are unknown. Too low means late reorders; too high a noisy
  list. Kloud Kart runs lean (median stock is about 2.6 weeks of sales), so even
  this rule flags 1,385 products as low and 591 as out.
- **What would make me revisit this:** Real supplier lead times; or tens of
  thousands of categories.

## What this survives

A synthetic tree 50× today's size (5,095 categories, 11 levels, 204,023
products): full rollup 0.16–0.24 s, drill-down 0.04–0.10 s. Stale planner
statistics once made the real rollup take 0.6 s instead of 8 ms; that is still
inside the budget. Method and runs are in
[`measurements/low_stock_rollup.md`](../measurements/low_stock_rollup.md).
