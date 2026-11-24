#!/usr/bin/env bash
# Rebuild the isolated test database, load SYNTHETIC fixtures (11) and run the
# validation tests (12). Never touches the main database.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
set -a; source .env; set +a
export PGPASSWORD="$EQUITYIQ_DB_PASSWORD"
export PGOPTIONS="-c client_min_messages=warning"
scripts/db_init.sh --test --reset
PSQL=(psql -X -v ON_ERROR_STOP=1 -h "$EQUITYIQ_DB_HOST" -p "$EQUITYIQ_DB_PORT" -U "$EQUITYIQ_DB_USER" -d "$EQUITYIQ_TEST_DB_NAME")
"${PSQL[@]}" -q -f database/11_quality_test_data.sql
"${PSQL[@]}" -f database/12_validation_tests.sql

# Export the SYNTHETIC test results so the API/dashboard can show them without the main
# database ever containing synthetic data.
mkdir -p data/quality-tests
"${PSQL[@]}" -q -At -c "
SELECT jsonb_pretty(jsonb_build_object(
  'dataset', 'SYNTHETIC',
  'generated_at', now(),
  'command', 'scripts/run_quality_tests.sh',
  'totals', (SELECT jsonb_build_object('tests', count(*), 'passed', count(*) FILTER (WHERE passed),
                                       'failed', count(*) FILTER (WHERE NOT passed)) FROM qa.test_results),
  'sections', (SELECT jsonb_agg(s ORDER BY s->>'section') FROM (
                 SELECT jsonb_build_object('section', section, 'tests', count(*),
                                           'passed', count(*) FILTER (WHERE passed)) AS s
                   FROM qa.test_results GROUP BY section) x),
  'tests', (SELECT jsonb_agg(jsonb_build_object('no', test_no, 'section', section, 'test', test_name,
                                                'expected', expected, 'actual', actual, 'passed', passed)
                             ORDER BY test_no) FROM qa.test_results),
  'fixtures', (SELECT jsonb_agg(jsonb_build_object('fixture_id', fixture_id, 'dataset', dataset, 'ticker', ticker,
                                                   'record_key', record_key, 'expected_rules', expected_rules,
                                                   'expected_outcome', expected_outcome, 'description', description)
                                ORDER BY fixture_id) FROM qa.fixture_expectations),
  'batches', (SELECT jsonb_agg(to_jsonb(m) - 'source' ORDER BY m.ingestion_batch_id)
                FROM analytics.v_dq_batch_metrics m WHERE m.source = 'synthetic_fixture')))" \
  > data/quality-tests/latest_results.json
echo "Synthetic results exported to data/quality-tests/latest_results.json"
