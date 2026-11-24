-- title: Sector analysis — equal-weight returns, volatility and volume
-- category: Sector analysis
-- objective: Compare the five sectors using equal-weight constituent returns, sector index volatility and average traded volume.
-- concepts: aggregation of aggregates (view over views), array_agg ORDER BY, RANK, LEFT JOIN on USING
-- expected_output: One row per sector ranked by equal-weight return.
-- assumptions: Equal-weight buy-and-hold of the 4 selected companies per sector — NOT an official sector index. Sector volatility = annualised sd of the equal-weight index's daily returns.
SELECT rank_return, sector, constituents,
       round(equal_weight_return_pct, 2)        AS equal_weight_return_pct,
       round(equal_weight_price_return_pct, 2)  AS equal_weight_price_return_pct,
       best_constituent,  round(best_constituent_return_pct, 2)  AS best_return_pct,
       worst_constituent, round(worst_constituent_return_pct, 2) AS worst_return_pct,
       round(sector_volatility_pct, 2)          AS sector_volatility_pct,
       round(avg_constituent_volatility_pct, 2) AS avg_constituent_volatility_pct,
       avg_constituent_daily_volume
  FROM analytics.v_sector_performance
 ORDER BY rank_return
 LIMIT 10;
