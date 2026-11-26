#!/usr/bin/env bash
# Rebuild Kloud Kart's database from a fresh load, then apply every solution
# script in order. Safe to re-run: schema.sql drops and recreates the tables.
#
# Usage (from the repo root, with the db container running):
#     ./scripts/rebuild.sh
set -euo pipefail
# Git Bash on Windows rewrites container paths like /workspace into Windows
# paths before docker sees them; this turns that off (no effect elsewhere).
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
set -a; source .env; set +a

psql_in_db() {
    # -w /workspace/... so relative paths inside the SQL files resolve.
    local workdir="$1"; shift
    docker compose exec -T -w "$workdir" db \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"
}

max_conn=$(psql_in_db /workspace -Atc "SHOW max_connections")
if [ "$max_conn" -lt 500 ]; then
    echo "max_connections is $max_conn; race_test.py needs 500. Recreate the db container." >&2
    exit 1
fi

echo "== Fresh load (provided bundle, unmodified)"
psql_in_db /workspace/M03_Resources -q -f schema.sql
psql_in_db /workspace/M03_Resources -f load.sql

echo "== Solution scripts"
for f in sql/[0-9]*.sql; do
    [ -e "$f" ] || continue
    echo "-- $f"
    psql_in_db /workspace -f "$f"
done

echo "== Done"
