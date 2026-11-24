-- title: Daily returns with LAG — hand-checkable
-- category: Equity analysis
-- objective: Show how a one-session return is computed from the previous session's adjusted close, with the inputs visible for manual checking.
-- concepts: LAG() OVER (PARTITION BY ... ORDER BY ...), CASE, NULLIF, gap detection via session numbers
-- expected_output: The latest 10 sessions for AAPL: previous and current adjusted close, return type and one-session return %.
-- assumptions: Adjusted close basis. return_type MULTI_SESSION means a gap: no daily return is reported for that row.
SELECT ticker, trade_date, prev_trade_date, sessions_elapsed, return_type,
       prev_adjusted_close, adjusted_close,
       round(daily_return_pct, 4)       AS daily_return_pct,
       round(daily_price_return_pct, 4) AS daily_price_return_pct,
       -- hand check: (adjusted_close / prev_adjusted_close - 1) * 100
       round((adjusted_close / nullif(prev_adjusted_close, 0) - 1) * 100, 4) AS manual_check_pct
  FROM analytics.v_daily_returns
 WHERE ticker = 'AAPL'
 ORDER BY trade_date DESC
 LIMIT 10;
