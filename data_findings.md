# Data findings — Kloud Kart Ltd.

## Summary

The extract has fourteen problems that matter, two of which are costing money
today: **overselling is not prevented and has already happened** (F-01), and
**order status is free text**, so any report that filters on it silently misses
up to 80% of completed orders (F-02). A third may be the largest of all but
cannot be settled from the data: **116 everyday products are priced like
appliances**, and they carry 44% of the revenue the Monday report counts (F-03).

They share one root cause. The schema has **no foreign keys, no CHECK rules,
no index beyond the primary keys, and no way to generate IDs safely**, so
nothing ever stopped a bad row going in. The fixes in `sql/20_clean.sql`
repair the data; `sql/30_constraints.sql` makes the database refuse each
problem from now on (`tests/constraints_test.sql` proves it, finding by
finding).

Every number below comes from
[`diagnosis/diagnosis_checks.sql`](diagnosis/diagnosis_checks.sql), run
read-only against a fresh load; its check labels match the F-numbers here.
Amounts are in GHS. Nothing was deleted: removed rows are kept verbatim in
`data_quarantine`, and changed values are logged in `data_corrections`
([ADR-001](decisions/ADR-001-quarantine-instead-of-delete.md)).

## Reconciliation

Rows from the extract as delivered to the cleaned database (fresh load plus
`sql/` scripts, before any new orders).

| Stage | Rows | Delta | Reason |
|---|---|---|---|
| **orders**, loaded | 159,384 | | |
| quarantined: customer does not exist | 159,174 | −210 | F-07 |
| quarantined: dated after the extract ends | **159,150** | −24 | F-12 |
| **order_items**, loaded | 336,559 | | |
| quarantined: order does not exist | 335,867 | −692 | F-07 |
| quarantined: line of an order quarantined above | 335,349 | −518 | F-07 (470), F-12 (48) |
| quarantined: duplicate line the total proves was never charged | 334,822 | −527 | F-08 |
| quarantined: quantity of 999 that cannot be recovered | **334,821** | −1 | F-06 |
| **inventory_log**, loaded | 282,352 | | |
| quarantined: product does not exist | 282,232 | −120 | F-07 |
| added: one reconciliation movement per drifting product | 282,376 | +144 | F-04 |
| added: one movement per oversold product, back to zero | **282,390** | +14 | F-01 |
| **customers**, **products**, **categories** | 40,420 / 4,023 / 94 | 0 | values corrected in place, no rows removed |

Values corrected in place (rows unchanged): 116,394 order statuses (F-02), 5
quantities (F-06), 14 stock figures (F-01), 2 category parents (F-05), and
35,570 contact fields (F-13). In total, 2,092 rows are in `data_quarantine` and
178 entries in `data_corrections`.

## Findings, ranked by risk

### F-01: Overselling is not prevented, and has already happened — Severity: Critical

- **What it is:** Nothing stops `stock_quantity` going below zero, and nothing
  serialises two buyers for the same unit. Stock also moved only when an order
  shipped, leaving the gap between payment and shipping open.
- **How I detected it:** Products with stock below zero; a count of the
  schema's constraints (0 CHECK rules); sale movements matched to orders by
  status (none for unshipped orders).
- **Scale:** 14 products below zero; 27 units sold that did not exist.
- **Effect on the client's number:** Every race for a last unit is a refund, an
  apology and a review. A flash sale of 400 orders in 10 seconds makes the
  race near-certain: the experiment in ADR-002 sold **400 units of a 50-unit
  stock** under a naive design.
- **What I did about it:** `place_order()` takes stock in one atomic step at
  checkout ([ADR-002](decisions/ADR-002-atomic-stock-decrement-at-checkout.md));
  a CHECK rule refuses
  negative stock; the 14 products were set to 0 through visible correction
  movements and listed for recount.
- **Residual risk:** Any code path that bypasses `place_order()` is still held
  by the CHECK rule, but would see an error rather than a clean "out of stock".

### F-02: Order status is free text — Severity: Critical

