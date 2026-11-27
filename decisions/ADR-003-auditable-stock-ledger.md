# ADR-003: Make the movement ledger the auditable record of stock: reconciled to the counter, linked to orders, append-only

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Kemoko Foumba Traore

## Context

Nana wants "a trail of every stock movement, sale, restock, correction, that
an auditor could walk through after the fact". In the extract the trail is
broken three ways (F-04):

- For 144 products, the stock counter and the sum of their movements disagree,
  by 2,553 units in total.
- A sale can be tied to its order only by matching product and timestamp.
- Any movement can be edited or deleted without trace, and 425 corrections carry
  notes such as `??` and `see WhatsApp msg`.

No physical stock count is available.

## Decision

1. **Keep the counter, reconcile the ledger to it.** For each drifting product I
   add one `correction` movement whose note names both old figures. The 14
   negative products are then set to 0 through a second visible movement. The
   640 affected products are listed in the `products_to_recount` view.
2. **Link every sale to its order.** A new `inventory_log.order_id`, filled for
   all 261,574 historical sales: each matched exactly one order, none ambiguous.
   A foreign key checked at commit keeps the link honest.
3. **Append-only.** UPDATE and TRUNCATE on the ledger are refused by trigger. A
   DELETE is allowed, but every deleted row is copied to `inventory_log_deleted`
   with the database user and time.

## Alternatives considered

### Alternative A: Overwrite the counter with the ledger

- **How it would work:** `stock_quantity := sum(change_qty)` for the 144.
- **Why it is attractive:** The ledger is the detailed record.
- **Why rejected:** For 42 of the 144, the drift equals exactly the units sold
  with no movement: the counter was right and the ledger write was lost.
  Overwriting would undo real sales and show stock that is not there, which
  recreates overselling.

### Alternative B: Leave the drift

- **How it would work:** Do nothing.
- **Why it is attractive:** No judgement made.
- **Why rejected:** "Stock = sum of movements" could never be checked again,
  and the audit trail would start out broken.

### Alternative C: Refuse DELETE as well

- **How it would work:** The same trigger blocks deletion.
- **Why it is attractive:** A truly immutable ledger.
- **Why rejected:** `race_test.py` deletes its own fixture movements and must run
  unmodified, and a genuine data-protection request would also be blocked.
  Making deletion visible gives the auditor what they need.

### Alternative D: Keep matching sales to orders on timestamps

- **How it would work:** The auditor joins on product and time.
- **Why it is attractive:** No schema change.
- **Why rejected:** It works today only because no two orders for the same
  product share a timestamp, and it breaks at flash-sale volumes.

## Consequences

- **What this buys:** "Stock = sum of movements" holds for every product, and the
  clean-up's invariants and the tests check it. Any order leads to its stock
  movements and back in one join. A wrong movement is fixed by adding a visible
  correction, never by rewriting history.
- **What this costs:** 158 movements that record a reconciliation rather than a
  physical event; one column and one archive table.
- **What it costs the client if I am wrong:** Up to 2,553 units mis-stated across
  144 products until the shelves are counted; that is why they head the recount
  list instead of being declared fixed. And the triggers can be disabled by a
  database superuser: real tamper-resistance needs separate database roles
  (the application may add movements, not change them), which the memo
  recommends.
- **What would make me revisit this:** A physical count that contradicts the
  counter for most of these products.

## What this survives

Contention: every movement is written in the same transaction as its stock
change. `race_test.py` Test 4 ("every successful purchase left a stock movement
behind") passes under contention, and `tests/cancel_race_test.py` checks counter
= ledger after a flash sale with cancellations. `tests/place_order_test.sql`
proves an UPDATE is refused and a DELETE archived.
