-- title: Duplicate detection — repeated business keys across all raw batches
-- category: Data quality
-- objective: Find ticker/date combinations delivered more than once, and distinguish identical re-deliveries from conflicting values.
-- concepts: CTE, GROUP BY, HAVING, COUNT(DISTINCT row), CASE, array_agg
-- expected_output: One row per repeated ticker/date with number of copies, batches involved and whether the copies agree. Empty result = no duplicates.
-- assumptions: Compares parsed values (so '100' and '100.0' are identical). Within-batch duplicates are also reported as rules DQ-UNI-001/002.
WITH keyed AS (
    SELECT ticker, trade_date_value, ingestion_batch_id,
           (open_value, high_value, low_value, close_value, adjusted_close_value, volume_value) AS record_values
      FROM staging.v_raw_stock_prices_typed
     WHERE ticker IS NOT NULL AND trade_date_value IS NOT NULL
)
SELECT ticker,
       trade_date_value                                    AS trade_date,
       count(*)                                            AS copies,
       count(DISTINCT ingestion_batch_id)                  AS batches,
       array_agg(DISTINCT ingestion_batch_id)              AS batch_ids,
       count(DISTINCT record_values)                       AS distinct_versions,
       CASE WHEN count(DISTINCT record_values) = 1 THEN 'IDENTICAL' ELSE 'CONFLICTING' END AS duplicate_type
  FROM keyed
 GROUP BY ticker, trade_date_value
HAVING count(*) > 1
 ORDER BY distinct_versions DESC, ticker, trade_date
 LIMIT 100;
