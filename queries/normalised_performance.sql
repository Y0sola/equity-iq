-- title: Normalised performance (base 100) — month-end snapshot
-- category: Equity analysis
-- objective: Compare securities on one scale by rebasing each adjusted close to 100 on the first common comparison date.
-- concepts: CROSS JOIN to a one-row view, date_trunc, DISTINCT ON, ROW_NUMBER for last date per month
-- expected_output: Normalised value per security at each month's last trading date (plus the base date).
-- assumptions: Base date = first date on which every validated company has a price; adjusted close basis.
WITH month_end AS (
    SELECT ticker, trade_date, normalised_value,
           row_number() OVER (PARTITION BY ticker, date_trunc('month', trade_date) ORDER BY trade_date DESC) AS rn
      FROM analytics.v_normalised_performance
)
SELECT ticker, trade_date, round(normalised_value, 2) AS normalised_value
  FROM month_end
 WHERE rn = 1 OR trade_date = (SELECT base_date FROM analytics.v_analysis_window)
 ORDER BY ticker, trade_date
 LIMIT 400;
