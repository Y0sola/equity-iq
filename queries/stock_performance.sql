-- title: Security performance ranking over the snapshot
-- category: Equity analysis
-- objective: Rank securities by adjusted-price performance and show price return, dividends, highs/lows and maximum drawdown.
-- concepts: RANK() OVER, RANK() OVER (PARTITION BY sector), FILTER aggregates, running max window (drawdown)
-- expected_output: One row per security ranked best to worst.
-- assumptions: Window = first to last common date. adjusted_return_pct is adjusted-price performance, not a precise total return; approx_total_return_pct adds dividends without reinvestment.
SELECT rank_overall, ticker, sector, rank_in_sector,
       base_date, end_date,
       round(adjusted_return_pct, 2)     AS adjusted_return_pct,
       round(price_return_pct, 2)        AS price_return_pct,
       dividends_per_share,
       round(approx_total_return_pct, 2) AS approx_total_return_pct,
       highest_close, highest_close_date, lowest_close, lowest_close_date,
       round(max_drawdown_pct, 2)        AS max_drawdown_pct
  FROM analytics.v_security_performance
 ORDER BY rank_overall
 LIMIT 50;
