-- =============================================================================
-- 11_quality_test_data.sql
-- Purpose : SYNTHETIC fixtures with known, seeded defects, plus the expected outcome
--           of every fixture, for testing the SQL quality framework.
-- Phase   : 3 — Quality framework
-- Run     : ONLY via scripts/run_quality_tests.sh, which targets equityiq_test.
--           Never applied by db_init.sh. Refuses to run in a non-test database.
--
-- Everything here is invented test data labelled source = 'synthetic_fixture'.
-- Real market data is never modified for testing.
--
-- Design
--   * Fixture window 2025-11-24 .. 2026-02-27 with a calendar that mirrors the real
--     XNYS holidays in that period (Thanksgiving, Christmas, New Year, MLK, Presidents).
--   * Six requested tickers. Five get a smooth, valid CONTROL price series (daily moves
--     well below every anomaly threshold); defects are then seeded on specific rows.
--   * qa.fixture_expectations records, per fixture, the rule ids that MUST fire (and no
--     others) and the expected outcome. 12_validation_tests.sql compares actual results.
-- =============================================================================

\set ON_ERROR_STOP 1

DO $$
BEGIN
    IF current_database() NOT LIKE '%test%' THEN
        RAISE EXCEPTION 'Refusing to load synthetic fixtures into database "%" (name must contain "test")', current_database();
    END IF;
END $$;

BEGIN;

CREATE SCHEMA IF NOT EXISTS qa;
COMMENT ON SCHEMA qa IS 'Synthetic test fixtures and test results (test database only).';

CREATE TABLE qa.fixture_batches (
    batch_name          text PRIMARY KEY,
    ingestion_batch_id  bigint NOT NULL REFERENCES audit.ingestion_logs (ingestion_batch_id)
);

CREATE TABLE qa.fixture_expectations (
    fixture_id        text PRIMARY KEY,
    dataset           text NOT NULL CHECK (dataset IN ('PRICE', 'ACTION', 'REFERENCE', 'NO_RECORD')),
    batch_name        text NOT NULL,
    ticker            text,
    record_key        text,             -- raw date text; for actions 'date|type'
    expected_rules    text[] NOT NULL,  -- exact set of rules that must fire ({} = none)
    expected_outcome  text NOT NULL CHECK (expected_outcome IN
                        ('PROMOTED', 'PROMOTED_FLAGGED', 'QUARANTINED', 'ONE_PROMOTED_REST_REDUNDANT',
                         'ISSUE_ONLY', 'NOT_PROMOTED')),
    description       text NOT NULL
);

-- Sector labels used by the synthetic reference rows (test DB only).
INSERT INTO ref.sector_mapping (source, provider_sector, mapped_sector)
SELECT 'synthetic_fixture', provider_sector, mapped_sector FROM ref.sector_mapping WHERE source = 'yahoo_finance';

-- -----------------------------------------------------------------------------
-- Calendar (mirrors real XNYS closures in the window)
-- -----------------------------------------------------------------------------
INSERT INTO ref.trading_calendar (exchange, calendar_date, is_trading_day, is_early_close, holiday_name, source)
SELECT 'XNYS', d::date,
       extract(isodow FROM d) < 6 AND h.holiday IS NULL,
       d::date IN (DATE '2025-11-28', DATE '2025-12-24'),
       h.holiday,
       'synthetic_fixture (mirrors XNYS closures)'
  FROM generate_series(DATE '2025-11-24', DATE '2026-02-27', interval '1 day') AS d
  LEFT JOIN (VALUES (DATE '2025-11-27', 'Thanksgiving'),
                    (DATE '2025-12-25', 'Christmas'),
                    (DATE '2026-01-01', 'New Year''s Day'),
                    (DATE '2026-01-19', 'Dr. Martin Luther King Jr. Day'),
                    (DATE '2026-02-16', 'President''s Day')) AS h(day, holiday)
         ON h.day = d::date;

