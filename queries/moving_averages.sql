-- title: 20- and 50-session moving averages — latest position per security
-- category: Equity analysis
-- objective: Compare each security's latest adjusted close with its 20- and 50-session simple moving averages.
-- concepts: window frame (ROWS BETWEEN n PRECEDING AND CURRENT ROW), DISTINCT ON, CASE classification
-- expected_output: One row per security: latest price, SMA20, SMA50, % distance from each and trend label.
-- assumptions: Adjusted close basis; SMA is NULL until 20/50 observations exist; sessions_spanned > observations would indicate a data gap in the window.
SELECT DISTINCT ON (ticker)
       ticker, trade_date, adjusted_close,
       round(sma_20, 2) AS sma_20, round(sma_50, 2) AS sma_50,
       obs_20, sessions_spanned_20, obs_50, sessions_spanned_50,
       round((adjusted_close / nullif(sma_20, 0) - 1) * 100, 2) AS pct_vs_sma_20,
       round((adjusted_close / nullif(sma_50, 0) - 1) * 100, 2) AS pct_vs_sma_50,
       CASE WHEN sma_20 IS NULL OR sma_50 IS NULL THEN 'INSUFFICIENT DATA'
            WHEN sma_20 > sma_50 AND adjusted_close > sma_20 THEN 'ABOVE BOTH, SHORT > LONG'
            WHEN sma_20 < sma_50 AND adjusted_close < sma_20 THEN 'BELOW BOTH, SHORT < LONG'
            ELSE 'MIXED' END AS trend_position
  FROM analytics.v_moving_averages
 ORDER BY ticker, trade_date DESC
 LIMIT 50;
