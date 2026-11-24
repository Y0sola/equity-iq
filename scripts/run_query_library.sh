#!/usr/bin/env bash
# Run every SQL Query Library file (queries/*.sql) against the main database in
# READ-ONLY mode, printing results and timing. Proves each library query is
# read-only and executes successfully.
#   scripts/run_query_library.sh            # all queries
#   scripts/run_query_library.sh volatility # files whose name contains "volatility"
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a; source .env; set +a
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
export PGOPTIONS="-c default_transaction_read_only=on"   # any write would fail
for f in queries/*${1:-}*.sql; do
  echo "=================================================================="
  grep -m1 '^-- title:' "$f" | sed 's/^-- title: /QUERY: /'
  echo "FILE:  $f"
  psql -X -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" -U "$EQUITYIQ_DB_USER" \
       -d "$EQUITYIQ_DB_NAME" -c '\timing on' -f "$f"
done