-- -----------------------------------------------------------------------------
-- Batches
-- -----------------------------------------------------------------------------
WITH b AS (
    INSERT INTO audit.ingestion_logs (batch_type, source, retrieval_parameters, snapshot_start_date,
                                      snapshot_end_date, snapshot_label, status, end_timestamp)
    SELECT t.batch_type, 'synthetic_fixture',
           jsonb_build_object('tickers_requested', jsonb_build_array('AAPL','MSFT','JPM','XOM','JNJ','MCD'),
                              'note', 'SYNTHETIC TEST FIXTURE'),
           DATE '2025-11-24', DATE '2026-02-27', 'synthetic_fixture_v1', 'SUCCEEDED', now()
      FROM (VALUES (1, 'COMPANY_REFERENCE'), (2, 'PRICES'), (3, 'CORPORATE_ACTIONS')) AS t(ord, batch_type)
     ORDER BY t.ord
    RETURNING ingestion_batch_id, batch_type
)
INSERT INTO qa.fixture_batches (batch_name, ingestion_batch_id)
SELECT CASE batch_type WHEN 'COMPANY_REFERENCE' THEN 'R1' WHEN 'PRICES' THEN 'P1' ELSE 'A1' END, ingestion_batch_id
  FROM b;

-- -----------------------------------------------------------------------------
-- Reference batch R1
-- -----------------------------------------------------------------------------
INSERT INTO staging.raw_company_reference (ingestion_batch_id, source_row_number, ticker, company_name, sector, industry, exchange, currency, source)
SELECT (SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = 'R1'), v.*
  FROM (VALUES
    (1, 'AAPL', 'Fixture Apple',     'Technology',         'Consumer Electronics',  'NMS', 'USD', 'synthetic_fixture'),
    (2, 'MSFT', 'Fixture Microsoft', 'Technology',         'Software',              'NMS', 'USD', 'synthetic_fixture'),
    (3, 'JPM',  'Fixture JPMorgan',  'Financial Services', 'Banks',                 'NYQ', 'USD', 'synthetic_fixture'),
    (4, 'XOM',  'Fixture Exxon',     'Energy',             'Oil & Gas Integrated',  'NYQ', 'USD', 'synthetic_fixture'),
    (5, 'XOM',  'Fixture Exxon',     'Energy',             'Oil & Gas Integrated',  'NYQ', 'USD', 'synthetic_fixture'),  -- exact duplicate
    (6, 'JNJ',  'Fixture J&J',       'Energy',             'Drug Manufacturers',    'NYQ', 'USD', 'synthetic_fixture'),  -- sector mismatch
    (7, 'MCD',  'Fixture McDonalds', 'Consumer Cyclical',  'Restaurants',           'NYQ', 'US$', 'synthetic_fixture'),  -- bad currency
    (8, 'ZZZZ', 'Unknown Co',        'Energy',             'Unknown',               'NYQ', 'USD', 'synthetic_fixture'),  -- not in universe
    (9, 'NKE',  '',                  'Consumer Cyclical',  NULL,                    'NYQ', 'USD', 'synthetic_fixture'),  -- blank name + missing industry
    (10,'TSLA', 'Fixture Tesla',     'Consumer Cyclical',  'Auto Manufacturers',    'NMS', 'USD', 'synthetic_fixture'),  -- conflicting duplicate ...
    (11,'TSLA', 'Fixture Tesla Inc', 'Consumer Cyclical',  'Auto Manufacturers',    'NMS', 'USD', 'synthetic_fixture')   -- ... different name
  ) AS v(n, ticker, company_name, sector, industry, exchange, currency, source);

