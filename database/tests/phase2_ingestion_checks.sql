-- =============================================================================
-- phase2_ingestion_checks.sql
-- Purpose : Reconciliation report proving the Phase 2 load is complete, traceable
--           and correctly understood. READ-ONLY: it changes nothing.
-- Run     : scripts/run_ingestion_checks.sh
--
-- This is a load reconciliation, not the data quality framework. The formal
-- rules (with severities, issues and quarantine) are built in Phase 3.
-- Concepts: CTEs (WITH), LEFT JOIN anti-joins, GROUP BY / HAVING, CASE,
--           window functions (LAG), pg_input_is_valid(), jsonb operators.
-- =============================================================================

\pset footer off
\echo '=== 1. Ingestion batches ==='
SELECT ingestion_batch_id AS batch, batch_type, status, records_received AS received,
       snapshot_start_date AS window_start, snapshot_end_date AS window_end,
       left(source_checksum, 12) || '…' AS checksum,
       round(extract(epoch FROM end_timestamp - start_timestamp)::numeric, 3) AS seconds,
       error_message
  FROM audit.ingestion_logs
 ORDER BY ingestion_batch_id;


\echo '=== 2. Trading calendar composition (expected: 365 days, 251 sessions, 10 holidays, 2 early closes) ==='
-- CASE groups each day into a category; GROUP BY counts each category.
SELECT CASE WHEN is_trading_day AND is_early_close THEN 'trading day (early close)'
            WHEN is_trading_day                    THEN 'trading day (full)'
            WHEN holiday_name IS NOT NULL          THEN 'holiday (weekday closure)'
            ELSE 'weekend' END                     AS day_type,
       count(*) AS days
  FROM ref.trading_calendar
 WHERE exchange = 'XNYS'
 GROUP BY 1
 ORDER BY 1;

SELECT calendar_date, to_char(calendar_date, 'Dy') AS weekday, holiday_name
  FROM ref.trading_calendar
 WHERE exchange = 'XNYS' AND holiday_name IS NOT NULL
 ORDER BY calendar_date;


\echo '=== 3. Expected-session coverage per ticker (expected sessions x 20 tickers) ==='
-- Expected = every (ticker, trading session) pair: a CROSS JOIN of the universe
-- with the calendar's trading days. LEFT JOIN to the raw rows: where no raw row
-- matches, r.ticker IS NULL, i.e. the session is missing.
WITH latest_price_batch AS (
    SELECT max(ingestion_batch_id) AS batch_id
      FROM audit.ingestion_logs
     WHERE batch_type = 'PRICES' AND status IN ('SUCCEEDED', 'PARTIAL')
),
expected AS (
    SELECT u.ticker, c.calendar_date
      FROM ref.security_universe u
     CROSS JOIN ref.trading_calendar c
     WHERE u.is_active AND c.exchange = 'XNYS' AND c.is_trading_day
),
received AS (
    SELECT DISTINCT r.ticker, r.trade_date::date AS trade_date
      FROM staging.raw_stock_prices r
      JOIN latest_price_batch b ON r.ingestion_batch_id = b.batch_id
)
SELECT e.ticker,
       count(*)                                    AS expected_sessions,
       count(r.ticker)                             AS sessions_received,
       count(*) - count(r.ticker)                  AS sessions_missing,
       round(100.0 * count(r.ticker) / count(*), 2) AS coverage_pct
  FROM expected e
  LEFT JOIN received r ON r.ticker = e.ticker AND r.trade_date = e.calendar_date
 GROUP BY e.ticker
 ORDER BY sessions_missing DESC, e.ticker;


\echo '=== 4. Load-level totals ==='
-- One row of headline numbers. Scalar subqueries each return a single value.
SELECT (SELECT count(*) FROM staging.raw_stock_prices)                                   AS raw_price_rows,
       (SELECT count(*) * (SELECT count(*) FROM ref.security_universe WHERE is_active)
          FROM ref.trading_calendar WHERE exchange = 'XNYS' AND is_trading_day)          AS expected_price_rows,
       (SELECT count(DISTINCT ticker) FROM staging.raw_stock_prices)                     AS tickers_with_prices,
       (SELECT min(trade_date) FROM staging.raw_stock_prices)                            AS first_date,
       (SELECT max(trade_date) FROM staging.raw_stock_prices)                            AS last_date,
       (SELECT count(*) FROM staging.raw_corporate_actions)                              AS raw_actions,
       (SELECT count(*) FROM staging.raw_company_reference)                              AS raw_reference_rows;


