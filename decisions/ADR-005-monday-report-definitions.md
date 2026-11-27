# ADR-005: Count completed and shipped orders as "spent", over the 12 complete months before the report date

- **Status:** Accepted
- **Date:** 2026-11-27
- **Decision owner:** Kemoko Foumba Traore

## Context

Adwoa's report needs, for every customer: total spent, order count, monthly
spend for the trailing 12 months, a running total and a top-100 ranking. The
brief does not define "spent", the 12-month window, the running total, how ties
rank, or what a customer is when one person has several accounts (F-10).

## Decision

- **Spent** is the total of `completed` and `shipped` orders.
- **The window** is the 12 complete calendar months before the month of the
  report date, which is a parameter defaulting to today. Run on Monday 7
  September 2026, it covers September 2025 to August 2026.
- **The running total** is each customer's cumulative spend at the end of each
  month, including everything before the window.
- **Ties** share a rank (`RANK()`).
- **A customer** is an account; people with several accounts are flagged
  (`accounts_sharing_email`), not merged.

## Alternatives considered

### Alternative A: Count pending orders as spent

- **How it would work:** Spent = completed + shipped + pending.
- **Why it is attractive:** Pending orders might be paid.
- **Why rejected:** Pending orders average 110 days old, the same as completed
  ones (F-11): they are stuck, not about to ship.

### Alternative B: Include the current, partial month

- **How it would work:** The 12th column is month-to-date.
- **Why it is attractive:** The freshest number.
- **Why rejected:** Every Monday the latest month would look like a collapse
  against complete months.

### Alternative C: Merge shared-email accounts in the report

- **How it would work:** Group by normalised email instead of account.
- **Why it is attractive:** Ranks people, not accounts.
- **Why rejected:** The accounts carry different phone numbers; merging on
  assumption could combine two real people's spend.

## Consequences

- **What this buys:** One written definition, used by both the summary and the
  monthly detail, and tested at every boundary (`tests/monday_report_test.sql`).
- **What this costs:** A person with two accounts can rank lower than they should.
- **What it costs the client if I am wrong:** If pending orders were in fact paid,
  every customer's spend is understated by about 10% (GHS 48M). The definition
  is one word in the function.
- **What would make me revisit this:** Payment data showing pending orders are paid.

## What this survives

The report's ranking is only as trustworthy as the price list: all of the top
100 bought at least one of the 116 suspect-priced products (F-03). The
definitions do not fix that, and the memo says so.
