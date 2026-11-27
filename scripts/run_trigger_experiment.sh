#!/usr/bin/env bash
# Runs the unmodified race_test.py against the "triggers only" design
# (experiments/trigger_only.sql), in both variants, each in a throwaway copy
# of the database. Results are written to evidence/.
#
# Usage (from the repo root, after ./scripts/rebuild.sh):
#     ./scripts/run_trigger_experiment.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
set -a; source .env; set +a

experiment_db="${POSTGRES_DB}_trigger_experiment"
evidence_dir="evidence"
mkdir -p "$evidence_dir"

psql_admin() {
    # Connect to the maintenance database: a database cannot be used as a
    # template while anyone is connected to it.
    docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

drop_experiment_db() {
    psql_admin -c "DROP DATABASE IF EXISTS ${experiment_db} WITH (FORCE)"
}
trap drop_experiment_db EXIT

for variant in no_check with_check; do
    echo "== Variant: ${variant}"
    drop_experiment_db
    psql_admin -c "CREATE DATABASE ${experiment_db} TEMPLATE ${POSTGRES_DB}"

    docker compose exec -T -w /workspace db \
        psql -U "$POSTGRES_USER" -d "$experiment_db" -v ON_ERROR_STOP=1 -q \
             -v variant="$variant" -f experiments/trigger_only.sql

    out="${evidence_dir}/trigger_only_${variant}.txt"
    # race_test exits 1 when it finds problems, which is the expected outcome here.
    docker compose run --rm -T \
        -e DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${experiment_db}" \
        racetest --test 1 --test 2 > "$out" 2>&1 || true
    grep -E "^(PASSED|FAILED)|FAIL|ok " "$out" | head -12
done
