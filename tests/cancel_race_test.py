#!/usr/bin/env python3
"""
cancel_race_test.py: cancel_order() under contention.

Companion to the provided race_test.py, in the same style. Three tests:

  1  Double cancel.      10 simultaneous cancellations of one order, 25 rounds:
                         exactly one succeeds and the stock comes back once.
  2  Cancel mid-sale.    Every winner of a flash sale cancels while 100 new
                         buyers race for the returned units: no errors, no
                         negative stock, counter = ledger, and stock equals
                         what the still-pending orders do not hold.
  3  No deadlock.        40 two-product orders, half with their lines in the
                         opposite product order, all cancelled at once.

Usage (inside the racetest container, which has psycopg2):
    docker compose run --rm --entrypoint python racetest /tests/cancel_race_test.py
"""

from __future__ import annotations

import os
import sys
import threading
from dataclasses import dataclass

import psycopg2

FIXTURE_PREFIX = "CANCEL RACE FIXTURE"
DSN = os.environ.get("DATABASE_URL")

DOUBLE_CANCEL_ROUNDS = 25
DOUBLE_CANCEL_CALLERS = 10
SALE_STOCK = 50
SALE_BUYERS = 100
DEADLOCK_ORDERS = 40

PLACE_ORDER = "SELECT success, order_id, message FROM place_order(%s, %s, 1)"
CANCEL_ORDER = "SELECT success, units_returned, message FROM cancel_order(%s)"

FAILURES: list[str] = []


@dataclass
class CallResult:
    row: tuple | None = None
    error: str = ""


def connect():
    return psycopg2.connect(DSN)


def fail(msg: str) -> None:
    print(f"  FAIL  {msg}")
    FAILURES.append(msg)


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


def fire(calls: list[tuple[str, tuple]]) -> list[CallResult]:
    """Run each (sql, params) call on its own connection, all released
    together by a barrier so they genuinely contend."""
    barrier = threading.Barrier(len(calls))
    results = [CallResult() for _ in calls]

    def call(sql: str, params: tuple, out: CallResult) -> None:
        conn = None
        try:
            conn = connect()
            conn.autocommit = True
            with conn.cursor() as cur:
                barrier.wait(timeout=60)
                cur.execute(sql, params)
                out.row = cur.fetchone()
        except Exception as exc:  # noqa: BLE001 - every error is a test finding
            out.error = f"{type(exc).__name__}: {exc}".strip()
        finally:
            if conn is not None:
                conn.close()

    threads = [threading.Thread(target=call, args=(sql, params, out), daemon=True)
               for (sql, params), out in zip(calls, results)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=120)
    return results


