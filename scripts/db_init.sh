#!/usr/bin/env bash
# =============================================================================
# db_init.sh — create the EquityIQ role/database and apply the SQL scripts.
#
# Usage:
#   scripts/db_init.sh            # initialise the main database (equityiq)
#   scripts/db_init.sh --test     # initialise the isolated test database (equityiq_test)
#   scripts/db_init.sh --reset    # DROP all EquityIQ schemas first, then rebuild
#
# Safe to re-run: every SQL file is idempotent. Reads settings from .env.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in the values." >&2
  exit 1
fi
set -a; source .env; set +a

TARGET="main"; RESET="false"
for arg in "$@"; do
  case "$arg" in
    --test)  TARGET="test" ;;
    --reset) RESET="true" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

DB_NAME="$EQUITYIQ_DB_NAME"
[[ "$TARGET" == "test" ]] && DB_NAME="$EQUITYIQ_TEST_DB_NAME"

ADMIN_PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" -U "$PG_ADMIN_USER" -d postgres)
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
export PGOPTIONS="-c client_min_messages=warning"   # hide "already exists, skipping" notices on re-runs
APP_PSQL=(psql -X -q -v ON_ERROR_STOP=1 -v reader="$EQUITYIQ_READER_USER" -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" -U "$EQUITYIQ_DB_USER" -d "$DB_NAME")

echo "==> Ensuring role '$EQUITYIQ_DB_USER' and database '$DB_NAME' exist"
"${ADMIN_PSQL[@]}" -v role="$EQUITYIQ_DB_USER" -v pw="$EQUITYIQ_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
SQL
"${ADMIN_PSQL[@]}" -v db="$DB_NAME" -v role="$EQUITYIQ_DB_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL

# Read-only analytical role used by the API. Defence in depth: SELECT-only grants
# (13_security_grants.sql) PLUS role defaults that make every session read-only and
# time-limited, so even a mistaken write or runaway query is refused by PostgreSQL.
echo "==> Ensuring read-only role '$EQUITYIQ_READER_USER' exists"
"${ADMIN_PSQL[@]}" -v role="$EQUITYIQ_READER_USER" -v pw="$EQUITYIQ_READER_PASSWORD" -v db="$DB_NAME" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT', :'role', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'role') \gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', '5s') \gexec
SELECT format('ALTER ROLE %I CONNECTION LIMIT 20', :'role') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'role') \gexec
SQL

if [[ "$RESET" == "true" ]]; then
  echo "==> RESET: dropping EquityIQ schemas in '$DB_NAME'"
  "${APP_PSQL[@]}" -f database/00_reset_schemas.sql
fi

# Apply numbered scripts 01_*.sql, 02_*.sql, ... in order (00_reset is excluded above).
for f in database/[0-9][0-9]_*.sql; do
  case "$(basename "$f")" in
    00_*) continue ;;              # destructive reset: only via --reset
    11_*|12_*) continue ;;         # synthetic fixtures/tests: only via scripts/run_quality_tests.sh
  esac
  echo "==> Applying $f"
  "${APP_PSQL[@]}" -f "$f"
done

echo "==> Done. Database '$DB_NAME' is initialised."
