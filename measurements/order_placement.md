# Order placement report

## Target

From the brief: two customers racing for the last unit, **exactly one gets it,
the other gets an instant, clear "out of stock", every time**, built for flash
sales of **about 400 orders in ten seconds on one product**. The provided
`race_test.py` must pass unmodified.

Read as numbers:

- **Correctness:** `race_test.py` passes on every run; no oversold unit, no error.
- **Flash sale:** 400 simultaneous attempts are all answered within 10 seconds.
- **"Instant":** a refusal takes under 100 ms on an application's (warm)
  connection, well below what a person can notice. This threshold is my
  interpretation; the brief gives none.

## Method

- **Hardware / container spec:** Docker Desktop on Windows 11, Linux VM with 8
  CPUs and 16 GB RAM; PostgreSQL 18.7 with `max_connections = 500` and every
  other setting at its default.
- **What was timed, from which event to which event:** in the client, from just
  before the call is sent to just after its result arrives.
  - *Warm:* one connection, one call at a time, on a fixture product
    (`benchmarks/order_latency.py`). 300 calls that sell, then 300 that are
    refused once the stock is gone.
  - *Flash sale:* `race_test.py --test 2 --verbose`, unmodified. 400 buyers each
    open a new connection, wait at a barrier, and call together; each call is
    timed from the barrier's release.
- **Runs, warm or cold, and which figure is reported:** 300 + 300 warm calls
  after one untimed warm-up call; 5 flash sales (2,000 attempts); the full
  `race_test.py` suite 10 times in a row. Median, 95th percentile (nearest rank)
  and worst over all calls.
- **How to reproduce:** `./scripts/rebuild.sh && ./scripts/run_measurements.sh`.
  Raw output: [`evidence/measurements.txt`](../evidence/measurements.txt).

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| `race_test.py`, full suite (last unit ×25, flash sale, oversell attempt, trail) | 10 | | | | **Yes**: passed 10 of 10 |
| Flash sale: outcome | 5 × 400 | | | | **Yes**: exactly 50 sold each time (250 in total), 1,750 refused, 0 errors |
| Warm connection: order that sells | 300 calls | 2.4 ms | 3.0 ms | 7.4 ms | Yes |
| Warm connection: order refused, out of stock | 300 calls | 0.1 ms | 0.2 ms | 0.3 ms | **Yes**: under 100 ms by a factor of 300 |
| Flash sale, new connections: buyers who got a unit | 250 calls | 394 ms | 707 ms | 910 ms | Yes: within 10 s |
| Flash sale, new connections: buyers told out of stock | 1,750 calls | 1,105 ms | 1,592 ms | 1,805 ms | Within 10 s. **Not "instant"** under this harness; see caveats |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Flash sale, 400 buyers for 50 units, "triggers only" design (`experiments/trigger_only.sql`) | 400 sold, stock ends at −350 | 50 sold, stock ends at 0 | Overselling eliminated |
| Same, triggers plus a `stock >= 0` rule | 350 buyers get a database error | 350 buyers told "out of stock", 0 errors | Clean refusal instead of a crash |
| Last unit, 25 races, both trigger designs | 25 of 25 rounds failed | 25 of 25 correct, in 10 of 10 suite runs | — |
| Flash-sale refusal, median, before and after the lock-free stock pre-check (3 runs each, measured during development) | about 1.9 s | about 1.5 s | Late buyers no longer queue behind the winners |

The trigger results are in [`evidence/trigger_only_no_check.txt`](../evidence/trigger_only_no_check.txt)
and [`evidence/trigger_only_with_check.txt`](../evidence/trigger_only_with_check.txt),
reproduced by `./scripts/run_trigger_experiment.sh`. The pre-check figures came
from three runs each during development and are not in an evidence file; the
current figure (1,105 ms over 1,750 calls) is.

## Caveats

- **The flash-sale timings measure the test harness more than the design.**
  `race_test.py` opens 400 brand-new connections at the same instant; each starts
  a server process that must load its caches on its first call, and 400 of them
  compete for 8 CPUs. The same refusal on an already-open connection takes
  0.1 ms. An application that keeps a pool of open connections, which is
  normal practice, sees the warm figures.
- **Capacity on one product:** at about 2.4 ms per sale, one product can take
  roughly 400 sales a second; the flash sale needs 40.
- **Warm figures come from one client with no contention.** Under contention a
  sale also waits its turn for the product's lock, about 2.4 ms per buyer ahead.
- **This is a laptop VM, not Kloud Kart's server.** Absolute times will differ.
  The correctness results do not depend on hardware.