- **What it is:** 15 spellings of 5 statuses: `completed`, ` completed`,
  `COMPLETED`, `Completed`, `complete`; `cancelled`, `canceled`, `CANCELLED`, and
  so on.
- **How I detected it:** Grouping by raw status, then comparing an exact filter
  with a trimmed, lower-cased one.
- **Scale:** All 159,384 orders. `status = 'completed'` finds **22,091 of
  111,351** completed orders (20%).
- **Effect on the client's number:** Any report that filters by status is wrong
  by up to 80%, with no error to warn anyone. The Monday report must filter
  (or it counts cancelled orders as spend).
- **What I did about it:** Mapped to 5 statuses (116,394 rows changed, logged as
  10 mapping entries); a CHECK rule allows only those 5.
- **Residual risk:** None in the database. Applications that write other
  spellings will now be refused, which is intended but needs telling.

### F-03: Everyday goods priced like appliances — Severity: High (unverified)

- **What it is:** 116 products cost 50 to 235 times the median price of their own
  category: cooking oil, kids' clothing, irons, fans, soft drinks and a USB-C
  cable at GHS 16,000–22,000. On a log-scale price histogram they form a
  separate cluster above the normal range, which is the signature of a unit
  error (pesewas entered as cedis) rather than of premium goods.
- **How I detected it:** Checking the Monday report's top-ranked customers by
  hand; then each product's price against its category median, and the
  price histogram.
- **Scale:** 116 products, GHS 214M of line value (43.6% of all). After cleaning,
  GHS 166M of the GHS 380M the report counts as spent (44%). **All 100 of the
  top-100 customers bought at least one.**
- **Effect on the client's number:** If the prices are wrong, revenue is
  overstated by up to 44%, the top-100 ranking measures who bought mispriced
  items, and customers may have been overcharged.
- **What I did about it:** **Nothing to the data.** Customers were charged these
  amounts and the orders completed; only the price list can say which prices
  are real.
- **Residual risk:** High until the price list is checked. See "Could not verify".

### F-04: Stock counter and movement ledger disagree, and the ledger has gaps — Severity: High

- **What it is:** For 3,879 products, stock equals the sum of their movements,
  which shows the ledger is meant to be complete. For 144 it is not. Some sales
  have no movement, and corrections carry notes such as `??`, `see WhatsApp
  msg` and `recount, not applied`.
- **How I detected it:** Each product's stock against the sum of its movements;
  sale movements matched to order lines on product and timestamp; the notes on
  corrections.
- **Scale:** 144 products, 2,553 units of drift (122 products show *less* stock
  than their ledger, by 2,464 units). 137 fulfilled order lines have no sale
  movement. 425 corrections carry untrustworthy notes.
- **Effect on the client's number:** Stock figures cannot be trusted for these
  products, and an auditor walking the trail finds sales with no movement and
  corrections justified by a WhatsApp message.
- **What I did about it:** Kept the counter (for 42 of the 144, the drift
  equals exactly the unlogged sales) and added one labelled correction per
  product so the ledger matches it. Every sale now carries its order, and the
  ledger is append-only ([ADR-003](decisions/ADR-003-auditable-stock-ledger.md)).
  640 products are listed in `products_to_recount`.
- **Residual risk:** Up to 2,553 units mis-stated until the shelves are counted.

### F-05: The category tree has a loop and a dangling branch — Severity: High

- **What it is:** `Seasonal Promotions (9001)` and `Promotions (9002)` are each
  other's parent. `Clearance (9003)` points to a parent (8999) that does not
  exist. 37 products have no category.
- **How I detected it:** A recursive walk up the tree that records its path and
  stops when it revisits a category.
- **Scale:** 1 loop (6 products), 1 dangling category, 37 uncategorised products
  (3,112 units). Depth today: 4.
- **Effect on the client's number:** A naive recursive rollup never finishes on
  the loop, so the low-stock view hangs. A rollup that starts from the roots
  silently drops the loop's products and the 37 uncategorised ones.
