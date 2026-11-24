-- title: Volume analysis — averages and unusual trading days
-- category: Equity analysis
-- objective: Summarise average daily volume per security and count days with unusually high volume versus the trailing average.
-- concepts: percentile_cont WITHIN GROUP (median), window frame excluding current row (no look-ahead), JOIN
-- expected_output: One row per security: average, median and max volume, unusual-volume days and the date of the biggest spike.
-- assumptions: Unusual = volume > 3x the average of the previous 20 records (same threshold as rule DQ-ANO-002).
SELECT s.ticker, s.sector, s.trading_days, s.avg_daily_volume,
       round(s.median_daily_volume) AS median_daily_volume, s.max_daily_volume, s.unusual_volume_days,
       (SELECT v.trade_date FROM analytics.v_volume_analysis v
         WHERE v.ticker = s.ticker AND v.volume_ratio IS NOT NULL
         ORDER BY v.volume_ratio DESC LIMIT 1) AS biggest_spike_date,
       (SELECT round(max(v.volume_ratio), 1) FROM analytics.v_volume_analysis v WHERE v.ticker = s.ticker) AS biggest_spike_ratio
  FROM analytics.v_volume_summary s
 ORDER BY s.avg_daily_volume DESC
 LIMIT 50;
