# Kloud Kart — Data Diagnosis

**Scope:** the provided extract as loaded by `schema.sql` + `load.sql`
(categories 94, products 4,023, customers 40,420, orders 159,384,
order_items 336,559, inventory_log 282,352).
**Evidence:** every number below is produced by
[`diagnosis/diagnosis_checks.sql`](../diagnosis/diagnosis_checks.sql), run
read-only against a fresh load. Check IDs (D1, D2, …) refer to that file.
**Currency:** amounts are in GHS, the unit `price` and `total_amount` are stored in.

## How problems are ranked

Danger is judged by **what the problem does to a decision Nana or Adwoa makes**,
not by how untidy it looks:

- **Critical**: actively costs money or makes one of Nana's four asks impossible today.
- **High**: silently produces a wrong number in a report or stock figure someone acts on.
- **Medium**: distorts a subset of results, or will once the business grows.
- **Low**: cosmetic or contact-quality; worth fixing on the way, never worth a project.

Because the brief warns that not everything that looks wrong is wrong, each
suspicious pattern was **tested before it was called a problem**. Five
patterns that passed that test are listed at the end, with the evidence that
cleared them.

## Ranked findings

| # | Danger | Problem | Size | How it was detected | What it costs Nana if left |
|---|---|---|---|---|---|
| 1 | Critical | **Overselling is not prevented, and has already happened.** Nothing in the schema stops `stock_quantity` going below zero, and nothing serialises two buyers for the same unit. | 14 products below zero, 27 units sold that did not exist. 0 CHECK constraints, 0 foreign keys. | D1: `stock_quantity < 0`; Schema check on `pg_constraint` | Refunds, apologies and reviews every time two orders race, and a flash sale of 400 orders in 10 s makes the race near-certain on the advertised product. |
| 2 | Critical | **Order status is free text.** 15 spellings of 5 statuses (`completed`, ` completed`, `COMPLETED`, `Completed`, `complete`; `cancelled`, `canceled`, `CANCELLED`, …). | 159,384 orders, 100% affected. `status = 'completed'` finds **22,091** of **111,351** completed orders (20%). | D2: `GROUP BY status`, then compare exact vs `lower(trim())` match | Any report that filters by status (the Monday report must, or it counts cancelled and refunded orders as spend) is wrong by up to 80%, with no error to warn anyone. |
| 3 | High | **The stock counter and the movement ledger disagree, and the ledger has gaps.** For 3,879 products, `stock_quantity` equals the sum of `inventory_log`, which proves the ledger is meant to be complete. For the other 144, it is not. | 144 products, 2,553 units of drift (122 products show *less* stock than the ledger says, by 2,464 units; 22 show more, by 89). 137 fulfilled order lines have no sale movement. 425 corrections carry notes such as `??`, `see WhatsApp msg`, `recount, not applied`. | D3a: products vs `sum(change_qty)`; D3b: sale rows matched to order lines on product + timestamp; D3c: notes on corrections | Nana's stock figures cannot be trusted for these products, and an auditor following the trail hits movements with no order, orders with no movement, and corrections justified by a WhatsApp message. This is the "proof of what happened" ask failing today. |
| 4 | High | **The category tree contains a loop and a dangling branch.** `Seasonal Promotions (9001)` → `Promotions (9002)` → `Seasonal Promotions (9001)`. `Clearance (9003)` points to parent `8999`, which does not exist. 37 products have no category. | 1 cycle (6 products), 1 orphan category, 37 uncategorised products (3,112 units). 91 of 94 categories are reachable from a root; maximum depth 4. | D4a: recursive walk with a visited-path array; D4b, D4c | A naive recursive rollup never terminates on the loop, so the low-stock view hangs instead of returning in seconds. A rollup that stops at the roots silently drops the 9001/9002/9003 branch and the 37 uncategorised products. |
| 5 | High | **Implausible quantities.** Six order lines for 999 or 9,999 units. The 99th percentile is 5 and the 99.9th is 10. | 6 lines, **GHS 3,073,442**, about 0.6% of all recorded revenue on 0.002% of lines. | D5: `quantity >= 100`, against the quantity percentiles | Put straight into the top-100 spend ranking: six customers jump to the top on what look like keystroke errors (999 / 9999 are placeholder patterns), and their sale movements drain stock on paper. |
| 6 | Medium | **Orphan rows** referencing parents that do not exist, each in a tell-tale ID range outside the real one (test or migration residue). | 210 orders → customers 999007–999997 (GHS 665,181). 692 order lines (689 orders) → orders 900101–999862 (GHS 826,328). 120 sale movements → products 99011–99999. | D6: `NOT EXISTS` against each parent; min/max of the dangling IDs | GHS 1.49M of recorded sales belongs to no real customer or no real order. Every inner join quietly drops these rows while a plain `sum()` keeps them, so two honest reports give two different answers. Foreign keys cannot be added until they are dealt with. |
| 7 | Medium | **Duplicated order lines** (same order, same product, twice). | 618 duplicate pairs across 613 orders; 579 are exact copies. For **527** of those orders, `total_amount` only matches when the duplicate is removed. | D7: self-join on `(order_id, product_id)`, totals recomputed with and without the copy | Units sold and product revenue are overstated, and the duplicate also wrote a second sale movement, so stock was drained twice. |
| 8 | Medium | **Order totals that disagree with their lines for no visible reason**, and lines with no price. | 2,124 clean orders differ from their lines. About 1,700 are exact percentage adjustments (see N4). The remaining ~430 have no pattern. Plus 148 lines with NULL `unit_price` (147 orders) and 152 lines priced at 0. | D8: ratio `total_amount / sum(lines)` bucketed | Line-level revenue and order-level revenue diverge. The report needs one definition of "spent", and these rows decide which. |
| 9 | Medium | **The same customer holds several accounts.** Emails that are equal after trimming and lower-casing, always with the same name, usually different phone numbers. | 533 people with 2–3 accounts (1,068 accounts). | D9: group by `lower(trim(email))`, count distinct names | The top-100 ranking undercounts real people: one person's spend is split across accounts, so a genuine top customer can be missing from the list. Marketing contacts them twice. |
| 10 | Medium | **Orders dated after the extract ends.** Normal traffic stops on 2026-08-31; 24 orders sit between 2026-09-06 and 2027-08-20, 15 of them still in the future at the time of writing (2026-11-26). | 24 orders, GHS 68,040. **All 24** have whole-minute timestamps, against 1.68% of normal orders. | D10: date range and seconds-component comparison | The trailing-12-month window is anchored on the wrong "latest month", and future months show revenue that has not happened. |
| 11 | Low | **Contact data in mixed formats.** Emails with surrounding spaces; phones in four formats (`+233…`, `233…`, `0…`, spaced); city spelled `Accra`, `accra`, `ACCRA`, `Accra `. | 1,314 padded emails (all fail a basic email pattern as stored); ~8,000 phones per format; 15 city spellings for 12 cities. | D11 | Emails and SMS bounce; "orders by city" splits Accra four ways. No effect on Nana's four asks. |
| 12 | Low | **Name capitalisation** (`YAA MENSAH`, `kwesi danso`, padded). | About 5,100 customers. | Profiling | Cosmetic only. Not worth changing data the business did not ask about. |

