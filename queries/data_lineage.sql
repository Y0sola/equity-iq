-- title: Data lineage — trace a validated price back to its source
-- category: Database
-- objective: Prove any published number can be traced to the exact raw record, the ingestion batch, the source request and any quality issues.
-- concepts: INNER JOIN chain, LEFT JOIN, jsonb operators (->, ->>), subquery, string_agg
-- expected_output: The largest one-session moves, each with production values, the raw provider text, batch metadata and linked issue rules.
-- assumptions: Shows the 5 largest absolute one-session moves; lineage key is core.stock_prices.raw_record_id.
SELECT c.ticker,
       p.trade_date,
       round(d.daily_return_pct, 2)                         AS daily_return_pct,
       p.close_price                                        AS production_close,
       r.close_price                                        AS raw_close_as_received,
       r.raw_payload ->> 'Adj Close'                        AS raw_payload_adj_close,
       r.raw_record_id,
       l.ingestion_batch_id,
       l.source,
       l.snapshot_label,
       l.retrieval_parameters -> 'request_parameters' ->> 'auto_adjust' AS auto_adjust_setting,
       l.start_timestamp                                    AS loaded_at,
       (SELECT string_agg(i.rule_id || ' ' || i.status, ', ' ORDER BY i.rule_id)
          FROM audit.data_quality_issues i
         WHERE i.raw_record_id = r.raw_record_id)           AS quality_issues
  FROM core.stock_prices p
  JOIN core.companies c           ON c.company_id = p.company_id
  JOIN analytics.v_daily_returns d ON d.price_id = p.price_id
  JOIN staging.raw_stock_prices r ON r.raw_record_id = p.raw_record_id
  JOIN audit.ingestion_logs l     ON l.ingestion_batch_id = r.ingestion_batch_id
 WHERE d.daily_return_pct IS NOT NULL
 ORDER BY abs(d.daily_return_pct) DESC
 LIMIT 5;