-- -----------------------------------------------------------------------------
-- Price batch P1: control series for all six tickers
-- close = base x (1 + 0.004 x sin(0.7 n)); max one-day move ~0.3%, far below thresholds.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE control_prices ON COMMIT DROP AS
WITH sessions AS (
    SELECT calendar_date, row_number() OVER (ORDER BY calendar_date) AS n
      FROM ref.trading_calendar
     WHERE exchange = 'XNYS' AND is_trading_day AND calendar_date BETWEEN DATE '2025-11-24' AND DATE '2026-02-27'
),
tickers AS (
    SELECT * FROM (VALUES ('AAPL', 200.0), ('MSFT', 400.0), ('JPM', 250.0),
                          ('XOM', 110.0), ('JNJ', 160.0), ('MCD', 290.0)) AS t(ticker, base)
),
closes AS (
    SELECT t.ticker, s.calendar_date, s.n, (t.base * (1 + 0.004 * sin(0.7 * s.n)))::numeric AS c
      FROM tickers t CROSS JOIN sessions s
)
SELECT ticker, calendar_date, n,
       round(c * 0.998, 2) AS o, round(c * 1.01, 2) AS h, round(c * 0.99, 2) AS l,
       round(c, 2) AS c, round(c, 2) AS adj,
       (1000000 + 50000 * ((n * 7) % 5))::bigint AS v
  FROM closes;

INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price,
                                      high_price, low_price, close_price, adjusted_close, volume, currency, source)
SELECT (SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = 'P1'),
       row_number() OVER (ORDER BY ticker, calendar_date),
       ticker, calendar_date::text, o::text, h::text, l::text, c::text, adj::text, v::text, 'USD', 'synthetic_fixture'
  FROM control_prices;

-- Helper: the P1 batch id
CREATE TEMP TABLE p1 ON COMMIT DROP AS SELECT ingestion_batch_id AS id FROM qa.fixture_batches WHERE batch_name = 'P1';

-- ---- Seed defects into P1 ---------------------------------------------------
-- F01 exact duplicate (AAPL 2026-01-06)
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT ingestion_batch_id, 9001, ticker, trade_date, open_price, high_price, low_price, close_price, adjusted_close, volume, currency, source
  FROM staging.raw_stock_prices WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'AAPL' AND trade_date = '2026-01-06';

-- F02 conflicting duplicate (AAPL 2026-01-07): second copy has a different close
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT ingestion_batch_id, 9002, ticker, trade_date, open_price, high_price, low_price,
       (close_price::numeric + 0.50)::text, adjusted_close, volume, currency, source
  FROM staging.raw_stock_prices WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'AAPL' AND trade_date = '2026-01-07';

-- F03 null close (MSFT 2026-01-08)
UPDATE staging.raw_stock_prices SET close_price = NULL
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'MSFT' AND trade_date = '2026-01-08';

-- F04 negative volume (MSFT 2026-01-09)
UPDATE staging.raw_stock_prices SET volume = '-500'
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'MSFT' AND trade_date = '2026-01-09';

-- F05 invalid ticker (APPL typo)
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT id, 9005, 'APPL', '2026-01-09', '200.00', '202.00', '198.00', '201.00', '201.00', '1000000', 'USD', 'synthetic_fixture' FROM p1;

-- F06 high below low (JPM 2026-01-12): swap high and low -> CNS-001 AND CNS-002 AND CNS-003
UPDATE staging.raw_stock_prices SET high_price = low_price, low_price = high_price
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JPM' AND trade_date = '2026-01-12';

-- F07 missing session (JPM 2026-01-13)
DELETE FROM staging.raw_stock_prices
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JPM' AND trade_date = '2026-01-13';

-- F08 legitimate extreme move: XOM re-prices +15% from 2026-01-14 onward (genuine level shift)
UPDATE staging.raw_stock_prices
   SET open_price = round(open_price::numeric * 1.15, 2)::text, high_price = round(high_price::numeric * 1.15, 2)::text,
       low_price = round(low_price::numeric * 1.15, 2)::text,   close_price = round(close_price::numeric * 1.15, 2)::text,
       adjusted_close = round(adjusted_close::numeric * 1.15, 2)::text
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'XOM' AND trade_date >= '2026-01-14';

