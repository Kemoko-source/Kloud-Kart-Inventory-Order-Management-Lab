#!/usr/bin/env bash
# Before/after timing of the Monday report, written to
# docs/evidence/report_benchmark.txt.
#
#   before  the extract exactly as delivered (fresh load, no indexes, messy
#           statuses) with the report written as per-customer sub-queries
#   after   the cleaned, indexed database with monday_customer_report()
#
# The naive version takes hours on the raw extract, so it is timed on a
# sample of customers and extrapolated linearly (each customer costs the same:
# 26 full scans of orders). Everything else runs in full.
#
# Usage (from the repo root, after ./scripts/rebuild.sh):
#     ./scripts/run_report_benchmark.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
set -a; source .env; set +a

raw_db="${POSTGRES_DB}_raw"
raw_sample=20
out="docs/evidence/report_benchmark.txt"
mkdir -p "$(dirname "$out")"

psql_db() {
    local db="$1"; shift
    docker compose exec -T -w /workspace db psql -U "$POSTGRES_USER" -d "$db" -v ON_ERROR_STOP=1 "$@"
}

# Milliseconds of each statement run from stdin, one per line.
time_statements() {
    local db="$1"; shift
    { echo '\timing on'; cat; } | psql_db "$db" -q "$@" | grep -oE 'Time: [0-9.]+' | awk '{print $2}'
}

drop_raw_db() { psql_db postgres -qc "DROP DATABASE IF EXISTS ${raw_db} WITH (FORCE)"; }
trap drop_raw_db EXIT

customers=$(psql_db "$POSTGRES_DB" -Atc "SELECT count(*) FROM customers")

{
echo "Monday report benchmark, $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "PostgreSQL $(psql_db "$POSTGRES_DB" -Atc 'SHOW server_version'), report as of 2026-09-07, ${customers} customers"
echo "Docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM')"
echo

echo "== Loading the raw extract into ${raw_db}"
drop_raw_db
psql_db postgres -qc "CREATE DATABASE ${raw_db}"
docker compose exec -T -w /workspace/M03_Resources -e PGOPTIONS='-c client_min_messages=warning' db \
    psql -U "$POSTGRES_USER" -d "$raw_db" -q -v ON_ERROR_STOP=1 -f schema.sql -f load.sql > /dev/null

echo
echo "== BEFORE: raw extract, naive per-customer sub-queries (${raw_sample}-customer sample)"
ms=$(echo '\i benchmarks/report_naive.sql' | time_statements "$raw_db" -v sample_customers="$raw_sample" -o /dev/null)
awk -v ms="$ms" -v n="$raw_sample" -v total="$customers" 'BEGIN {
    per = ms / n
    printf "   %.0f ms for %d customers = %.0f ms per customer\n", ms, n, per
    printf "   extrapolated to %d customers: %.0f s (%.1f hours)\n", total, per * total / 1000, per * total / 3600000 }'

echo
echo "== Rewrite only: raw extract, set-based query, no indexes (3 runs, all customers)"
printf '\\i benchmarks/report_set_based_raw.sql\n%.0s' 1 2 3 \
    | time_statements "$raw_db" -o /dev/null | awk '{printf "   %.0f ms\n", $1}'

echo
echo "== Indexes only: cleaned and indexed database, naive sub-queries (all customers)"
echo '\i benchmarks/report_naive.sql' \
    | time_statements "$POSTGRES_DB" -v sample_customers="$customers" -o /dev/null | awk '{printf "   %.0f ms\n", $1}'

echo
echo "== AFTER: cleaned and indexed database, monday_customer_report() (3 runs, all customers, all columns)"
printf "SELECT * FROM monday_customer_report('2026-09-07');\n%.0s" 1 2 3 \
    | time_statements "$POSTGRES_DB" -o /dev/null | awk '{printf "   %.0f ms\n", $1}'
} | tee "$out"
