-- =============================================================================
-- phase1_schema_tests.sql
-- Purpose : Prove the schema enforces what it claims: keys, uniqueness, check
--           constraints, foreign keys, lineage protection and triggers.
-- Run     : scripts/run_schema_tests.sh   (targets the equityiq_test database)
--
-- HOW IT WORKS
--   Everything runs inside one transaction that is ROLLED BACK at the end, so
--   the database is left exactly as it was. Two helper functions run a SQL
--   statement and record whether it behaved as expected:
--     expect_ok(name, sql)               – the statement must succeed
--     expect_error(name, sql, sqlstate)  – the statement must fail with this error code
--   PostgreSQL error codes used:
--     23505 unique_violation       23503 foreign_key_violation
--     23514 check_violation        23502 not_null_violation
-- =============================================================================

\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE test_results (
    test_no    serial PRIMARY KEY,
    test_name  text    NOT NULL,
    expected   text    NOT NULL,
    actual     text    NOT NULL,
    passed     boolean NOT NULL
) ON COMMIT DROP;

-- pg_temp functions exist only for this session.
CREATE FUNCTION pg_temp.expect_ok(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    INSERT INTO test_results (test_name, expected, actual, passed)
    VALUES (p_name, 'success', 'success', true);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results (test_name, expected, actual, passed)
    VALUES (p_name, 'success', SQLSTATE || ': ' || SQLERRM, false);
END;
$$;

CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_sqlstate text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    INSERT INTO test_results (test_name, expected, actual, passed)
    VALUES (p_name, 'error ' || p_sqlstate, 'success (no error raised)', false);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO test_results (test_name, expected, actual, passed)
    VALUES (p_name, 'error ' || p_sqlstate, SQLSTATE || ': ' || SQLERRM, SQLSTATE = p_sqlstate);
END;
$$;

CREATE FUNCTION pg_temp.expect_true(p_name text, p_condition boolean, p_detail text) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO test_results (test_name, expected, actual, passed)
    VALUES (p_name, 'true', coalesce(p_detail, 'null'), coalesce(p_condition, false));
$$;

-- Hide per-test output; results are printed at the end.
\o /dev/null
-- -----------------------------------------------------------------------------
-- A. Structure
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_true('A1 all 5 schemas exist',
    (SELECT count(*) FROM information_schema.schemata
      WHERE schema_name IN ('ref','staging','core','audit','analytics')) = 5,
    (SELECT string_agg(schema_name, ',' ORDER BY schema_name) FROM information_schema.schemata
      WHERE schema_name IN ('ref','staging','core','audit','analytics')));

SELECT pg_temp.expect_true('A2 all 13 tables exist',
    (SELECT count(*) FROM information_schema.tables
      WHERE table_type = 'BASE TABLE'
        AND (table_schema, table_name) IN (
            ('ref','security_universe'), ('ref','trading_calendar'), ('ref','sector_mapping'),
            ('staging','raw_company_reference'), ('staging','raw_stock_prices'), ('staging','raw_corporate_actions'),
            ('core','companies'), ('core','stock_prices'), ('core','corporate_actions'),
            ('audit','ingestion_logs'), ('audit','data_quality_rules'), ('audit','data_quality_issues'),
            ('audit','rule_failures'))) = 13,
    (SELECT count(*)::text || ' found' FROM information_schema.tables
      WHERE table_schema IN ('ref','staging','core','audit') AND table_type = 'BASE TABLE'));

SELECT pg_temp.expect_true('A3 prices use numeric, volume bigint, trade_date date',
    (SELECT bool_and(CASE column_name
                       WHEN 'volume'     THEN data_type = 'bigint'
                       WHEN 'trade_date' THEN data_type = 'date'
                       ELSE data_type = 'numeric' END)
       FROM information_schema.columns
      WHERE table_schema = 'core' AND table_name = 'stock_prices'
        AND column_name IN ('open_price','high_price','low_price','close_price','adjusted_close','volume','trade_date')),
    'core.stock_prices column types');

SELECT pg_temp.expect_true('A4 universe seeded: 20 tickers, 5 sectors x 4',
    (SELECT count(*) = 20 AND count(DISTINCT assigned_sector) = 5 FROM ref.security_universe)
    AND NOT EXISTS (SELECT 1 FROM ref.security_universe GROUP BY assigned_sector HAVING count(*) <> 4),
    (SELECT count(*)::text || ' tickers' FROM ref.security_universe));

-- -----------------------------------------------------------------------------
-- B. Valid inserts (the happy path) — these rows are used by later tests
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_ok('B1 create ingestion batch',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source) VALUES ('PRICES', 'schema-test')$q$);