### Structural problems underneath all of the above

| Problem | Evidence | Why it matters |
|---|---|---|
| No foreign keys anywhere | Schema check: 0 | Findings 4 and 6 were allowed to exist. |
| No CHECK constraints | Schema check: 0 | Findings 1, 2 and 5 were allowed to exist. |
| No index besides the primary keys | Schema check: 0 | Every join in the Monday report scans whole tables. A correlated lookup during this diagnosis ran for over 5 minutes until it was rewritten as a set-based join. |
| No ID generators (no sequences or identity columns) | Schema check: 0 sequences | Two simultaneous orders cannot safely pick the next `order_id` on their own; this is a second race beside the stock race. |
| Stock is decremented at fulfilment, not at checkout | D3b: no sale movement for any pending, cancelled or refunded order | Between "customer pays" and "order ships", the unit is still on the shelf as far as the database knows. This is the window the overselling happens in. |

## Patterns that look wrong but are not

These were investigated and deliberately **left alone**. Changing them would damage correct data.

| # | Pattern | Why it is correct | Evidence |
|---|---|---|---|
| N1 | Order-line `unit_price` is below the product's current `price` (3,964 lines) | A line records the price at the moment of sale; prices change. Rewriting it would falsify historical revenue. | N1: 332k lines at about today's price; 3,964 below it, spread over time (promotions). |
| N2 | 400 product names appear more than once | They are separate variants: each has its own ID, price and stock, in the same category. Merging them would merge stock that is physically different. | N2: e.g. `LG Haircare XL` ×4, priced 75.31 to 325.75. |
| N3 | `order_date` is a `timestamp` with no time zone | Accra is UTC+0 with no daylight saving, so local time *is* UTC. Order volume peaks at 13:00 and bottoms out at 00:00, which is a local-time curve. | N3: hour-of-day histogram. |
| N4 | About 1,700 orders whose total is exactly 50%, 75%, 90%, 110% or 125% of their lines | Fixed percentages are checkout adjustments (discount codes, fees): `total_amount` is what the customer was actually charged. | D8: ratios cluster at 0.75 (415), 0.90 (401), 1.10 (399), 1.25 (391), 0.50 (114). |
| N5 | Pending, cancelled and refunded orders have no sale movement in `inventory_log` | Stock moves when an order is fulfilled; an order that never shipped should not move stock. Of fulfilled orders, 99.9% have their movement. | D3b: 0 of 73,641 pending/cancelled/refunded product-moments logged, 261,474 of 261,611 fulfilled ones logged. |

## What happens to each finding next

The treatment is decided and justified in `docs/02_design_decisions.md`
(Milestone 2 onwards). In short: problems that break Nana's four asks (1–5)
are fixed in the schema and data. Questionable rows (5–8, 10) are moved to a
quarantine table with the reason recorded, never silently deleted, so an
auditor can still see them. Contact-data issues (11–12) are normalised only
where a report depends on them.