- **What I did about it:** Made Promotions and Clearance roots; a trigger now
  refuses any loop at any depth; the rollup is loop-safe anyway and shows an
  "(Uncategorised)" row
  ([ADR-004](decisions/ADR-004-low-stock-rollup.md)).
- **Residual risk:** Clearance's real parent is unknown; it is visible as a root.

### F-06: Implausible quantities — Severity: High

- **What it is:** Six order lines for 999 or 9,999 units. The 99.9th percentile is 10.
- **How I detected it:** Quantities against their percentiles.
- **Scale:** 6 lines worth GHS 3.07M on paper.
- **Effect on the client's number:** Six customers would top any ranking built
  from order lines.
- **What I did about it:** None of these lines was in its order's total, so the
  true quantity is `(total − other lines) ÷ unit price`. For 5 lines that is a
  whole number (1, 2 or 3) and was corrected; the sixth (10.11) was quarantined.
- **Residual risk:** None known.

### F-07: Orphan rows pointing at parents that do not exist — Severity: Medium

- **What it is:** Rows whose parent is missing, each in an ID range outside the
  real one: test or migration residue.
- **How I detected it:** `NOT EXISTS` against each parent; the minimum and
  maximum of the dangling IDs.
- **Scale:** 210 orders → customers 999,007–999,997 (GHS 665,181); 692 order lines
  → orders 900,101–999,862 (GHS 826,328); 120 sale movements → products
  99,011–99,999.
- **Effect on the client's number:** GHS 1.49M of recorded sales belongs to no
  real customer or order. Joins drop these rows while plain sums keep them, so
  two honest reports disagree.
- **What I did about it:** Quarantined, with the 470 lines of the orphan orders;
  foreign keys now refuse new orphans.
- **Residual risk:** None in the data; the quarantine keeps them for audit.

### F-08: Duplicated order lines — Severity: Medium

- **What it is:** The same product twice in one order.
- **How I detected it:** Pairing lines on order and product, then recomputing
  each order's total with and without the copy.
- **Scale:** 618 pairs in 613 orders. For 527 orders the total only matches
  without the copy.
- **Effect on the client's number:** Units sold and product revenue overstated;
  the copy also wrote a second sale movement, draining stock twice.
- **What I did about it:** Quarantined the 527 copies the totals prove were never
  charged; kept the 51 exact copies that may be genuine. Their products are on
  the recount list.
- **Residual risk:** Stock for those products stays understated until counted.

### F-09: Order totals that disagree with their lines for no visible reason — Severity: Medium

- **What it is:** Order totals that are not their lines' sum, beyond the
  explainable percentage adjustments (see "Looked wrong"); lines with no price.
- **How I detected it:** The ratio of total to lines, bucketed.
- **Scale:** About 430 orders with no pattern; 148 lines with no price
  (147 orders); 152 lines priced at 0.
- **Effect on the client's number:** Line-based and order-based revenue
  disagree. The report therefore uses one definition: the order total.
- **What I did about it:** **Not changed**: no rule recovers the truth, and
  inventing a price falsifies revenue.
- **Residual risk:** Product-level revenue for these orders is uncertain.

### F-10: The same customer holds several accounts — Severity: Medium

- **What it is:** Emails equal after trimming and lower-casing, always with the
  same name, usually a different phone.
- **How I detected it:** Grouping customers by normalised email and counting
  distinct names.
- **Scale:** 533 people holding 1,068 accounts.
- **Effect on the client's number:** One person's spend is split across
  accounts, so a real top customer can be missing from the ranking.
- **What I did about it:** **Not merged** (irreversible, and the phones differ).
  The report flags them (`accounts_sharing_email`).
- **Residual risk:** Their ranking is understated until someone confirms and merges.

### F-11: "Pending" orders are stuck, not in progress — Severity: Medium

- **What it is:** Pending orders average 110 days old, the same as completed
  ones; the oldest date from the extract's first week.
- **How I detected it:** Average age of orders by status.
- **Scale:** 16,007 orders, GHS 48.5M.
- **Effect on the client's number:** Either money was taken for orders never
  fulfilled, or orders were abandoned and never closed.
