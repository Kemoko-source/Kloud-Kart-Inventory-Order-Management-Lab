#!/usr/bin/env python3
"""
order_latency.py: how long one place_order() call takes on a warm connection,
which is what an application with a connection pool sees. (race_test.py opens
a new connection per buyer, so its timings include connection start-up.)

Times N successful orders, then N refusals ("out of stock") on a fixture
product, one connection, autocommit, from just before execute() to just after
fetchone(). Prints one line per scenario: label, then each call's milliseconds.
Removes its fixtures afterwards.

Usage (inside the racetest container, which has psycopg2):
    docker compose run --rm --entrypoint python racetest /benchmarks/order_latency.py
"""

from __future__ import annotations

import os
import sys
import time

import psycopg2

FIXTURE_NAME = "LATENCY FIXTURE"
CALLS = 300
PLACE_ORDER = "SELECT success FROM place_order(%s, %s, 1)"


def timed_calls(cur, customer_id: int, product_id: int, expect_success: bool) -> list[float]:
    timings = []
    for _ in range(CALLS):
        t0 = time.perf_counter()
        cur.execute(PLACE_ORDER, (customer_id, product_id))
        success = cur.fetchone()[0]
        timings.append((time.perf_counter() - t0) * 1000)
        if success is not expect_success:
            sys.exit(f"unexpected result: success={success}, expected {expect_success}")
    return timings


def cleanup(cur) -> None:
    cur.execute("SELECT product_id FROM products WHERE product_name = %s", (FIXTURE_NAME,))
    pids = [r[0] for r in cur.fetchall()]
    if not pids:
        return
    cur.execute("SELECT DISTINCT order_id FROM order_items WHERE product_id = ANY(%s)", (pids,))
    oids = [r[0] for r in cur.fetchall()]
    cur.execute("BEGIN")
    cur.execute("DELETE FROM inventory_log WHERE product_id = ANY(%s)", (pids,))
    cur.execute("DELETE FROM order_items WHERE order_id = ANY(%s)", (oids,))
    cur.execute("DELETE FROM orders WHERE order_id = ANY(%s)", (oids,))
    cur.execute("DELETE FROM products WHERE product_id = ANY(%s)", (pids,))
    cur.execute("COMMIT")


def main() -> int:
    conn = psycopg2.connect(os.environ["DATABASE_URL"])
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cleanup(cur)
        cur.execute("SELECT min(customer_id) FROM customers")
        customer_id = cur.fetchone()[0]
        # One unit more than the timed calls: the first, untimed call warms the
        # connection (function compilation, catalogue caches).
        cur.execute(
            "INSERT INTO products (product_name, price, stock_quantity) VALUES (%s, 10, %s) RETURNING product_id",
            (FIXTURE_NAME, CALLS + 1),
        )
        product_id = cur.fetchone()[0]
        cur.execute(PLACE_ORDER, (customer_id, product_id))

        sold = timed_calls(cur, customer_id, product_id, expect_success=True)
        refused = timed_calls(cur, customer_id, product_id, expect_success=False)  # stock is now 0
        print("warm_success", *(f"{ms:.3f}" for ms in sold))
        print("warm_refusal", *(f"{ms:.3f}" for ms in refused))
    finally:
        cleanup(cur)
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
