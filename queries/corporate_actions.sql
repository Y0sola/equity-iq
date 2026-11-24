-- title: Corporate actions — dividends and price behaviour on ex-dates
-- category: Corporate actions
-- objective: Show each dividend or split with the reported vs adjusted return on the ex-date and the dividend yield, to illustrate how adjustment works.
-- concepts: LEFT JOIN, correlated subquery, CASE, view reuse (v_daily_returns)
-- expected_output: One row per validated corporate action, most recent first.
-- assumptions: Descriptive only — no causal claims. reported_minus_adjusted_pct should be close to minus the dividend yield.
SELECT ticker, sector, action_date, action_type, dividend_amount, split_ratio,
       prev_close_price, ex_date_close,
       round(reported_return_pct, 3)              AS reported_return_pct,
       round(adjusted_return_pct, 3)              AS adjusted_return_pct,
       round(reported_minus_adjusted_pct, 3)      AS reported_minus_adjusted_pct,
       round(dividend_yield_on_prev_close_pct, 3) AS dividend_yield_pct,
       round(max_abs_adjusted_move_pm2_pct, 2)    AS max_abs_move_pm2_sessions_pct,
       significant_move_nearby
  FROM analytics.v_corporate_action_impact
 ORDER BY action_date DESC, ticker
 LIMIT 100;