-- F09 multiple failures on one row (MSFT 2026-01-15): zero open AND missing volume
UPDATE staging.raw_stock_prices SET open_price = '0', volume = NULL
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'MSFT' AND trade_date = '2026-01-15';

-- F10 record on an exchange holiday (JNJ 2026-01-19, MLK Day)
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT id, 9010, 'JNJ', '2026-01-19', '160.00', '161.00', '159.00', '160.50', '160.50', '900000', 'USD', 'synthetic_fixture' FROM p1;

-- F11 unparseable price (JNJ 2026-01-20)
UPDATE staging.raw_stock_prices SET open_price = 'abc'
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JNJ' AND trade_date = '2026-01-20';

-- F12 future date outside the window (XOM 2027-01-04)
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT id, 9012, 'XOM', '2027-01-04', '126.00', '127.00', '125.00', '126.50', '126.50', '1000000', 'USD', 'synthetic_fixture' FROM p1;

-- F13 currency conflict (JPM 2026-01-21 reported in EUR)
UPDATE staging.raw_stock_prices SET currency = 'EUR'
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JPM' AND trade_date = '2026-01-21';

-- F14 volume spike (JNJ 2026-02-10 at 6x normal)
UPDATE staging.raw_stock_prices SET volume = (volume::bigint * 6)::text
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JNJ' AND trade_date = '2026-02-10';

-- F15 adjusted series steps +2% with no corporate action (MSFT from 2026-02-03)
UPDATE staging.raw_stock_prices SET adjusted_close = round(adjusted_close::numeric * 1.02, 2)::text
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'MSFT' AND trade_date >= '2026-02-03';

-- F17 impossible date (XOM '2026-13-45')
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT id, 9017, 'XOM', '2026-13-45', '126.00', '127.00', '125.00', '126.50', '126.50', '1000000', 'USD', 'synthetic_fixture' FROM p1;

-- F19 fractional volume (AAPL 2026-01-26)
UPDATE staging.raw_stock_prices SET volume = '1000000.5'
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'AAPL' AND trade_date = '2026-01-26';

-- F24 blank ticker
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT id, 9024, '', '2026-01-09', '200.00', '202.00', '198.00', '201.00', '201.00', '1000000', 'USD', 'synthetic_fixture' FROM p1;

-- F25 numeric format a generic parser would accept but a price file must not contain
UPDATE staging.raw_stock_prices SET volume = '1_000_000'
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'AAPL' AND trade_date = '2026-01-27';

-- F21 large move ACROSS A GAP must not be called a one-day return:
-- JPM re-prices +20% from 2026-01-14; previous validated record is 2026-01-09
-- (01-12 quarantined by F06, 01-13 missing by F07).
UPDATE staging.raw_stock_prices
   SET open_price = round(open_price::numeric * 1.20, 2)::text, high_price = round(high_price::numeric * 1.20, 2)::text,
       low_price = round(low_price::numeric * 1.20, 2)::text,   close_price = round(close_price::numeric * 1.20, 2)::text,
       adjusted_close = round(adjusted_close::numeric * 1.20, 2)::text
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'JPM' AND trade_date >= '2026-01-14';

-- F23 latest session missing (XOM 2026-02-27, the last session in the window)
DELETE FROM staging.raw_stock_prices
 WHERE ingestion_batch_id = (SELECT id FROM p1) AND ticker = 'XOM' AND trade_date = '2026-02-27';

UPDATE audit.ingestion_logs SET records_received = (SELECT count(*) FROM staging.raw_stock_prices r, p1 WHERE r.ingestion_batch_id = p1.id)
 WHERE ingestion_batch_id = (SELECT id FROM p1);