SELECT pg_temp.expect_ok('B2 insert valid company in universe',
    $q$INSERT INTO core.companies (ticker, company_name, sector, exchange, currency, source)
       VALUES ('AAPL', 'Test Company', 'Information Technology', 'NASDAQ', 'USD', 'schema-test')$q$);

SELECT pg_temp.expect_ok('B3 raw staging accepts a well-formed row',
    $q$INSERT INTO staging.raw_stock_prices
         (ingestion_batch_id, ticker, trade_date, open_price, high_price, low_price, close_price, adjusted_close, volume, source)
       SELECT max(ingestion_batch_id), 'AAPL', '2025-01-02', '100', '105', '99', '104', '103.5', '1000', 'schema-test'
         FROM audit.ingestion_logs$q$);

SELECT pg_temp.expect_ok('B4 insert valid validated price with lineage',
    $q$INSERT INTO core.stock_prices (company_id, trade_date, open_price, high_price, low_price, close_price,
                                     adjusted_close, volume, source, ingestion_timestamp, raw_record_id)
       SELECT c.company_id, DATE '2025-01-02', 100, 105, 99, 104, 103.5, 1000, 'schema-test', now(), r.raw_record_id
         FROM core.companies c, staging.raw_stock_prices r
        WHERE c.ticker = 'AAPL' AND r.source = 'schema-test'$q$);

