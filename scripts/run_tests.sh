#!/usr/bin/env bash
# Runs every test against the current database: the SQL test files (each in a
# rolled-back transaction) and then the unmodified race_test.py.
#
# Usage (from the repo root, after ./scripts/rebuild.sh):
#     ./scripts/run_tests.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
set -a; source .env; set +a

for test_file in tests/*_test.sql; do
    echo "== ${test_file}"
    # A bad query plan must fail the test, not hang it: one once ran for 8 hours.
    docker compose exec -T -e PGOPTIONS='-c statement_timeout=120s' db \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f "/workspace/${test_file}" 2>&1 \
        | sed 's/^psql:[^ ]* NOTICE:  //'
done

echo "== race_test.py (unmodified)"
docker compose run --rm -T racetest
