# ADR-002: Take stock at checkout with one atomic conditional update inside place_order(), not with triggers

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Kemoko Foumba Traore

## Context

Last month two orders took the same last unit. Two things allowed it. Stock
moved only when an order shipped (none of the 73,641 pending, cancelled or
refunded product-moments has a sale movement), so a paid-for unit still looked
available. And checking stock and taking it were two separate steps: both
buyers read "1 left", both passed the check, both wrote. Nana has been told
triggers might fix it. The mechanism must pass the provided `race_test.py`
unmodified, return a clear "out of stock" instead of an error, and survive
flash sales of about 400 orders in ten seconds on one product.

## Decision

`place_order()` takes stock **at checkout** with a single statement,
`UPDATE products SET stock_quantity = stock_quantity - qty WHERE product_id = …
AND stock_quantity >= qty`, at PostgreSQL's default isolation level. A second
buyer waits for the first buyer's row lock, then re-checks the condition
against the committed stock; if it no longer holds, the buyer is told "out of
stock". The order (status `pending`), its line and the sale movement are
written in the same transaction. A lock-free read refuses buyers early when the
stock is already gone. A `CHECK (stock_quantity >= 0)` rule is the backstop for
any other code path.

## Alternatives considered

### Alternative A: Triggers (what Nana was told)

- **How it would work:** The application keeps checking stock and then writing
  the order; a trigger on `order_items` takes the stock.
- **Why it is attractive:** Nobody can forget to update stock.
- **Why rejected:** Measured, not argued. `scripts/run_trigger_experiment.sh`
  ran the unmodified `race_test.py` against exactly this design in a throwaway
  database ([evidence](../evidence/)). Triggers alone sold **400 units of a
  50-unit stock**, leaving −350. With a `stock >= 0` CHECK added, the stock held,
  but **350 buyers got a database error** instead of "out of stock". Both failed
  25 of 25 last-unit rounds. The trigger was never the mechanism that mattered:
  the gap between check and write is, and a trigger can only report failure
  with an error.

### Alternative B: SERIALIZABLE isolation

- **How it would work:** Run orders at the strictest isolation level.
- **Why it is attractive:** The database detects every conflict.
- **Why rejected:** Under contention it aborts transactions with serialization
  failures. These cannot be retried inside the function (the transaction is
  already dead), so they reach the caller, which the contract forbids. With 400
  buyers on one row, most would fail and retry: a retry storm at the worst moment.

### Alternative C: Keep taking stock at shipping, check only at checkout

- **How it would work:** `place_order()` checks stock; shipping takes it.
- **Why it is attractive:** No change to the warehouse's process.
- **Why rejected:** A check without a reservation is the race itself: a hundred
  buyers can pass the check for the same unit before anything ships.

### Alternative D: Lock-then-check, optimistic locking, or an external queue

- **How it would work:** `SELECT … FOR UPDATE` then `UPDATE`; a version column
  with retry; or a lock or queue outside the database.
- **Why it is attractive:** Common patterns elsewhere.
- **Why rejected:** Lock-then-check is the same lock in two statements with more
  to get wrong. Optimistic locking creates the same retry storm as SERIALIZABLE.
  An external queue is new infrastructure and a monthly bill, which the brief rules out.

## Consequences

- **What this buys:** `race_test.py` passed **11 of 11 consecutive runs**:
  275 last-unit races and 4,400 flash-sale attempts, with 0 oversold and 0 errors.
- **What this costs:** Buyers of one product queue on its row for about 2 ms
  each. And because a pending order now holds real stock, a cancelled order
  must give it back; this is the improvement beyond the brief
  ([`improvement.md`](../improvement.md)). The 15,983 historical pending orders
  never took stock and are not re-reserved: they average 110 days old (F-11).
- **What it costs the client if I am wrong:** Oversold units mean refunds and
  reviews; the CHECK rule turns any oversell into an error instead. If the
  warehouse also writes a sale movement at shipping, new orders would be
  counted twice: shipping must stop doing that for orders placed through
  `place_order()`.
- **What would make me revisit this:** Multi-product baskets (see below), or one
  product needing more than about 400 sales a second.

## What this survives

One product's row takes roughly 400–500 sales a second at about 2 ms each on a
warm connection; the flash sale needs 40 a second. Measured figures are in
[`measurements/order_placement.md`](../measurements/order_placement.md). It
does **not** survive 400 simultaneous *direct* connections on a default server
(the test needs `max_connections = 500`): the application should share a pool
of connections. A basket version must lock its products in a fixed order
(`ORDER BY product_id`), or two baskets holding the same products in opposite
order will deadlock.
