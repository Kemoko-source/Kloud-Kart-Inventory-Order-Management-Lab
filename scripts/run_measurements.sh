#!/usr/bin/env bash
# Repeated, timed runs behind the reports in measurements/. Writes raw timings
# and median / p95 / worst per scenario to evidence/measurements.txt.
#
#   order placement  warm single calls (benchmarks/order_latency.py), the
#                    provided race_test.py flash sale with per-call timings,
#                    and the full race_test.py suite for correctness
#   low-stock rollup today's data, and a synthetic tree 50x today's size
#   Monday report    today's data, and about 10x today's order volume
#
# SQL timings are psql's \timing (client round trip, result discarded). The
# first run of each SQL scenario uses a fresh session and is reported apart
# from the warm runs that follow.
#
# Usage (from the repo root, after ./scripts/rebuild.sh; takes ~10 minutes):
#     ./scripts/run_measurements.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
source scripts/lib.sh
load_env

out="evidence/measurements.txt"
warm_runs=10
race_suite_runs=10
flash_sale_runs=5
scale_runs=3

# median / p95 / worst of the milliseconds read from stdin (nearest-rank p95).
summarise() {
    sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "   no samples"; exit 1 }
        p95 = int(0.95 * NR + 0.999); if (p95 > NR) p95 = NR
        printf "   runs %d   median %.1f ms   p95 %.1f ms   worst %.1f ms\n",
               NR, (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2), v[p95], v[NR] }'
}

# Times one statement: a cold run in a fresh session, then warm runs in another.
time_sql() {
    local statement="$1"
    local cold warm
    cold=$({ echo '\timing on'; echo "${statement} \\g /dev/null"; } \
        | docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q \
        | grep -oE 'Time: [0-9.]+' | awk '{print $2}')
    warm=$({ echo '\timing on'; echo "${statement} \\g /dev/null";
             for _ in $(seq "$warm_runs"); do echo "${statement} \\g /dev/null"; done; } \
        | docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q \
        | grep -oE 'Time: [0-9.]+' | awk 'NR > 1 {print $2}')
    printf '   first run in a fresh session: %.1f ms\n' "$cold"
    echo "   warm: $(echo "$warm" | paste -sd ' ')"
    echo "$warm" | summarise
}

# Runs a benchmark file N times and keeps the timings of the given positions.
time_benchmark_file() {
    local file="$1" positions="$2"
    for _ in $(seq "$scale_runs"); do
        docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "/workspace/${file}" 2>/dev/null \
            | grep -oE '^Time: [0-9.]+' | awk '{print $2}' | sed -n "${positions}"
    done
}

{
echo "Measurements, $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "PostgreSQL $(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SHOW server_version')," \
     "max_connections $(docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SHOW max_connections')," \
     "server settings otherwise default"
echo "Docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM'), Docker Desktop on Windows 11"
echo

echo "== ORDER PLACEMENT"
latency=$(docker compose run --rm -T --entrypoint python racetest /benchmarks/order_latency.py 2>/dev/null)
echo "-- warm connection, one call at a time, place_order() that sells (300 calls)"
echo "$latency" | awk '/^warm_success/ { for (i = 2; i <= NF; i++) print $i }' | summarise
echo "-- warm connection, one call at a time, place_order() that refuses (300 calls)"
echo "$latency" | awk '/^warm_refusal/ { for (i = 2; i <= NF; i++) print $i }' | summarise

flash=""
for _ in $(seq "$flash_sale_runs"); do
    flash+=$(docker compose run --rm -T racetest --test 2 --verbose 2>/dev/null | grep 'success=')$'\n'
done
echo "-- race_test.py flash sale, 400 new connections at once, ${flash_sale_runs} runs: buyers who got a unit"
echo "$flash" | grep 'success=True'  | grep -oE '[0-9.]+ms' | tr -d 'ms' | summarise
echo "-- same runs: buyers told out of stock"
echo "$flash" | grep 'success=False' | grep -oE '[0-9.]+ms' | tr -d 'ms' | summarise
echo "-- same runs: totals"
echo "   $(echo "$flash" | grep -c 'success=True') sold, $(echo "$flash" | grep -c 'success=False') refused," \
     "$(echo "$flash" | grep -c "err='[^']" || true) errors across ${flash_sale_runs} runs"

passed=0
for _ in $(seq "$race_suite_runs"); do
    if docker compose run --rm -T racetest 2>/dev/null | grep -q '^PASSED'; then passed=$((passed + 1)); fi
done
echo "-- race_test.py full suite: passed ${passed} of ${race_suite_runs} consecutive runs"
echo

echo "== LOW-STOCK ROLLUP"
echo "-- today's data: full rollup, every category"
time_sql "SELECT * FROM low_stock_by_category"
echo "-- today's data: drill-down, 50 most urgent products"
time_sql "SELECT * FROM low_stock_products ORDER BY units_below_reorder_level DESC LIMIT 50"
echo "-- 50x today's size (5,095 categories, 11 levels, 204,023 products): full rollup, ${scale_runs} runs"
time_benchmark_file benchmarks/low_stock_at_scale.sql 1p | summarise
echo

echo "== MONDAY REPORT"
echo "-- today's data: every customer, every column"
time_sql "SELECT * FROM monday_customer_report('2026-09-07')"
echo "-- today's data: top 100 only"
time_sql "SELECT * FROM monday_customer_report('2026-09-07') WHERE spend_rank <= 100"
echo "-- ~10x today's volume (1.6M orders, 100,420 customers): every customer, ${scale_runs} runs x 2"
time_benchmark_file benchmarks/report_at_scale.sql 1,2p | summarise
} | tee "$out"
