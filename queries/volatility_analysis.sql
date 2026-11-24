-- title: Volatility — daily and annualised
-- category: Equity analysis
-- objective: Measure how much each security's daily returns vary, and annualise for comparison.
-- concepts: stddev_samp aggregate, minimum-sample CASE, RANK, numeric sqrt
-- expected_output: One row per security: returns used, excluded multi-session returns, daily and annualised volatility, best/worst day.
-- assumptions: Sample standard deviation of one-session adjusted returns; annualised x sqrt(252); NULL if fewer than 20 returns.
SELECT rank_most_volatile, ticker, sector,
       daily_returns_used, multi_session_returns_excluded,
       round(mean_daily_return_pct, 4)     AS mean_daily_return_pct,
       round(daily_volatility_pct, 4)      AS daily_volatility_pct,
       round(annualised_volatility_pct, 2) AS annualised_volatility_pct,
       round(worst_daily_return_pct, 2)    AS worst_day_pct,
       round(best_daily_return_pct, 2)     AS best_day_pct
  FROM analytics.v_volatility
 ORDER BY rank_most_volatile
 LIMIT 50;