\echo '=== 5. Rows dated outside the window or on non-trading days (expected: 0) ==='
SELECT r.ticker, r.trade_date, c.is_trading_day, c.holiday_name
  FROM staging.raw_stock_prices r
  LEFT JOIN ref.trading_calendar c
         ON c.exchange = 'XNYS' AND c.calendar_date = r.trade_date::date
 WHERE c.calendar_date IS NULL          -- outside the calendar window
    OR NOT c.is_trading_day;            -- weekend / holiday


\echo '=== 6. Duplicate business keys (ticker + date) within a batch (expected: 0 rows) ==='
-- HAVING filters groups after aggregation (WHERE filters rows before it).
SELECT ingestion_batch_id, ticker, trade_date, count(*) AS copies
  FROM staging.raw_stock_prices
 GROUP BY ingestion_batch_id, ticker, trade_date
HAVING count(*) > 1;


\echo '=== 7. Parseability of text values (expected: 0 unparseable, report nulls) ==='
-- pg_input_is_valid(text, type) returns false instead of raising an error,
-- which lets us COUNT bad values rather than crash on the first one.
SELECT count(*) FILTER (WHERE NOT pg_input_is_valid(trade_date, 'date'))         AS bad_dates,
       count(*) FILTER (WHERE NOT pg_input_is_valid(open_price, 'numeric')
                           OR NOT pg_input_is_valid(high_price, 'numeric')
                           OR NOT pg_input_is_valid(low_price, 'numeric')
                           OR NOT pg_input_is_valid(close_price, 'numeric')
                           OR NOT pg_input_is_valid(adjusted_close, 'numeric'))  AS bad_prices,
       count(*) FILTER (WHERE NOT pg_input_is_valid(volume, 'bigint'))           AS bad_volumes,
       count(*) FILTER (WHERE close_price IS NULL OR adjusted_close IS NULL
                           OR open_price IS NULL OR high_price IS NULL
                           OR low_price IS NULL OR volume IS NULL)               AS rows_with_nulls,
       count(*) FILTER (WHERE volume = '0')                                      AS zero_volume_rows
  FROM staging.raw_stock_prices;


\echo '=== 8. Lineage: typed columns match the preserved raw payload (expected: 0 mismatches) ==='
-- ->> extracts a jsonb field as text. Comparing as numeric avoids false alarms
-- from formatting differences.
SELECT count(*) AS rows_checked,
       count(*) FILTER (WHERE close_price::numeric    IS DISTINCT FROM (raw_payload->>'Close')::numeric
                           OR adjusted_close::numeric IS DISTINCT FROM (raw_payload->>'Adj Close')::numeric
                           OR volume::numeric         IS DISTINCT FROM (raw_payload->>'Volume')::numeric
                           OR trade_date              IS DISTINCT FROM left(raw_payload->>'Date', 10)) AS mismatches
  FROM staging.raw_stock_prices;


\echo '=== 9. Provider decimal precision (observed, informs Phase 3 rounding rule) ==='
-- scale() = number of digits after the decimal point.
SELECT max(scale(close_price::numeric))                                AS max_close_decimals,
       count(*) FILTER (WHERE scale(close_price::numeric) > 4)          AS closes_with_gt_4_decimals,
       count(*) FILTER (WHERE round(close_price::numeric, 2) <> round(close_price::numeric, 4)) AS closes_not_whole_cents_at_4dp,
       count(*)                                                         AS rows
  FROM staging.raw_stock_prices;


\echo '=== 10. Corporate actions received ==='
SELECT action_type, count(*) AS events, count(DISTINCT ticker) AS tickers,
       min(action_date) AS first_date, max(action_date) AS last_date
  FROM staging.raw_corporate_actions
 GROUP BY action_type;