SELECT pg_temp.expect_ok('B5 insert valid dividend',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, dividend_amount, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-02-10', 'DIVIDEND', 0.25, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$);

SELECT pg_temp.expect_ok('B6 insert valid 4-for-1 split',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, split_ratio, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-03-10', 'STOCK_SPLIT', 4, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$);

SELECT pg_temp.expect_ok('B7 insert trading day and holiday',
    $q$INSERT INTO ref.trading_calendar (exchange, calendar_date, is_trading_day, holiday_name, source)
       VALUES ('TEST', DATE '2025-01-02', true, NULL, 'schema-test'),
              ('TEST', DATE '2025-01-01', false, 'New Year''s Day', 'schema-test')$q$);

-- -----------------------------------------------------------------------------
-- C. Staging is permissive (defects must be storable so they can be reported)
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_ok('C1 staging accepts null close, negative volume, unparseable price, bad ticker',
    $q$INSERT INTO staging.raw_stock_prices
         (ingestion_batch_id, ticker, trade_date, open_price, high_price, low_price, close_price, adjusted_close, volume, source)
       SELECT max(ingestion_batch_id), 'NOT_A_TICKER!', '2025-13-45', 'abc', '90', '95', NULL, NULL, '-500', 'schema-test'
         FROM audit.ingestion_logs$q$);

SELECT pg_temp.expect_ok('C2 staging accepts an exact duplicate row',
    $q$INSERT INTO staging.raw_stock_prices
         (ingestion_batch_id, ticker, trade_date, open_price, high_price, low_price, close_price, adjusted_close, volume, source)
       SELECT ingestion_batch_id, ticker, trade_date, open_price, high_price, low_price, close_price, adjusted_close, volume, source
         FROM staging.raw_stock_prices WHERE ticker = 'AAPL' AND source = 'schema-test'$q$);

-- -----------------------------------------------------------------------------
-- D. Core rejects invalid records
-- -----------------------------------------------------------------------------
-- Reusable fragment: insert a price row for AAPL with given values.
CREATE FUNCTION pg_temp.price_sql(p_date text, p_o text, p_h text, p_l text, p_c text, p_adj text, p_v text)
RETURNS text LANGUAGE sql AS $$
    SELECT format(
      'INSERT INTO core.stock_prices (company_id, trade_date, open_price, high_price, low_price, close_price,
                                      adjusted_close, volume, source, ingestion_timestamp, raw_record_id)
       SELECT c.company_id, DATE %L, %s, %s, %s, %s, %s, %s, ''schema-test'', now(),
              (SELECT min(r.raw_record_id) FROM staging.raw_stock_prices r      -- an unpromoted raw row
                WHERE r.source = ''schema-test''
                  AND NOT EXISTS (SELECT 1 FROM core.stock_prices p WHERE p.raw_record_id = r.raw_record_id))
         FROM core.companies c WHERE c.ticker = ''AAPL''',
      p_date, p_o, p_h, p_l, p_c, p_adj, p_v);
$$;

SELECT pg_temp.expect_error('D1 duplicate company ticker rejected',
    $q$INSERT INTO core.companies (ticker, company_name, sector, exchange, currency, source)
       VALUES ('AAPL', 'Duplicate', 'Information Technology', 'NASDAQ', 'USD', 'schema-test')$q$, '23505');

SELECT pg_temp.expect_error('D2 company ticker outside universe rejected (FK)',
    $q$INSERT INTO core.companies (ticker, company_name, sector, exchange, currency, source)
       VALUES ('ZZZZ', 'Unknown Co', 'Energy', 'NYSE', 'USD', 'schema-test')$q$, '23503');

INSERT INTO ref.security_universe (ticker, assigned_sector) VALUES ('TST', 'Energy');  -- test-only ticker, rolled back
SELECT pg_temp.expect_error('D3 invalid currency code rejected',
    $q$INSERT INTO core.companies (ticker, company_name, sector, exchange, currency, source)
       VALUES ('TST', 'Test', 'Energy', 'NYSE', 'us$', 'schema-test')$q$, '23514');

SELECT pg_temp.expect_error('D4 duplicate company + trade_date rejected',
    pg_temp.price_sql('2025-01-02', '100', '105', '99', '104', '103.5', '1000'), '23505');

SELECT pg_temp.expect_error('D4b same raw record promoted twice rejected (lineage 1:1)',
    $q$INSERT INTO core.stock_prices (company_id, trade_date, open_price, high_price, low_price, close_price,
                                     adjusted_close, volume, source, ingestion_timestamp, raw_record_id)
       SELECT company_id, DATE '2025-01-15', 100, 105, 99, 104, 104, 1000, 'schema-test', now(),
              (SELECT raw_record_id FROM core.stock_prices WHERE trade_date = DATE '2025-01-02')
         FROM core.companies WHERE ticker = 'AAPL'$q$, '23505');

SELECT pg_temp.expect_error('D5 high below low rejected',
    pg_temp.price_sql('2025-01-03', '100', '95', '99', '98', '98', '1000'), '23514');

SELECT pg_temp.expect_error('D6 negative volume rejected',
    pg_temp.price_sql('2025-01-06', '100', '105', '99', '104', '104', '-1'), '23514');

SELECT pg_temp.expect_error('D7 zero price rejected',
    pg_temp.price_sql('2025-01-07', '0', '105', '99', '104', '104', '1000'), '23514');

SELECT pg_temp.expect_error('D8 close above high rejected',
    pg_temp.price_sql('2025-01-08', '100', '105', '99', '110', '110', '1000'), '23514');

SELECT pg_temp.expect_error('D9 open below low rejected',
    pg_temp.price_sql('2025-01-09', '90', '105', '99', '104', '104', '1000'), '23514');

SELECT pg_temp.expect_error('D10 null close rejected',
    pg_temp.price_sql('2025-01-10', '100', '105', '99', 'NULL', '104', '1000'), '23502');

SELECT pg_temp.expect_ok('D11 adjusted_close outside high-low range allowed (dividend adjustment)',
    pg_temp.price_sql('2025-01-13', '100', '105', '99', '104', '95', '1000'));

SELECT pg_temp.expect_error('D12 price for nonexistent company rejected (FK)',
    $q$INSERT INTO core.stock_prices (company_id, trade_date, open_price, high_price, low_price, close_price,
                                     adjusted_close, volume, source, ingestion_timestamp, raw_record_id)
       SELECT 999999, DATE '2025-01-02', 1, 1, 1, 1, 1, 1, 'schema-test', now(), min(r.raw_record_id)
         FROM staging.raw_stock_prices r     -- an unpromoted raw row, so only the FK can fail
        WHERE NOT EXISTS (SELECT 1 FROM core.stock_prices p WHERE p.raw_record_id = r.raw_record_id)$q$, '23503');

SELECT pg_temp.expect_error('D13 price without raw lineage rejected',
    $q$INSERT INTO core.stock_prices (company_id, trade_date, open_price, high_price, low_price, close_price,
                                     adjusted_close, volume, source, ingestion_timestamp, raw_record_id)
       SELECT company_id, DATE '2025-01-14', 100, 105, 99, 104, 104, 1000, 'schema-test', now(), NULL
         FROM core.companies WHERE ticker = 'AAPL'$q$, '23502');

-- -----------------------------------------------------------------------------
-- E. Corporate action type-specific rules
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_error('E1 dividend with a split ratio rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, dividend_amount, split_ratio, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-04-10', 'DIVIDEND', 0.25, 2, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23514');

SELECT pg_temp.expect_error('E2 negative dividend rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, dividend_amount, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-04-11', 'DIVIDEND', -0.25, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23514');

SELECT pg_temp.expect_error('E3 split without ratio rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-04-12', 'STOCK_SPLIT', 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23514');

SELECT pg_temp.expect_error('E4 split ratio of 1 (no-op) rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, split_ratio, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-04-13', 'STOCK_SPLIT', 1, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23514');

SELECT pg_temp.expect_error('E5 unknown action type rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, dividend_amount, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-04-14', 'MERGER', 1, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23514');

SELECT pg_temp.expect_error('E6 duplicate dividend same company/date rejected',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, dividend_amount, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-02-10', 'DIVIDEND', 0.30, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$, '23505');

SELECT pg_temp.expect_ok('E7 reverse split (ratio 0.1) allowed',
    $q$INSERT INTO core.corporate_actions (company_id, action_date, action_type, split_ratio, source, ingestion_timestamp)
       SELECT company_id, DATE '2025-05-01', 'STOCK_SPLIT', 0.1, 'schema-test', now() FROM core.companies WHERE ticker = 'AAPL'$q$);

-- -----------------------------------------------------------------------------
-- F. Audit tables: rule catalogue, issue workflow, ingestion logs
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_ok('F1 insert valid rule',
    $q$INSERT INTO audit.data_quality_rules (rule_id, rule_name, rule_category, rule_description, expected_condition,
                                            target_table, severity, issue_class, handling)
       VALUES ('TEST-001', 'test_high_below_low', 'CONSISTENCY', 'High below low', 'high_price >= low_price',
               'staging.raw_stock_prices', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE')$q$);

SELECT pg_temp.expect_error('F2 anomaly rule cannot be set to auto-quarantine',
    $q$INSERT INTO audit.data_quality_rules (rule_id, rule_name, rule_category, rule_description, expected_condition,
                                            target_table, severity, issue_class, handling)
       VALUES ('TEST-002', 'test_big_move', 'ANOMALY', 'Big move', 'abs return <= 10%',
               'core.stock_prices', 'WARNING', 'REVIEWABLE_ANOMALY', 'QUARANTINE')$q$, '23514');

SELECT pg_temp.expect_ok('F3 insert OPEN issue',
    $q$INSERT INTO audit.data_quality_issues (issue_key, rule_id, ticker, trade_date, affected_field, severity)
       VALUES ('TEST-001|AAPL|2025-01-03|high_price', 'TEST-001', 'AAPL', DATE '2025-01-03', 'high_price', 'CRITICAL')$q$);

SELECT pg_temp.expect_error('F4 duplicate issue_key rejected (re-run cannot duplicate issues)',
    $q$INSERT INTO audit.data_quality_issues (issue_key, rule_id, ticker, trade_date, affected_field, severity)
       VALUES ('TEST-001|AAPL|2025-01-03|high_price', 'TEST-001', 'AAPL', DATE '2025-01-03', 'high_price', 'CRITICAL')$q$, '23505');

SELECT pg_temp.expect_error('F5 invalid issue status rejected',
    $q$UPDATE audit.data_quality_issues SET status = 'FIXED' WHERE rule_id = 'TEST-001'$q$, '23514');

SELECT pg_temp.expect_error('F6 RESOLVED without resolved_at rejected',
    $q$UPDATE audit.data_quality_issues SET status = 'RESOLVED' WHERE rule_id = 'TEST-001'$q$, '23514');

SELECT pg_temp.expect_ok('F7 RESOLVED with resolved_at accepted',
    $q$UPDATE audit.data_quality_issues SET status = 'RESOLVED', resolved_at = now(), resolution_notes = 'test'
       WHERE rule_id = 'TEST-001'$q$);

SELECT pg_temp.expect_error('F8 issue linked to two raw sources rejected',
    $q$INSERT INTO audit.data_quality_issues (issue_key, rule_id, raw_record_id, raw_action_id, severity)
       SELECT 'TEST-001|x', 'TEST-001', min(raw_record_id), 1, 'CRITICAL' FROM staging.raw_stock_prices$q$, '23514');

SELECT pg_temp.expect_ok('F9 issue with no raw record (missing session) accepted',
    $q$INSERT INTO audit.data_quality_issues (issue_key, rule_id, ticker, trade_date, affected_field, severity)
       VALUES ('TEST-001|AAPL|2025-01-06|record', 'TEST-001', 'AAPL', DATE '2025-01-06', 'record', 'CRITICAL')$q$);

SELECT pg_temp.expect_error('F10 issue referencing unknown rule rejected (FK)',
    $q$INSERT INTO audit.data_quality_issues (issue_key, rule_id, severity) VALUES ('X|1', 'NO-SUCH-RULE', 'INFO')$q$, '23503');

SELECT pg_temp.expect_error('F11 invalid ingestion status rejected',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status) VALUES ('PRICES', 'schema-test', 'DONE')$q$, '23514');

SELECT pg_temp.expect_error('F12 finished batch without end_timestamp rejected',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status) VALUES ('PRICES', 'schema-test', 'SUCCEEDED')$q$, '23514');

SELECT pg_temp.expect_error('F13 accepted + rejected exceeding received rejected',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status, end_timestamp, records_received, records_accepted, records_rejected)
       VALUES ('PRICES', 'schema-test', 'SUCCEEDED', now(), 10, 8, 5)$q$, '23514');

SELECT pg_temp.expect_ok('F14 first successful load of a snapshot checksum accepted',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status, end_timestamp, source_checksum)
       VALUES ('PRICES', 'schema-test', 'SUCCEEDED', now(), repeat('a', 64))$q$);

SELECT pg_temp.expect_error('F15 second successful load of same snapshot rejected (rerun protection)',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status, end_timestamp, source_checksum)
       VALUES ('PRICES', 'schema-test', 'SUCCEEDED', now(), repeat('a', 64))$q$, '23505');

SELECT pg_temp.expect_ok('F16 SKIPPED rerun of same snapshot can be logged',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status, end_timestamp, source_checksum)
       VALUES ('PRICES', 'schema-test', 'SKIPPED', now(), repeat('a', 64))$q$);

SELECT pg_temp.expect_ok('F17 same checksum allowed for a different dataset type',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, status, end_timestamp, source_checksum)
       VALUES ('CORPORATE_ACTIONS', 'schema-test', 'SUCCEEDED', now(), repeat('a', 64))$q$);

SELECT pg_temp.expect_error('F18 malformed checksum rejected',
    $q$INSERT INTO audit.ingestion_logs (batch_type, source, source_checksum) VALUES ('PRICES', 'schema-test', 'abc')$q$, '23514');

-- -----------------------------------------------------------------------------
-- G. Calendar, lineage protection and triggers
-- -----------------------------------------------------------------------------
SELECT pg_temp.expect_error('G1 duplicate calendar day rejected',
    $q$INSERT INTO ref.trading_calendar (exchange, calendar_date, is_trading_day, source)
       VALUES ('TEST', DATE '2025-01-02', true, 'schema-test')$q$, '23505');

SELECT pg_temp.expect_error('G2 trading day with holiday name rejected',
    $q$INSERT INTO ref.trading_calendar (exchange, calendar_date, is_trading_day, holiday_name, source)
       VALUES ('TEST', DATE '2025-01-03', true, 'Not a holiday', 'schema-test')$q$, '23514');

SELECT pg_temp.expect_error('G3 raw record used by a validated price cannot be deleted (lineage)',
    $q$DELETE FROM staging.raw_stock_prices
        WHERE raw_record_id IN (SELECT raw_record_id FROM core.stock_prices)$q$, '23503');

-- updated_at trigger: now() is fixed within a transaction, so we backdate first,
-- then update and confirm the trigger moved it forward again.
UPDATE core.companies SET updated_at = now() - interval '1 day' WHERE ticker = 'AAPL';
UPDATE core.companies SET company_name = 'Test Company Renamed' WHERE ticker = 'AAPL';
SELECT pg_temp.expect_true('G4 updated_at trigger stamps changed rows',
    (SELECT updated_at = now() FROM core.companies WHERE ticker = 'AAPL'),
    (SELECT updated_at::text FROM core.companies WHERE ticker = 'AAPL'));

-- -----------------------------------------------------------------------------
-- Results
-- -----------------------------------------------------------------------------
\o
\echo
\echo '=== Phase 1 schema test results ==='
SELECT test_no AS "#", test_name, expected,
       left(actual, 70) AS actual,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM test_results ORDER BY test_no;

SELECT count(*) AS total_tests,
       count(*) FILTER (WHERE passed)     AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed
  FROM test_results;

-- Fail the script (non-zero exit code) if any test failed.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM test_results WHERE NOT passed) THEN
        RAISE EXCEPTION 'Schema tests FAILED: % failing test(s)', (SELECT count(*) FROM test_results WHERE NOT passed);
    END IF;
END $$;

ROLLBACK;  -- leave the database untouched
