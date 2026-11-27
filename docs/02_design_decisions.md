# Kloud Kart — Design Decisions

Each decision states what was chosen, what was rejected and why, and **what it
costs Nana if the decision turns out to be wrong**. Where the brief left
something open, the assumption is marked **Assumption**.

Sections are added milestone by milestone:

1. [Cleaning and hardening](#1-cleaning-and-hardening) (`sql/10`–`30`)
2. [Overselling and the audit trail](#2-overselling-and-the-audit-trail) (`sql/40`–`50`)
3. [Low-stock rollup](#3-low-stock-rollup) (`sql/60`)
4. [Monday report](#4-monday-report) (`sql/70`)
5. [Improvement beyond the brief: cancellations return stock](#5-improvement-beyond-the-brief-cancellations-return-stock) (`sql/80`)

---

## 1. Cleaning and hardening

### 1.1 Nothing is deleted; bad rows are quarantined

**Decision.** Every removed row moves to `data_quarantine` with its full
original content (`jsonb`) and a reason code. Every changed value is written to
`data_corrections` with old value, new value and reason. Bulk format changes
(status spelling, contact formats) are logged as one summary row per mapping.

**Rejected.**
- *Delete bad rows.* Simplest, but it destroys evidence Nana asked to keep
  ("proof of what happened"), and nobody could reverse a wrong call.
- *Flag columns (`is_valid`) on the live tables.* This keeps the rows in place,
  but every report, today's and future ones, must remember to filter on the flag.
  One forgotten `WHERE` re-introduces GHS 1.49M of phantom sales.
- *A per-row log for bulk changes.* That would be 116k rows recording that
  `COMPLETED` became `completed`: noise that buries the corrections an auditor
  actually needs to read.

**Cost if wrong.** Low: any quarantined row can be restored from its `row_data`.

### 1.2 What was cleaned, and what was deliberately not

| Finding | Action | Rows | Why this and not something else |
|---|---|---|---|
| D2 status spellings | Mapped to `pending, shipped, completed, cancelled, refunded` | 116,394 changed | `complete` = `completed` and `canceled` = `cancelled` are spelling variants, not different states. |
| D11 contact formats | Email `lower(trim())`, city `initcap(trim())`, phone to `+233XXXXXXXXX` | 3,437 / 8,109 / 24,024 | One statement, near-zero risk. Unrecognised phones are left as entered rather than guessed. |
| #12 name capitalisation | **Not changed** | 0 | Cosmetic, and `initcap` breaks names such as `McDonald` and `O'Neil`: risk with no benefit to Nana's four asks. |
| D4 category loop | `Promotions (9002)` made a root; `Seasonal Promotions (9001)` stays under it | 1 | The general category should contain the specific one, not the reverse. |
| D4 missing parent | `Clearance (9003)` made a root | 1 | Its real parent is unknowable; a root is visible in the rollup, a guess could hide it in the wrong branch. |
| D4 uncategorised products | **Not changed** | 37 | Inventing a category would be a guess; the rollup reports them as their own bucket. |
| D5 quantity 999 / 9,999 | Corrected from the order total, otherwise quarantined | 5 corrected, 1 quarantined | None of these lines was in its order's `total_amount`, so `(total − other lines) ÷ unit_price` gives the true quantity. For 5 lines it is a whole number (1, 2 or 3). The sixth gives 10.11, so its true quantity is unknown. |
| D7 duplicate lines | Later exact copy quarantined **only where the order total proves it was never charged** | 527 of 578 exact copies | The other 51 may be genuine (the same item added twice and paid for twice), so they stay. |
| D6 orphan order lines | Quarantined | 692 | Their order does not exist; no report can attribute them. |
| D6 orders of missing customers | Quarantined with their lines | 210 orders, 470 lines | Customer IDs 999,007–999,997 lie outside the real range (100,001–140,420): test residue, not lost customers. |
| D10 orders after the extract | Quarantined with their lines | 24 orders, 48 lines | Their real date is unknowable, and each would sit in the wrong month of the 12-month trend. |
| D6 movements of missing products | Quarantined | 120 | Product IDs 99,011–99,999 lie outside the real range; no shelf exists to count. |
| D8 totals vs lines | **Not changed** | 0 | About 1,700 are exact-percentage checkout adjustments: `total_amount` is what the customer was charged. The ~430 unexplained ones are listed, not "fixed": no rule recovers the truth. |
| D8 NULL unit prices | **Not changed**; column stays nullable | 148 | Inventing a price would falsify revenue. Every new line from `place_order` carries a price. |
| D9 duplicate customers | **Not merged** | 533 people | Merging is irreversible and the accounts carry different phones and cities. Addressed in the report instead (see section 4). |

### 1.3 Stock: the counter is kept, and the ledger is reconciled to it

**Decision.** For each of the 144 products where `stock_quantity` and the sum of
`inventory_log` disagree, one `correction` movement is added so the ledger
equals the counter, with a note naming both old figures. The 14 negative
products are then reset to 0 through a second visible movement. All of them,
plus every product touched by a duplicate line, are listed in the
`products_to_recount` view (640 products).

**Why the counter.** For 42 of the 144 products the drift equals exactly the
units sold with no movement row: the counter was updated and the ledger write
was lost. Nothing points the other way.

**Rejected.**
- *Overwrite the counter with the ledger.* It would undo real sales on 42
  products and make stock look higher than it is, which recreates overselling.
- *Backfill the missing sale rows individually.* More precise for those 42, but
  it explains only part of the drift; the rest would still need a correction.
  Two mechanisms where one suffices.
- *Leave the drift.* Then "stock = sum of movements" can never be checked
  again, and the audit trail Nana asked for starts out broken.

**Assumption.** No physical stock count is available. **Cost if wrong:** up to
2,553 units are mis-stated across 144 products until the shelves are counted;
that is why they head the recount list rather than being declared fixed.

### 1.4 Rules the database now enforces

| Rule | Mechanism | Stops |
|---|---|---|
| Stock never below zero | `CHECK (stock_quantity >= 0)` | D1: the last line of defence against overselling, whatever the application does |
| Status from a fixed list | `CHECK (status IN (...))` | D2 |
| Movement sign matches reason (sale/damage < 0, restock/return > 0, stock-take = 0) | `CHECK` | Mis-signed ledger entries (D3) |
| No orphans | 6 foreign keys | D6, and any future orphan |
| No category loops at any depth | `BEFORE` trigger walking ancestors | D4: a foreign key cannot see a loop |
| Positive quantities, non-negative prices and totals | `CHECK` | D5 |
| Required values | `NOT NULL` | Half-written rows |
| Safe ID generation | Identity columns, started above every ID ever referenced | Two concurrent orders picking the same `max()+1` |

**CHECK lists instead of lookup tables** for status and movement reason. The
movement rule needs a CHECK anyway, because the allowed sign depends on the
reason, which a foreign key cannot express. Both vocabularies are small and
stable. **Cost if wrong:** adding a status (say `returned`) is one
`ALTER TABLE ... DROP/ADD CONSTRAINT`, run in seconds.

**Why a trigger for categories.** This is the one rule a constraint cannot
express. The trigger takes a transaction-level advisory lock so that two
simultaneous edits cannot each pass the check and together close a loop.
(Upgrading the table lock instead would deadlock two such edits.) Category
edits are rare, so serialising them costs nothing.

**Why no UNIQUE on email.** 533 people already hold duplicate accounts, so the
constraint cannot be added without merging them first (see 1.2). A plain index
keeps lookups by email fast in the meantime.

**Foreign-key indexes.** PostgreSQL does not index the referencing side of a
foreign key. Without these six indexes every parent-to-child join, and every
delete of a parent, scans the whole child table. Report-specific indexes are
decided in section 4, with before/after measurements.

### 1.5 Verified, not assumed

- `20_clean.sql` runs in a single transaction and ends with invariants (canonical
  statuses, no negative stock, counter = ledger for every product, no orphans,
  no loops, no implausible quantities). If any fails, nothing is committed.
- `tests/constraints_test.sql` attempts 13 bad writes and passes only if each is
  rejected with the expected error. It also checks that a legal category move
  still works. It runs in a rolled-back transaction.
- The full rebuild (fresh load plus scripts) takes about 15 seconds and is
  re-runnable.

---

## 2. Overselling and the audit trail

### 2.1 The cause: "check, then act" in two steps

Last month's two oversells came from a gap between *reading* the stock and
*writing* the sale. Two buyers both read "1 left", both pass the check, and
both write. Anything that keeps the check and the write as two separate steps
keeps the gap, however fast the steps are.

### 2.2 Decision: one atomic conditional decrement

`place_order()` takes stock with a single statement:

```sql
UPDATE products SET stock_quantity = stock_quantity - p_quantity
WHERE product_id = p_product_id AND stock_quantity >= p_quantity
```

At PostgreSQL's default isolation level (READ COMMITTED), a second buyer's
UPDATE on the same row **waits** for the first buyer's row lock. When the first
commits, PostgreSQL **re-reads the current row and re-checks the `WHERE`**. If
the stock is gone, the UPDATE matches no row and the function returns
`success = false`, "Out of stock: … requested, … available". The check and the
decrement are one indivisible step, so a unit cannot be sold twice, and
nothing can fail with a serialization error, so there is nothing to retry.

The order, its line and the sale movement are written in the same transaction
as the decrement: no order without its stock movement, and no movement without
its order. `CHECK (stock_quantity >= 0)` remains as a backstop for any other
code path that touches stock.

### 2.3 Would triggers alone have fixed it? No: measured, not argued

"Use triggers" usually means the application keeps its flow (check stock, then
write the order) and a trigger on `order_items` takes the stock, so nobody can
forget to. `experiments/trigger_only.sql` builds exactly that, and
`scripts/run_trigger_experiment.sh` runs the **unmodified** `race_test.py`
against it in a throwaway copy of the database. Full output is in
[`docs/evidence/`](evidence/).

| Design | Flash sale: 400 buyers, 50 units | Last unit, 25 rounds |
|---|---|---|
| Triggers only | **400 sold; stock ends at −350** | 25/25 rounds oversold |
| Triggers + `CHECK (stock >= 0)` | 50 sold, but **350 buyers get a database error** instead of "out of stock" | 25/25 rounds fail |
| **`place_order()` (chosen)** | **Exactly 50 sold, 350 clean refusals, 0 errors** | **25/25 correct** |

A trigger runs *inside* the writing transaction, after the application has
already decided to sell. It can do only two things with an oversell: let it
happen, or abort with an error. An error cannot tell the customer "out of
stock"; it tells the application "something crashed". The trigger was never the
mechanism that mattered: the atomic check-and-decrement is, wherever it lives.
A trigger can host that same `UPDATE … WHERE stock >= qty`, but it still has
only an exception to report failure with, which breaks the instant, clear "out
of stock" Nana promised.

**What a naive build would have cost.** In the first flash sale: 350 orders for
stock that does not exist, which means 350 refunds and apologies in ten
seconds, against the two last month.

### 2.4 Alternatives rejected

| Alternative | Correct? | Why not |
|---|---|---|
| `SELECT … FOR UPDATE`, check in code, then `UPDATE` | Yes | Takes the same row lock in two statements and more code. The single conditional UPDATE is the same lock with less to get wrong. |
| `SERIALIZABLE` isolation | Yes, no oversell | Under contention it aborts transactions with serialization failures. These cannot be retried inside the function, because the transaction is already dead. They would reach the caller, which the contract forbids, and 400 buyers on one row would mostly fail and retry: a retry storm at the worst moment. |
| Optimistic locking (version column, retry on conflict) | Yes | Same retry storm: with 400 buyers on one row, nearly every first attempt conflicts. |
| Advisory lock per product | Yes | A second locking mechanism alongside the row lock that already exists. |
| Queue or lock outside the database (Redis, message broker) | Yes | New infrastructure and a monthly bill, which the brief rules out. |

### 2.5 Flash-sale readiness: measured

| Measurement | Result |
|---|---|
| `race_test.py`, full suite | **Passed 11 of 11 consecutive runs** (275 last-unit races, 4,400 flash-sale attempts, 0 oversold, 0 errors) |
| One `place_order` call, warm connection | about 2 ms when it sells, about 1 ms when it refuses |
| Same, first call on a new connection | about 7 ms (the server process loads its caches) |
| Flash sale in the test (400 *new* connections at once, 8 CPUs) | about 4 s wall clock. Median 0.45 s to buy, 1.5 s to be refused |

The test's latency is dominated by 400 brand-new server processes starting at
the same instant, not by the lock. In production the application reuses a pool
of warm connections. At about 2 ms per sale, one product's row can take roughly
**400–500 sales a second**; the flash sale needs 40 a second (400 in 10 s).

**Fast refusal.** Before queuing for the lock, `place_order()` does a plain,
lock-free read of the stock, and refuses at once if there is not enough. This
can only refuse early, never sell: every sale still goes through the atomic
UPDATE, so a stale read cannot oversell. It means late buyers in a sold-out
flash sale are not queued behind the winners only to be refused. In the test it
cut the median refusal from 1.9 s to about 1.55 s; the rest is the connection
start-up above.

**What does not survive, and what to do about it:**
- **400 simultaneous *direct* connections.** The test needs `max_connections =
  500`. Each PostgreSQL connection is a process, so the application should
  share a small pool of connections rather than open one per customer.
- **Multi-product baskets.** The contract is one product per call. A basket
  version must lock its products in a fixed order (`ORDER BY product_id`), or
  two baskets holding the same two products in opposite order will deadlock.

### 2.6 Decision: stock is taken at checkout, not at fulfilment

Historically stock moved when an order shipped (diagnosis N5), which left the
oversell window open between payment and shipping. New orders take stock at
checkout and start as `pending`.

**Consequence.** A cancelled order must return its stock, or every
cancellation leaves units permanently off the shelf. This is what
`cancel_order()` does (section 5). **Assumption:** historical pending orders
(placed before this change) did not reserve stock, so they are not
re-reserved retroactively, and cancelling one returns nothing.

### 2.7 The audit trail

| Piece | What it gives the auditor |
|---|---|
| `inventory_log.order_id` | Each sale points to its order. **261,574 historical sales were linked**: each matched exactly one order on product and timestamp, none ambiguous. The 394 left unlinked belong to quarantined orders. |
| Foreign key on `order_id`, `DEFERRABLE INITIALLY DEFERRED` | It cannot point at an order that does not exist. It is checked at commit rather than per statement, so a transaction may remove an order and its movements in either order. (The provided `race_test.py` cleans up orders first.) |
| UPDATE and TRUNCATE refused by trigger | History cannot be rewritten. A wrong movement is fixed by adding a `correction`, which is itself visible. |
| DELETE copied to `inventory_log_deleted` with database user and time | Deletion stays possible (test fixtures, data-protection requests), but never invisible. |

**Rejected: refuse DELETE as well.** `race_test.py` deletes its own fixture
movements, and it must run unmodified. A genuine data-protection deletion would
also be blocked.

**Limit, stated honestly.** A database superuser can disable triggers. Real
tamper-resistance needs separate database roles: the application role gets
INSERT on `inventory_log` but not UPDATE or DELETE. This is recommended in the
memo; it is configuration Kloud Kart's team must own.

### 2.8 Security of `place_order`

- `SET search_path = public, pg_temp`: a caller cannot make the function use a
  look-alike table planted in another schema.
- Inputs are validated (quantity at least 1, customer and product exist) and
  answered with `success = false` and a reason, never with a crash.
- Parameters are used as values, never concatenated into SQL, so there is no
  injection path.

---

## 3. Low-stock rollup

### 3.1 What "low" means (the brief leaves it open)

**Decision.** Each product has a `reorder_level`. A product is **out of stock**
at 0 and **low** when `0 < stock ≤ reorder_level`. The level is seeded as **two
weeks of that product's own sales**, averaged over the last 8 weeks of trading
(minimum 1). New products default to 10, which is two weeks at the median
product's rate of about 4.6 units a week.

**Why not a single threshold.** Median stock is only 12 units, so "≤ 10 units"
flags **1,949 of 4,023 products (48%)**: not "at a glance". It also treats a
product that sells 1 a month the same as one that sells 20 a week.

**Why stored, not computed live.** It lets operations override individual
products (seasonal lines, slow suppliers). It keeps the view from scanning
280k movements on every refresh. And the extract ends in August 2026, so "the
last 8 weeks before today" would contain no sales at all; the seed uses the
last 8 weeks *of the data*.

**Assumptions.** The supplier lead time is unknown, so two weeks of cover is a
judgement. Kloud Kart runs lean (median stock is about 2.6 weeks of sales), so
even this rule flags 1,385 products as low and 591 as out. **Cost if wrong:**
too low a level means late reorders and stock-outs; too high means a noisy list.
Either way it is one `UPDATE` per product or category, owned by operations.

### 3.2 How the tree is walked

**Decision.** A recursive query (`WITH RECURSIVE`) at read time, in three views:

| View | Shows |
|---|---|
| `category_tree` | Every category with its depth and full path (`Electronics > Phones > Phone Accessories > Cases`) |
| `low_stock_by_category` | For each category, its **whole subtree** at any depth: products, out of stock, low, units on hand. One `(Uncategorised)` row, so the 37 products without a category are never invisible |
| `low_stock_products` | The drill-down: every out or low product with its category path, most urgent first |

**Depth is never assumed.** The recursion follows `parent_id` until it runs
out. A test hangs three new levels under Cases and checks the product rolls up
through all seven.

**It cannot hang.** Both recursive views use the SQL-standard `CYCLE` clause, so
a loop ends the walk instead of running forever. That is the second line of
defence; the trigger from section 1.4 refuses loops in the first place. A test
bypasses the trigger, forces Electronics under its own grandchild, and checks
both views still answer within 5 seconds.

**Rejected alternatives.**

| Alternative | Why not |
|---|---|
| Fixed self-joins (category → parent → grandparent → …) | Hard-codes the depth, which the brief forbids; breaks the day marketing adds a fifth level. |
| A closure table (every ancestor–descendant pair stored) maintained by triggers | Fast reads, but a second copy of the tree that must be kept in sync on every edit. With 94 categories, and 5,000 still read in under 0.25 s, there is nothing to buy with that complexity. |
| `ltree` materialised paths | An extension plus a path column to maintain; same synchronisation burden as a closure table. |
| A materialised view refreshed on a schedule | Faster still, but stale between refreshes, which is wrong for a stock screen during a flash sale. |

### 3.3 Performance: measured before and after

`benchmarks/low_stock_at_scale.sql` builds, inside a rolled-back transaction,
a ragged tree **50× today's size**: 5,095 categories, 11 levels, 204,023
products.

| Version | Today (94 categories, 4,023 products) | 50× scale |
|---|---|---|
| First version: join each product to every ancestor, then aggregate | 17 ms | **3.66 s** (over budget) |
| **Chosen: aggregate per category first, then roll the totals up** | **8 ms** | **0.16–0.24 s** |
| Drill-down, 50 most urgent products | 19 ms | 0.04–0.10 s |

The first version copied every product once per ancestor level, about 1.2
million rows at scale. Aggregating first rolls up only one row per category.
The answer is identical; the tests check the rollup arithmetic at every node.

**A trap found while measuring.** After the benchmark, the real rollup suddenly
took 600 ms. `EXPLAIN ANALYZE` showed why. `ANALYZE` row estimates are **not**
rolled back with a transaction, so the planner still believed the 5,000-category
tree existed. It over-estimated the work, switched on JIT compilation, and
spent 576 ms compiling an 8 ms query. The benchmark now re-runs `ANALYZE`
after its rollback. The general lesson for Kloud Kart's team: stale statistics
can make a fast query slow without any change to the query; autovacuum keeps
them fresh in normal operation. Worst case, the JIT cost adds about 0.6 s, which
is still inside the "couple of seconds" budget.

---

## 4. Monday report

### 4.1 Definitions the brief leaves open

| Question | Decision | Why | Cost if wrong |
|---|---|---|---|
| What counts as "spent"? | `completed` and `shipped` orders | Cancelled and refunded orders are money returned. **Pending orders are excluded too**: they average 110 days old, the same as completed ones (diagnosis #14), so "pending" means stuck, not about to ship. | Pending orders are 9.9% of order value (GHS 48M). If they were in fact paid, every customer's spend is understated by about that much. One word in the function changes it. |
| What is "trailing 12 months"? | The 12 **complete** calendar months before the month of the report date. Run on Monday 7 September 2026: September 2025 to August 2026. The date is a parameter that defaults to today. | A partial current month would make the latest column look like a collapse every week. | None to the totals; only which month is shown last. |
| A running total of what? | Each customer's **cumulative spend at the end of each month**, including everything before the window | This is the figure Adwoa keeps by hand; the last value equals the customer's total spent. | Low: if she tracks something else, the monthly detail function has all the parts. |
| How are ties ranked? | `RANK()`: equal spenders share a rank, so "top 100" can return a few more than 100 rows | Choosing who drops out of a tie would be arbitrary. | None. |
| What is a "customer"? | An **account**. The 533 people with two or three accounts are flagged (`accounts_sharing_email`), not merged | Merging is irreversible, and the accounts carry different phone numbers (diagnosis #9). | Such a person's spend is split across rows, so they can rank lower than they should. The flag makes them visible. |

### 4.2 Shape: two functions sharing one definition

| Function | Returns |
|---|---|
| `customer_monthly_spend(as_of)` | One row per customer per month: orders, spend, running orders, running total. The detail behind the report. |
| `monday_customer_report(as_of)` | One row per customer: rank, total spent, order count, last-12-month spend, the 12 monthly spends and 12 running totals as arrays, and the duplicate-account flag. **Built from the detail function**, so the summary and the detail can never disagree. |

The top 100 is `WHERE spend_rank <= 100` on the second function, not a third
query with its own definitions.

### 4.3 Performance: measured before and after

`scripts/run_report_benchmark.sh` loads the extract **exactly as delivered**
into a separate database and times each version. Output:
[`docs/evidence/report_benchmark.txt`](evidence/report_benchmark.txt).

| Version | All 40,420 customers |
|---|---|
| **Before:** raw extract, report written as sub-queries per customer and per month (26 scans of `orders` per customer) | **≈ 3 hours** (2.9–3.1 h across runs), extrapolated from a measured 20-customer sample at 260–278 ms per customer |
| Indexes only: the same sub-queries on the indexed database | 7.5–7.6 s |
| Rewrite only: the set-based query on the raw extract, **no indexes** | 1.1–1.5 s |
| **After:** `monday_customer_report()`, every column for every customer | **1.5–2.0 s** |
| After, at about 10× volume: 1.6M orders and 100,420 customers (`benchmarks/report_at_scale.sql`) | **5.1–5.7 s** |

**What made it fast.** The report reads `orders` once, groups it, and lets window
functions produce the running totals and the ranking. The naive version
re-reads the table 26 times per customer.

**Why not just indexes.** An index on `orders.customer_id` makes each of the
naive version's lookups fast, and today that alone gets it to 7.6 s. But it
still issues about a million lookups per run (26 for each of 40,420
customers), and that number grows with every new customer. The set-based
version's cost follows the number of orders, not customers × months.

**Why not a bigger server.** Both fixes are about how much work the query does,
not how fast the hardware does it. The rewrite alone took the raw extract from
hours to about a second on a laptop. Direct evidence: giving the query more
memory (`work_mem` 32 MB or 64 MB instead of 4 MB) made it **slower** at 10×
volume (6.3–11.6 s against 5.3–5.7 s), because the planner switched to plans
that suit the bigger budget worse.

**Three plan problems found and fixed with `EXPLAIN ANALYZE`:**

1. **The function wrapper doubled the cost.** A `SET search_path` clause stops
   PostgreSQL from inlining a SQL function, so 485,040 detail rows were stored
   and read back. The clause was removed and every table is schema-qualified
   (`public.orders`) instead, which keeps the protection against look-alike
   tables.
2. **The month list was mis-estimated by 80×.** `generate_series` over dates is
   always estimated at 1,000 rows, which inflated the plan to 40 million rows.
   An integer series (`0..11`) is estimated exactly.
3. **One join re-read 9.3 million rows to produce 1.2 million (at 10× volume).**
   Joining on a computed month date let PostgreSQL merge on the customer only.
   An integer month index gives the join two plain keys. This cut the 10×
   run from 7.2 s to 5.6 s.

**Tested and left alone.** JIT compilation costs about 0.57 s on this query and
gains about as much back; with it on or off, the results were within
run-to-run noise. Server settings were not changed: no measurable gain, and
one more thing for Kloud Kart's team to maintain.

**What survives growth, and what does not.** At the brief's 4,000 orders a day,
a year is about 1.5M orders, close to the 10× test: about 5.5 s. Cost grows
roughly in line with orders and customers. At several times that volume, the
next step is a monthly spend table kept up to date as orders are placed, so
the report reads 12 small rows per customer instead of every order. It is not
built now because it adds a write on every order to save seconds nobody is
waiting for yet.

### 4.4 Correctness

`tests/monday_report_test.sql` (13 checks, rolled back) compares every
customer's total and order count with a direct count, checks that the 12
months add up and the running totals step correctly, checks that ranks follow
spend and that the summary agrees with the detail, and then tests each
definition at its boundary on a new customer: pending, cancelled and refunded
orders excluded, an order before the window counted in the total only, window
start inclusive and window end exclusive.

**A test that ran for 8 hours.** One check was written as `NOT EXISTS (join of
two 40k-row tables)`. Inside `EXISTS`, PostgreSQL plans to stop at the first
match and picked a nested loop. When nothing differs, as here, that compares
all 1.6 billion pairs. Rewritten as `count(*) = 0`, it takes milliseconds.
Every SQL test now runs with a 2-minute statement timeout, so a bad plan fails
the test instead of hanging it.

### 4.5 What the report cannot fix

All 100 of the top-100 customers bought at least one of the 116 products with
suspect prices (diagnosis #13), and those products make up 44% of the spend
the report counts. The report is arithmetically correct, but **its ranking is
only as trustworthy as the price list.** This is stated in the memo as
something to verify before the ranking is used for decisions.

---

## 5. Improvement beyond the brief: cancellations return stock

### 5.1 Why this one

The brief asks for one improvement, justified by what it is worth to Nana or
Adwoa. Three candidates came out of the work:

| Candidate | Worth | Chosen? |
|---|---|---|
| **`cancel_order()`: a cancelled order gives its stock back, with an audit movement** | Keeps Nana's stock figures true after go-live. Closes a gap this solution itself opened. | **Yes** |
| A price-anomaly watch: products priced far outside their category, and the report spend that depends on them | Protects Adwoa's ranking (diagnosis #13) | Recommended in the memo |
| A stuck-orders list: pending orders older than N days, with value and customer | An action list for GHS 48M (diagnosis #14) | Recommended in the memo |

**Why it matters most.** `place_order()` now takes stock at checkout (decision
2.6). Without a cancellation path, every cancelled order would keep its units
off the shelf for ever. Each cancellation would leave one more product showing
less stock than is really there, and within weeks Nana's figures would drift
back to the state he started with: counts nobody trusts. The two watch lists
report problems; this prevents one, and it protects Nana's first priority.

### 5.2 Key decision: return what the ledger says, not what the order says

`cancel_order()` returns, per product, the stock **the order's own movements in
`inventory_log` show it still holds**, not its line quantities.

| | Returns line quantities | Returns what the ledger shows (chosen) |
|---|---|---|
| New order from `place_order` | 3 units back | 3 units back |
| **Historical pending order** (stock was never taken: it used to move at shipping) | **Invents stock.** Across the 15,983 such orders: up to **53,223 phantom units** | Nothing back, because nothing was taken |
| Same order cancelled twice | Twice the stock, unless something else stops it | Nothing the second time: the ledger already shows it returned |

This is only possible because every movement now carries its `order_id`
(decision 2.7). The audit trail is what makes the cancellation correct.

### 5.3 The rest of the design

| Decision | Why |
|---|---|
| Only `pending` orders can be cancelled | Shipped goods have left the warehouse; taking them back is a return, a different process with a different movement reason. |
| Status change is one conditional `UPDATE … WHERE status = 'pending'` | Same pattern as `place_order`: of several simultaneous cancellations, exactly one changes the row. The others get "already cancelled". |
| New movement reason `cancellation` (must add stock) | An auditor can tell an order that never left the warehouse from goods a customer handed back (`return`). The sign rule from 1.4 is extended, not bypassed. |
| Products locked in `product_id` order before stock is returned | Two cancellations sharing products always lock them in the same order, so they cannot deadlock. |
| Clear refusals: unknown order, already cancelled, not pending | Same contract style as `place_order`: `success = false` with a reason, never a crash. |

### 5.4 Evidence

- `tests/cancel_order_test.sql` (15 checks): stock and ledger back level after a
  cancellation; a cancellation movement linked to the order; a second
  cancellation refused; shipped and unknown orders refused; a historical
  pending order cancelled with **no** stock returned; a two-product order getting
  every unit back; a negative `cancellation` movement rejected.
- `tests/cancel_race_test.py` (same style as `race_test.py`): 10 simultaneous
  cancellations of one order, 25 rounds, exactly one succeeds each time; every
  flash-sale winner cancels while 100 new buyers race for the returned units,
  with no errors, no negative stock, and counter = ledger = 50 minus units still
  on order; 40 two-product orders with their lines in opposite orders, all
  cancelled at once, with no deadlock.
- **The test was checked against a deliberately broken version.** With the
  `status = 'pending'` guard removed, it failed all 25 rounds of the
  double-cancel test (10 "successes" each). It also showed something useful: even
  with the guard gone, **no stock was returned twice**, because the ledger had
  nothing left to give back. The design has two independent layers: the status
  guard gives callers the right answer, and the ledger keeps the stock right
  even if that guard is ever broken.

### 5.5 What it does not do

- It does not handle returns of delivered goods (a `return` movement after
  `shipped`/`completed`). That needs a business rule on refunds and the
  condition of returned goods that only Nana can set.
- It cancels whole orders. Removing one line from a multi-line order would need
  its own function on the same ledger principle.