\echo '=== 11. Adjustment convention check: Adj Close / Close ratio ==='
-- Hypothesis (Yahoo, auto_adjust=False): Close is NOT dividend-adjusted; Adj Close is.
-- If true, ratio = adjusted_close / close_price should:
--   (a) be exactly 1 on the last date (no later dividends to adjust for),
--   (b) stay constant between ex-dividend dates, and
--   (c) step up ON each ex-dividend date by roughly 1 / (1 - dividend / previous close).
-- LAG(x) OVER (PARTITION BY ticker ORDER BY date) = the previous row's x for the same ticker.
WITH ratios AS (
    SELECT ticker,
           trade_date::date AS trade_date,
           close_price::numeric AS close_price,
           adjusted_close::numeric / close_price::numeric AS ratio
      FROM staging.raw_stock_prices
),
changes AS (
    SELECT ticker, trade_date, ratio,
           LAG(ratio)       OVER w AS prev_ratio,
           LAG(close_price) OVER w AS prev_close
      FROM ratios
    WINDOW w AS (PARTITION BY ticker ORDER BY trade_date)
),
ratio_steps AS (     -- days where the ratio moves by more than float noise (1e-5 relative)
    SELECT * FROM changes
     WHERE prev_ratio IS NOT NULL AND abs(ratio / prev_ratio - 1) > 0.00001
),
dividends AS (
    SELECT ticker, action_date::date AS action_date, dividend_amount::numeric AS dividend
      FROM staging.raw_corporate_actions WHERE action_type = 'DIVIDEND'
)
SELECT
    (SELECT count(*) FROM dividends)                                                    AS dividend_events,
    (SELECT count(*) FROM ratio_steps)                                                  AS ratio_step_days,
    (SELECT count(*) FROM ratio_steps s JOIN dividends d
         ON d.ticker = s.ticker AND d.action_date = s.trade_date)                       AS steps_on_ex_dates,
    (SELECT count(*) FROM ratio_steps s LEFT JOIN dividends d
         ON d.ticker = s.ticker AND d.action_date = s.trade_date WHERE d.ticker IS NULL) AS steps_without_dividend,
    (SELECT count(*) FROM dividends d LEFT JOIN ratio_steps s
         ON d.ticker = s.ticker AND d.action_date = s.trade_date WHERE s.ticker IS NULL) AS dividends_without_step,
    (SELECT count(*) FROM ratios r
      WHERE r.trade_date = (SELECT max(trade_date) FROM ratios) AND abs(r.ratio - 1) > 0.000001) AS last_day_ratio_not_1;

\echo '--- 11b. Size of each step vs. the dividend-implied factor (first 10 by ticker/date) ---'
WITH ratios AS (
    SELECT ticker, trade_date::date AS trade_date, close_price::numeric AS close_price,
           adjusted_close::numeric / close_price::numeric AS ratio
      FROM staging.raw_stock_prices
),
changes AS (
    SELECT ticker, trade_date, ratio,
           LAG(ratio)       OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_ratio,
           LAG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date) AS prev_close
      FROM ratios
)
SELECT c.ticker, c.trade_date AS ex_date, d.dividend_amount::numeric AS dividend,
       round(c.prev_close, 2)                                   AS prev_close,
       round(c.ratio / c.prev_ratio, 6)                         AS observed_step,
       round(1 / (1 - d.dividend_amount::numeric / c.prev_close), 6) AS implied_step,
       round(abs(c.ratio / c.prev_ratio - 1 / (1 - d.dividend_amount::numeric / c.prev_close)), 6) AS abs_diff
  FROM changes c
  JOIN staging.raw_corporate_actions d
    ON d.ticker = c.ticker AND d.action_date::date = c.trade_date AND d.action_type = 'DIVIDEND'
 ORDER BY c.ticker, c.trade_date
 LIMIT 10;


\echo '=== 12. Reference data: provider sector vs project-assigned sector ==='
SELECT u.ticker, u.assigned_sector, r.sector AS provider_sector, r.industry, r.exchange, r.currency,
       CASE WHEN r.ticker IS NULL THEN 'MISSING REFERENCE ROW' END AS note
  FROM ref.security_universe u
  LEFT JOIN staging.raw_company_reference r ON r.ticker = u.ticker
 ORDER BY u.assigned_sector, u.ticker;