- **What I did about it:** Excluded from "spent" in the report
  ([ADR-005](decisions/ADR-005-monday-report-definitions.md)). The orders are
  left as they are: closing them is a business decision.
- **Residual risk:** GHS 48.5M in a status nobody acts on.

### F-12: Orders dated after the extract ends — Severity: Medium

- **What it is:** Normal trading stops on 2026-08-31; 24 orders run from
  2026-09-06 to 2027-08-20, 15 of them still in the future.
- **How I detected it:** The date range, then the seconds of each timestamp:
  **all 24** are on a whole minute, against 1.68% of normal orders, which points
  to manual entry.
- **Scale:** 24 orders, GHS 68,040.
- **Effect on the client's number:** The 12-month trend anchors on the wrong
  month and shows revenue that has not happened.
- **What I did about it:** Quarantined with their 48 lines.
- **Residual risk:** 40 sale movements at those dates stay in the ledger
  (movements are never rewritten); their orders are in quarantine.

### F-13: Contact data in mixed formats — Severity: Low

- **What it is:** Emails with spaces around them; phones in four formats; city
  spelled `Accra`, `accra`, `ACCRA`, `Accra `.
- **How I detected it:** Pattern counts per format.
- **Scale:** 1,314 padded emails; about 8,000 phones per format; 15 spellings of
  12 cities.
- **Effect on the client's number:** Emails and texts bounce; sales by city split
  Accra four ways. No effect on Nana's four asks.
- **What I did about it:** Trimmed and lower-cased emails, one phone format,
  one spelling per city: three statements, logged.
- **Residual risk:** Unrecognised phone formats were left as entered.

### F-14: Name capitalisation — Severity: Low

- **What it is:** `YAA MENSAH`, `kwesi danso`, names with stray spaces.
- **How I detected it:** Profiling.
- **Scale:** About 5,100 customers.
- **Effect on the client's number:** None.
- **What I did about it:** **Nothing.** Automatic capitalisation breaks names
  such as `McDonald`; risk with no benefit.
- **Residual risk:** Cosmetic only.

## Looked wrong, is not wrong

| Apparent problem | Why it looks wrong | Why it is actually fine |
|---|---|---|
| Order-line price differs from the product's current price (3,964 lines below it) | Same product, two prices | A line records the price at the moment of sale; prices change. Rewriting it would falsify past revenue. |
| 400 product names appear more than once | Looks like duplicate products | Each has its own ID, price and stock in the same category: real variants. Merging would merge stock that is physically different. |
| Order times have no time zone | Times could be misread across zones | Accra is UTC+0 with no daylight saving. Orders peak at 13:00 and bottom out at 00:00, which is a local-time curve. |
| About 1,700 orders whose total is exactly 50%, 75%, 90%, 110% or 125% of their lines | Totals do not add up | Fixed percentages are checkout adjustments (discount codes, fees): the total is what the customer was charged. |
| Pending, cancelled and refunded orders have no sale movement | Looks like a broken audit trail | Stock used to move at shipping; an unshipped order should not move stock. 99.9% of shipped orders have their movement. |
| 90 stock-take movements of zero | A movement that moves nothing | A count that confirmed the stock: a useful audit fact, not an error. |

## Could not verify

| Question | Why the data cannot answer it | What settles it | Finding |
|---|---|---|---|
| Are the 116 high prices real? | Customers paid them, and orders completed | Kloud Kart's price list | F-03 |
| Which is right for the 144 drifting products, counter or ledger? | Both are records; neither is the shelf | A physical count of the 640 products in `products_to_recount` | F-04 |
| Were "pending" orders paid? | No payment data in the extract | Payment records | F-11 |
| Are the 533 shared-email accounts one person each? | Same name and email, different phones | Asking the customers, or the account history | F-10 |
| What did the ~430 unexplained orders really cost? | No pattern links total and lines | The payment or invoice behind each order | F-09 |
| Where does `Clearance` belong in the tree? | Its parent never existed | Marketing | F-05 |
