-- title: Completeness — expected trading sessions vs records received, per security
-- category: Data quality
-- objective: Measure whether every security has a record for every exchange trading session, without counting weekends or holidays as missing.
-- concepts: CROSS JOIN (expected pairs), LEFT JOIN anti-join, GROUP BY, aggregate FILTER, NULLIF (zero denominator)
-- expected_output: One row per security: expected sessions, sessions received in staging, sessions validated in core, coverage percentages.
-- assumptions: Expected = active universe x XNYS sessions between the latest price batch's snapshot start and end dates.
WITH b AS (SELECT * FROM analytics.v_latest_price_batch),
expected AS (
    SELECT u.ticker, c.calendar_date
      FROM ref.security_universe u
     CROSS JOIN b
      JOIN ref.trading_calendar c
        ON c.exchange = 'XNYS' AND c.is_trading_day
       AND c.calendar_date BETWEEN b.snapshot_start_date AND b.snapshot_end_date
     WHERE u.is_active
),
received AS (
    SELECT DISTINCT ticker, trade_date_value FROM staging.v_raw_stock_prices_typed
),
validated AS (
    SELECT c.ticker, p.trade_date FROM core.stock_prices p JOIN core.companies c USING (company_id)
)
SELECT e.ticker,
       count(*)                                                     AS expected_sessions,
       count(r.ticker)                                              AS sessions_received,
       count(v.ticker)                                              AS sessions_validated,
       count(*) - count(r.ticker)                                   AS sessions_missing,
       round(100.0 * count(r.ticker) / nullif(count(*), 0), 2)      AS received_coverage_pct,
       round(100.0 * count(v.ticker) / nullif(count(*), 0), 2)      AS validated_coverage_pct
  FROM expected e
  LEFT JOIN received  r ON r.ticker = e.ticker AND r.trade_date_value = e.calendar_date
  LEFT JOIN validated v ON v.ticker = e.ticker AND v.trade_date = e.calendar_date
 GROUP BY e.ticker
 ORDER BY sessions_missing DESC, e.ticker
 LIMIT 50;
