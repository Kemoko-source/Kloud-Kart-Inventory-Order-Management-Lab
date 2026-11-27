# Improvement beyond the brief: cancelled orders give their stock back

## The problem it solves

To end overselling, stock is now taken the moment an order is placed, not when
it ships ([ADR-002](decisions/ADR-002-atomic-stock-decrement-at-checkout.md)).
That closes the race, but it opens a new gap: when a customer cancels, nothing
puts their units back. Every cancellation would leave stock off the shelf for
ever, the counts would drift lower than reality week by week, and within months
Nana would be back where he started: stock figures nobody trusts.

The obvious fix is wrong for this database. "Add the order's line quantities
back" works for new orders, but **15,983 historical pending orders never took
any stock** (stock used to move at shipping). Cancelling them that way would
invent up to **53,223 units** that were never on the shelf, about a fifth of
the whole catalogue's real stock.

## What I built

`cancel_order(order_id, note)` in [`sql/80_cancel_order.sql`](sql/80_cancel_order.sql):

- **It returns what the ledger says the order took**, not what the order lists.
  Since every stock movement now carries its order
  ([ADR-003](decisions/ADR-003-auditable-stock-ledger.md)), the function sums
  this order's movements per product and gives back whatever is still out. A
  new order gets its units back; a historical one gets nothing back, because it
  took nothing; a second cancellation gets nothing, because the ledger already
  shows the stock returned.
- **It cancels exactly once under contention.** The status change is one
  conditional update (`pending` → `cancelled`), the same pattern as
  `place_order()`. Of several simultaneous cancellations, one succeeds; the
  others are told "already cancelled".
- **It cannot deadlock.** Products are locked in a fixed order.
- **It leaves a distinct trail.** A new movement reason, `cancellation`, which
  must add stock, so an auditor can tell an order that never left the warehouse
  from goods a customer handed back (`return`).
- **It refuses clearly**, never with a crash: unknown order, already cancelled,
  or not pending (shipped goods need a return, not a cancellation).

**Tested:**

- [`tests/cancel_order_test.sql`](tests/cancel_order_test.sql), 15 checks:
  stock and ledger back level, refusals, a historical order returning nothing,
  and a two-product order getting every unit back.
- [`tests/cancel_race_test.py`](tests/cancel_race_test.py), in the style of
  `race_test.py`:
  - 10 simultaneous cancellations of one order, 25 rounds: exactly one succeeds
    each time.
  - Every flash-sale winner cancels while 100 new buyers race for the returned
    units: no errors, no negative stock, and stock still equals the sum of its
    movements.
  - 40 two-product orders with their lines in opposite orders, all cancelled at
    once: no deadlock.
- **The test was checked against a deliberately broken version.** With the
  "only pending" guard removed, it failed every round. It also showed that even
  then **no stock was returned twice**, because the ledger had nothing left to
  give back: two independent layers of protection.

## What it is worth to Nana

- **His stock figures stay true after go-live.** Without it, every cancellation
  quietly lowers his counts. With it, a cancelled order's units are back on sale
  at once, including during a flash sale, where cancelled units can go to the
  next buyer.
- **No phantom stock.** The 53,223 units the obvious version would have invented
  would have been sold to customers and then refunded: overselling by another route.
- **His auditor sees every cancellation** as its own line, linked to its order,
  with the note the customer service agent typed.
- **For Adwoa:** cancelled orders already drop out of "spent" in the Monday
  report; now their stock comes back too, so sales and stock tell the same story.

## What it cost

- About a day of work: one function, one new movement reason, 15 SQL checks
  and a three-part concurrency test.
- One schema change: `cancellation` added to the allowed movement reasons, with
  its sign rule.
- **No running cost:** no new infrastructure, and no extra work on the order
  path; a cancellation touches only the order and its products.
- **What it does not do:** take back delivered goods (a return needs refund and
  condition rules only Nana can set), or cancel a single line of a multi-item
  order. Both can follow the same ledger principle.
