-- title: OHLC consistency profile per security
-- category: Data quality
-- objective: Confirm validated prices respect high >= open/close >= low and profile how often the close sits exactly at the day's high or low.
-- concepts: aggregate FILTER, CASE, GROUP BY, NULLIF, ratio arithmetic
-- expected_output: One row per security: records, violations (expected 0 in core), closes at high/low, average intraday range %.
-- assumptions: Runs on core (validated) data, where CHECK constraints already forbid violations; violations column demonstrates that guarantee.
SELECT c.ticker,
       count(*)                                                                    AS records,
       count(*) FILTER (WHERE p.high_price < p.low_price
                           OR p.open_price  NOT BETWEEN p.low_price AND p.high_price
                           OR p.close_price NOT BETWEEN p.low_price AND p.high_price) AS ohlc_violations,
       count(*) FILTER (WHERE p.close_price = p.high_price)                        AS closes_at_high,
       count(*) FILTER (WHERE p.close_price = p.low_price)                         AS closes_at_low,
       round(avg((p.high_price - p.low_price) / nullif(p.low_price, 0)) * 100, 2)  AS avg_intraday_range_pct
  FROM core.stock_prices p
  JOIN core.companies c USING (company_id)
 GROUP BY c.ticker
 ORDER BY avg_intraday_range_pct DESC
 LIMIT 50;
