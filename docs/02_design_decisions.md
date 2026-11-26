# Kloud Kart — Design Decisions

Each decision states what was chosen, what was rejected and why, and **what it
costs Nana if the decision turns out to be wrong**. Where the brief left
something open, the assumption is marked **Assumption**.

Sections are added milestone by milestone:

1. [Cleaning and hardening](#1-cleaning-and-hardening) (`sql/10`–`30`)
2. Overselling: *to follow*
3. Low-stock rollup: *to follow*
4. Monday report: *to follow*

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
