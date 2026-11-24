#!/usr/bin/env bash
# Read-only reconciliation report for the loaded snapshot (main database).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a; source .env; set +a
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
psql -X -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" \
     -U "$EQUITYIQ_DB_USER" -d "$EQUITYIQ_DB_NAME" -f database/tests/phase2_ingestion_checks.sql
