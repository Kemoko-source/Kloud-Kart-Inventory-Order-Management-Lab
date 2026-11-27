# ADR-001: Move bad rows to a quarantine table and log every correction, instead of deleting or flagging

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Kemoko Foumba Traore

## Context

The clean-up has to remove 2,092 rows (orphans, duplicates, impossible dates)
and change values in about 152,000 more (statuses, quantities, stock, contact
data). Nana asked for "a trail an auditor could walk through after the fact",
and several of the calls are judgements that could turn out to be wrong.

## Decision

I move every removed row into `data_quarantine` with its full original content
and a reason code, and I write every changed value to `data_corrections` with
its old value, new value and reason. Bulk format changes are logged as one entry
per mapping (for example `COMPLETED` → `completed`, 22,392 rows).

## Alternatives considered

### Alternative A: Delete the bad rows

- **How it would work:** `DELETE` the orphans, duplicates and impossible dates.
- **Why it is attractive:** Simplest; the tables end up clean with no extra objects.
- **Why rejected:** It destroys the evidence Nana asked to keep, and no wrong
  call could ever be reversed.

### Alternative B: Flag rows in place (`is_valid` column)

- **How it would work:** Keep every row and mark the bad ones.
- **Why it is attractive:** Nothing moves; reversal is flipping a flag.
- **Why rejected:** Every report, today's and future ones, must remember to
  filter on the flag. One forgotten `WHERE` re-introduces GHS 1.49M of sales that
  belong to no real customer or order (F-07).

### Alternative C: Log every changed row individually

- **How it would work:** One correction entry per row, including the 116,394
  status spellings.
- **Why it is attractive:** Complete row-level history.
- **Why rejected:** 116k entries saying `COMPLETED` became `completed` bury the
  178 corrections an auditor actually needs to read.

## Consequences

- **What this buys:** Clean operational tables that need no special filtering,
  and the raw extract is reconstructable from the cleaned tables plus the two
  audit tables.
- **What this costs:** Two extra tables; the quarantine holds JSON copies of the
  rows, not typed columns.
- **What it costs the client if I am wrong:** Little: any quarantined row can be
  restored from its `row_data`, and any correction reversed from its old value.
- **What would make me revisit this:** A data-protection request that requires
  quarantined personal data to be erased, not kept.

## What this survives

Re-running the whole clean-up from a fresh load (it is one transaction ending
in invariant checks), and an auditor asking "what happened to order X" for any
order in the extract.