UPDATE audit.ingestion_logs SET records_received = (SELECT count(*) FROM staging.raw_company_reference r JOIN qa.fixture_batches b
                                                     ON b.ingestion_batch_id = r.ingestion_batch_id AND b.batch_name = 'R1')
 WHERE ingestion_batch_id = (SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = 'R1');

-- -----------------------------------------------------------------------------
-- Corporate action batch A1
-- -----------------------------------------------------------------------------
INSERT INTO staging.raw_corporate_actions (ingestion_batch_id, source_row_number, ticker, action_date, action_type,
                                           dividend_amount, split_ratio, source)
SELECT (SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = 'A1'), v.*
  FROM (VALUES
    (1,  'JNJ',  '2026-02-23', 'DIVIDEND',    '1.30',  NULL, 'synthetic_fixture'),   -- F30 valid dividend
    (2,  'AAPL', '2026-02-06', 'STOCK_SPLIT', NULL,    '4',  'synthetic_fixture'),   -- F31 valid 4-for-1 split
    (3,  'MSFT', '2026-02-10', 'DIVIDEND',    '-0.50', NULL, 'synthetic_fixture'),   -- F32 negative dividend
    (4,  'XOM',  '2026-02-11', 'STOCK_SPLIT', NULL,    '0',  'synthetic_fixture'),   -- F33 zero split ratio
    (5,  'JPM',  '2026-02-12', 'DIVIDEND',    '1.40',  NULL, 'synthetic_fixture'),   -- F34 exact duplicate ...
    (6,  'JPM',  '2026-02-12', 'DIVIDEND',    '1.40',  NULL, 'synthetic_fixture'),   --     ... second copy
    (7,  'JPM',  '2026-01-30', 'DIVIDEND',    '1.40',  NULL, 'synthetic_fixture'),   -- F35 conflicting duplicate ...
    (8,  'JPM',  '2026-01-30', 'DIVIDEND',    '1.45',  NULL, 'synthetic_fixture'),   --     ... different amount
    (9,  'JNJ',  '2026-02-14', 'DIVIDEND',    '1.30',  NULL, 'synthetic_fixture'),   -- F36 Saturday ex-date
    (10, 'AAPL', '2026-02-09', 'SPINOFF',     '5.00',  NULL, 'synthetic_fixture'),   -- F37 unsupported type
    (11, 'MCD',  '2026-02-02', 'DIVIDEND',    '1.77',  NULL, 'synthetic_fixture')    -- F38 company failed validation
  ) AS v(n, ticker, action_date, action_type, dividend_amount, split_ratio, source);

UPDATE audit.ingestion_logs SET records_received = 11
 WHERE ingestion_batch_id = (SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = 'A1');