def query_one(sql: str, params: tuple = ()) -> tuple:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def make_product(label: str, stock: int) -> int:
    """A fixture product whose ledger starts level with its counter."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO products (product_name, price, stock_quantity) VALUES (%s, 10, %s)"
            " RETURNING product_id",
            (f"{FIXTURE_PREFIX} {label}", stock),
        )
        pid = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO inventory_log (product_id, change_qty, reason) VALUES (%s, %s, 'restock')",
            (pid, stock),
        )
        return pid


def stock_and_ledger(pid: int) -> tuple[int, int]:
    return query_one(
        "SELECT p.stock_quantity, coalesce(sum(l.change_qty), 0) FROM products p"
        " LEFT JOIN inventory_log l USING (product_id) WHERE p.product_id = %s"
        " GROUP BY p.stock_quantity",
        (pid,),
    )


def errors_in(results: list[CallResult]) -> list[str]:
    return [r.error for r in results if r.error]


def cleanup() -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT product_id FROM products WHERE product_name LIKE %s",
                    (FIXTURE_PREFIX + "%",))
        pids = [r[0] for r in cur.fetchall()]
        if pids:
            cur.execute("SELECT DISTINCT order_id FROM order_items WHERE product_id = ANY(%s)", (pids,))
            oids = [r[0] for r in cur.fetchall()]
            cur.execute("DELETE FROM inventory_log WHERE product_id = ANY(%s)", (pids,))
            cur.execute("DELETE FROM order_items WHERE order_id = ANY(%s)", (oids,))
            cur.execute("DELETE FROM orders WHERE order_id = ANY(%s)", (oids,))
            cur.execute("DELETE FROM products WHERE product_id = ANY(%s)", (pids,))


def test_double_cancel(customer_id: int) -> None:
    print(f"\nTest 1: {DOUBLE_CANCEL_CALLERS} simultaneous cancellations of one order, "
          f"{DOUBLE_CANCEL_ROUNDS} rounds")
    bad_rounds = 0
    for rnd in range(DOUBLE_CANCEL_ROUNDS):
        pid = make_product(f"T1 r{rnd}", 1)
        oid = query_one("SELECT order_id FROM place_order(%s, %s, 1)", (customer_id, pid))[0]
        results = fire([(CANCEL_ORDER, (oid,))] * DOUBLE_CANCEL_CALLERS)
        wins = [r for r in results if r.row and r.row[0]]
        stock, ledger = stock_and_ledger(pid)
        movements = query_one(
            "SELECT count(*) FROM inventory_log WHERE order_id = %s AND reason = 'cancellation'", (oid,))[0]
        problems = []
        if errors_in(results):
            problems.append("errors: " + "; ".join(errors_in(results))[:200])
        if len(wins) != 1:
            problems.append(f"{len(wins)} cancellations succeeded, expected 1")
        if stock != 1 or ledger != 1:
            problems.append(f"stock {stock}, ledger {ledger}, expected 1 and 1")
        if movements != 1:
            problems.append(f"{movements} cancellation movements, expected 1")
        if problems:
            bad_rounds += 1
            fail(f"round {rnd}: " + "; ".join(problems))
    if bad_rounds == 0:
        ok(f"{DOUBLE_CANCEL_ROUNDS}/{DOUBLE_CANCEL_ROUNDS} rounds: one success, stock returned once")


def test_cancel_during_sale(customer_id: int) -> None:
    print(f"\nTest 2: every winner cancels while {SALE_BUYERS} new buyers race for the units")
    pid = make_product("T2 sale", SALE_STOCK)
    first_wave = fire([(PLACE_ORDER, (customer_id, pid))] * SALE_BUYERS)
    winners = [r.row[1] for r in first_wave if r.row and r.row[0]]

    # Cancellations and new purchases released by the same barrier.
    calls = [(CANCEL_ORDER, (oid,)) for oid in winners] + [(PLACE_ORDER, (customer_id, pid))] * SALE_BUYERS
    results = fire(calls)

    errs = errors_in(first_wave) + errors_in(results)
    stock, ledger = stock_and_ledger(pid)
    pending = query_one(
        "SELECT coalesce(sum(i.quantity), 0) FROM orders o JOIN order_items i USING (order_id)"
        " WHERE i.product_id = %s AND o.status = 'pending'", (pid,))[0]
    cancelled = sum(1 for (sql, _), r in zip(calls, results) if sql == CANCEL_ORDER and r.row and r.row[0])
    rebought = sum(1 for (sql, _), r in zip(calls, results) if sql == PLACE_ORDER and r.row and r.row[0])
    print(f"        first wave sold {len(winners)}; then {cancelled} cancelled, {rebought} re-sold, "
          f"stock {stock}")

    if errs:
        fail(f"{len(errs)} calls raised, e.g. {errs[0][:150]}")
    if len(winners) != SALE_STOCK or cancelled != SALE_STOCK:
        fail(f"sold {len(winners)} and cancelled {cancelled}, expected {SALE_STOCK} each")
    if stock < 0:
        fail(f"stock went negative: {stock}")
    if stock != ledger:
        fail(f"stock counter {stock} != ledger {ledger}")
    if stock != SALE_STOCK - pending:
        fail(f"stock {stock} + units held by pending orders {pending} != {SALE_STOCK}")
    if not (errs or stock < 0 or stock != ledger or stock != SALE_STOCK - pending):
        ok(f"no errors, never negative, counter = ledger = {SALE_STOCK} - units still on order")


def test_no_deadlock(customer_id: int) -> None:
    print(f"\nTest 3: {DEADLOCK_ORDERS} two-product orders, lines in opposite orders, cancelled at once")
    pid_a = make_product("T3 A", DEADLOCK_ORDERS)
    pid_b = make_product("T3 B", DEADLOCK_ORDERS)
    order_ids = []
    with connect() as conn, conn.cursor() as cur:
        for n in range(DEADLOCK_ORDERS):
            first, second = (pid_a, pid_b) if n % 2 == 0 else (pid_b, pid_a)
            cur.execute("INSERT INTO orders (customer_id, total_amount) VALUES (%s, 20) RETURNING order_id",
                        (customer_id,))
            oid = cur.fetchone()[0]
            for pid in (first, second):
                cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price)"
                            " VALUES (%s, %s, 1, 10)", (oid, pid))
                cur.execute("UPDATE products SET stock_quantity = stock_quantity - 1 WHERE product_id = %s",
                            (pid,))
                cur.execute("INSERT INTO inventory_log (product_id, change_qty, reason, order_id)"
                            " VALUES (%s, -1, 'sale', %s)", (pid, oid))
            order_ids.append(oid)

    results = fire([(CANCEL_ORDER, (oid,)) for oid in order_ids])
    errs = errors_in(results)
    returned = sum(r.row[1] for r in results if r.row and r.row[0])
    stocks = [stock_and_ledger(pid) for pid in (pid_a, pid_b)]

    if errs:
        fail(f"{len(errs)} cancellations raised, e.g. {errs[0][:150]}")
    if returned != 2 * DEADLOCK_ORDERS:
        fail(f"{returned} units returned, expected {2 * DEADLOCK_ORDERS}")
    if any(s != (DEADLOCK_ORDERS, DEADLOCK_ORDERS) for s in stocks):
        fail(f"stock/ledger after cancelling everything: {stocks}, expected {DEADLOCK_ORDERS} each")
    if not errs and returned == 2 * DEADLOCK_ORDERS:
        ok(f"no deadlocks, all {2 * DEADLOCK_ORDERS} units returned, both products level")


def main() -> int:
    if not DSN:
        print("DATABASE_URL is not set.", file=sys.stderr)
        return 2
    print("cancel_race_test.py: cancel_order() under contention")
    print("=" * 66)
    customer_id = query_one("SELECT min(customer_id) FROM customers")[0]
    cleanup()
    try:
        test_double_cancel(customer_id)
        test_cancel_during_sale(customer_id)
        test_no_deadlock(customer_id)
    finally:
        cleanup()
    print("\n" + "=" * 66)
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} problem(s)")
        return 1
    print("PASSED: cancellations return stock exactly once, under contention.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
