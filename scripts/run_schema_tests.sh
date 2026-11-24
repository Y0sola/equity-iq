#!/usr/bin/env bash
# Run the Phase 1 schema tests against the isolated test database.
# The test DB is rebuilt first so the tests start from a known, empty state
# (other suites, e.g. run_quality_tests.sh, leave synthetic data behind).
# The tests themselves run in a transaction that is rolled back.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a; source .env; set +a
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
scripts/db_init.sh --test --reset > /dev/null
psql -X -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" \
     -U "$EQUITYIQ_DB_USER" -d "$EQUITYIQ_TEST_DB_NAME" \
     -f database/tests/phase1_schema_tests.sql