-- -----------------------------------------------------------------------------
-- Expected outcomes (written BEFORE the framework runs)
-- -----------------------------------------------------------------------------
INSERT INTO qa.fixture_expectations (fixture_id, dataset, batch_name, ticker, record_key, expected_rules, expected_outcome, description) VALUES
-- controls (negative tests: nothing may fire)
('C01', 'PRICE', 'P1', 'AAPL', '2026-01-05', '{}', 'PROMOTED', 'Valid control record'),
('C02', 'PRICE', 'P1', 'JNJ',  '2026-02-02', '{}', 'PROMOTED', 'Valid control record'),
('C03', 'PRICE', 'P1', 'XOM',  '2026-01-13', '{}', 'PROMOTED', 'Valid control record the day before a large move'),
('C04', 'PRICE', 'P1', 'XOM',  '2026-01-15', '{}', 'PROMOTED', 'Day after a level shift: normal move, not flagged'),
('C05', 'PRICE', 'P1', 'JNJ',  '2026-01-21', '{}', 'PROMOTED', 'Day after a quarantined record: gap return not evaluated, nothing flagged'),
-- seeded price defects
('F01', 'PRICE', 'P1', 'AAPL', '2026-01-06', '{DQ-UNI-001}', 'ONE_PROMOTED_REST_REDUNDANT', 'Exact duplicate: first copy promoted, second not'),
('F02', 'PRICE', 'P1', 'AAPL', '2026-01-07', '{DQ-UNI-002}', 'QUARANTINED', 'Conflicting duplicate: both copies quarantined'),
('F03', 'PRICE', 'P1', 'MSFT', '2026-01-08', '{DQ-COM-001}', 'QUARANTINED', 'Null close'),
('F04', 'PRICE', 'P1', 'MSFT', '2026-01-09', '{DQ-VAL-003}', 'QUARANTINED', 'Negative volume'),
('F05', 'PRICE', 'P1', 'APPL', '2026-01-09', '{DQ-VAL-004}', 'QUARANTINED', 'Invalid ticker (typo)'),
('F06', 'PRICE', 'P1', 'JPM',  '2026-01-12', '{DQ-CNS-001,DQ-CNS-002,DQ-CNS-003}', 'QUARANTINED', 'High below low: one row, three consistency failures'),
('F07', 'NO_RECORD', 'P1', 'JPM', '2026-01-13', '{DQ-COM-004}', 'ISSUE_ONLY', 'Missing trading session: issue without raw record'),
('F08', 'PRICE', 'P1', 'XOM',  '2026-01-14', '{DQ-ANO-001,DQ-ANO-003}', 'PROMOTED_FLAGGED', 'Legitimate +15% move: flagged for review, NOT discarded'),
('F09', 'PRICE', 'P1', 'MSFT', '2026-01-15', '{DQ-CNS-002,DQ-COM-002,DQ-VAL-002}', 'QUARANTINED', 'Multiple failures: zero open (invalid AND outside day range) and missing volume'),
('F10', 'PRICE', 'P1', 'JNJ',  '2026-01-19', '{DQ-VAL-007}', 'QUARANTINED', 'Record dated on an exchange holiday'),
('F10b','NO_RECORD', 'P1', 'AAPL', '2026-01-19', '{}', 'NOT_PROMOTED', 'Holiday: no missing-session issue for a closed market'),
('F11', 'PRICE', 'P1', 'JNJ',  '2026-01-20', '{DQ-VAL-001}', 'QUARANTINED', 'Unparseable open price "abc"'),
('F12', 'PRICE', 'P1', 'XOM',  '2027-01-04', '{DQ-VAL-006}', 'QUARANTINED', 'Future date outside the snapshot window'),
('F13', 'PRICE', 'P1', 'JPM',  '2026-01-21', '{DQ-CNS-004}', 'QUARANTINED', 'Price currency differs from company currency'),
('F14', 'PRICE', 'P1', 'JNJ',  '2026-02-10', '{DQ-ANO-002}', 'PROMOTED_FLAGGED', 'Volume spike 6x: flagged, promoted'),
('F15', 'PRICE', 'P1', 'MSFT', '2026-02-03', '{DQ-ANO-003,DQ-CNS-007}', 'PROMOTED_FLAGGED', 'Adjusted series steps +2% with no corporate action'),
('F16', 'PRICE', 'P1', 'MCD',  '2026-01-05', '{DQ-COM-007}', 'QUARANTINED', 'Price for a company whose reference data was quarantined'),
('F17', 'PRICE', 'P1', 'XOM',  '2026-13-45', '{DQ-VAL-005}', 'QUARANTINED', 'Impossible date'),
('F18', 'NO_RECORD', 'P1', 'AAPL', '2026-01-10', '{}', 'NOT_PROMOTED', 'Saturday: no missing-session issue'),
('F19', 'PRICE', 'P1', 'AAPL', '2026-01-26', '{DQ-VAL-008}', 'QUARANTINED', 'Fractional volume'),
('F21', 'PRICE', 'P1', 'JPM',  '2026-01-14', '{}', 'PROMOTED', '+20% across a 3-session gap: NOT evaluated as a one-day return'),
('F24', 'PRICE', 'P1', '',     '2026-01-09', '{DQ-COM-003}', 'QUARANTINED', 'Blank ticker'),
('F25', 'PRICE', 'P1', 'AAPL', '2026-01-27', '{DQ-VAL-001}', 'QUARANTINED', 'Volume "1_000_000": underscore digit grouping rejected'),
('F23', 'NO_RECORD', 'P1', 'XOM', '2026-02-27', '{DQ-COM-004,DQ-TIM-002}', 'ISSUE_ONLY', 'Last session of the window missing: completeness + timeliness'),
-- reference
('R01', 'REFERENCE', 'R1', 'AAPL', NULL, '{}', 'PROMOTED', 'Valid reference record'),
('R02', 'REFERENCE', 'R1', 'XOM',  NULL, '{DQ-UNI-005}', 'ONE_PROMOTED_REST_REDUNDANT', 'Exact duplicate reference row'),
('R03', 'REFERENCE', 'R1', 'JNJ',  NULL, '{DQ-CNS-005}', 'PROMOTED_FLAGGED', 'Provider sector Energy vs assigned Healthcare: informational'),
('R04', 'REFERENCE', 'R1', 'MCD',  NULL, '{DQ-VAL-012}', 'QUARANTINED', 'Invalid currency code US$'),
('R05', 'REFERENCE', 'R1', 'ZZZZ', NULL, '{DQ-VAL-004}', 'QUARANTINED', 'Ticker not in universe'),
('R06', 'REFERENCE', 'R1', 'NKE',  NULL, '{DQ-COM-005,DQ-COM-006}', 'QUARANTINED', 'Blank company name (critical) and missing industry (warning)'),
('R07', 'REFERENCE', 'R1', 'TSLA', NULL, '{DQ-UNI-006}', 'QUARANTINED', 'Conflicting duplicate reference rows'),
-- corporate actions
('A30', 'ACTION', 'A1', 'JNJ',  '2026-02-23|DIVIDEND',    '{}', 'PROMOTED', 'Valid dividend'),
('A31', 'ACTION', 'A1', 'AAPL', '2026-02-06|STOCK_SPLIT', '{}', 'PROMOTED', 'Valid 4-for-1 split'),
('A32', 'ACTION', 'A1', 'MSFT', '2026-02-10|DIVIDEND',    '{DQ-VAL-010}', 'QUARANTINED', 'Negative dividend'),
('A33', 'ACTION', 'A1', 'XOM',  '2026-02-11|STOCK_SPLIT', '{DQ-VAL-011}', 'QUARANTINED', 'Zero split ratio'),
('A34', 'ACTION', 'A1', 'JPM',  '2026-02-12|DIVIDEND',    '{DQ-UNI-003}', 'ONE_PROMOTED_REST_REDUNDANT', 'Exact duplicate dividend'),
('A35', 'ACTION', 'A1', 'JPM',  '2026-01-30|DIVIDEND',    '{DQ-UNI-004}', 'QUARANTINED', 'Conflicting dividend amounts'),
('A36', 'ACTION', 'A1', 'JNJ',  '2026-02-14|DIVIDEND',    '{DQ-VAL-007}', 'QUARANTINED', 'Ex-date on a Saturday'),
('A37', 'ACTION', 'A1', 'AAPL', '2026-02-09|SPINOFF',     '{DQ-VAL-009}', 'QUARANTINED', 'Unsupported action type'),
('A38', 'ACTION', 'A1', 'MCD',  '2026-02-02|DIVIDEND',    '{DQ-COM-007}', 'QUARANTINED', 'Company reference failed validation');

COMMIT;

\echo 'Synthetic fixtures loaded.'
SELECT b.batch_name, l.ingestion_batch_id, l.batch_type, l.records_received
  FROM qa.fixture_batches b JOIN audit.ingestion_logs l USING (ingestion_batch_id) ORDER BY 2;
