#!/usr/bin/env bash
# Rebuild the test DB, load SYNTHETIC fixtures, run the pipeline, then run the
# Phase 4 analytics tests (rolled back). Never touches the main database.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a; source .env; set +a
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
export PGOPTIONS="-c client_min_messages=warning"
scripts/db_init.sh --test --reset > /dev/null
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" -U "$EQUITYIQ_DB_USER" -d "$EQUITYIQ_TEST_DB_NAME")
"${PSQL[@]}" -f database/11_quality_test_data.sql > /dev/null
"${PSQL[@]}" -c "CALL audit.process_pending_batches();"
"${PSQL[@]}" -f database/tests/phase4_analytics_tests.sql
