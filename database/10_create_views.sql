-- =============================================================================
-- 10_create_views.sql
-- Purpose : Presentation views consumed by the read-only API / dashboard.
-- Phase   : 5 — Backend
-- Idempotent: yes (CREATE OR REPLACE VIEW)
--
-- These views only COMBINE existing quality (09) and analytics (08) views into the
-- shapes the dashboard needs. They add no new business logic, so every number shown
-- in the UI traces back to the documented SQL definitions.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Overview headline figures (one row). Source and as-of dates are always included so
-- the dashboard never shows a number without its provenance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_overview_kpis AS
SELECT (SELECT count(*) FROM ref.security_universe WHERE is_active)           AS tracked_securities,
       (SELECT count(DISTINCT assigned_sector) FROM ref.security_universe
         WHERE is_active)                                                     AS sectors,
       s.validated_companies,
       s.raw_price_records_all_batches                                        AS market_records,
       s.validated_price_records,
       s.expected_price_records,
       s.validated_coverage_pct,
       (SELECT score_pct FROM analytics.v_dq_dimension_scores WHERE dimension = 'OVERALL') AS record_pass_rate_pct,
       s.quarantined_records,
       s.open_confirmed_defect_issues,
       s.open_anomaly_issues,
       s.validated_corporate_actions,
       s.last_ingestion,
       s.snapshot_start_date                                                  AS as_of_start_date,
       s.snapshot_end_date                                                    AS as_of_end_date,
       s.snapshot_label,
       (SELECT string_agg(DISTINCT source, ', ') FROM core.companies)         AS source
  FROM analytics.v_dq_snapshot_summary s;


-- -----------------------------------------------------------------------------
-- Securities table: one row per tracked security (universe LEFT JOIN, so a security
-- whose data failed validation is still listed with status NOT VALIDATED).
-- quality_status: DEFECTS (open confirmed defects) > REVIEW (open anomalies) > PASSED.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_security_overview AS
WITH latest AS (
    SELECT DISTINCT ON (company_id) company_id, trade_date, close_price, adjusted_close, daily_return_pct
      FROM analytics.v_daily_returns
     ORDER BY company_id, trade_date DESC
),
issues AS (
    SELECT i.ticker,
           count(*) FILTER (WHERE r.issue_class = 'CONFIRMED_DEFECT'   AND i.status IN ('OPEN', 'UNDER_REVIEW')) AS open_defects,
           count(*) FILTER (WHERE r.issue_class = 'REVIEWABLE_ANOMALY' AND i.status IN ('OPEN', 'UNDER_REVIEW')) AS open_anomalies
      FROM audit.data_quality_issues i JOIN audit.data_quality_rules r USING (rule_id)
     GROUP BY i.ticker
),
quarantine AS (
    SELECT ticker, count(*) AS quarantined_records FROM analytics.v_quarantined_records GROUP BY ticker
)
SELECT u.ticker,
       c.company_name, u.assigned_sector AS sector, c.provider_sector, c.industry, c.exchange, c.currency,
       l.trade_date                       AS latest_trade_date,
       l.close_price                      AS latest_close,
       l.daily_return_pct                 AS latest_daily_return_pct,
       p.adjusted_return_pct              AS period_adjusted_return_pct,
       p.price_return_pct                 AS period_price_return_pct,
       vs.avg_daily_volume,
       v.annualised_volatility_pct,
       coalesce(i.open_defects, 0)        AS open_defect_issues,
       coalesce(i.open_anomalies, 0)      AS open_anomaly_issues,
       coalesce(q.quarantined_records, 0) AS quarantined_records,
       CASE WHEN c.company_id IS NULL                 THEN 'NOT VALIDATED'
            WHEN coalesce(i.open_defects, 0) > 0      THEN 'DEFECTS'
            WHEN coalesce(i.open_anomalies, 0) > 0    THEN 'REVIEW'
            ELSE 'PASSED' END             AS quality_status
  FROM ref.security_universe u
  LEFT JOIN core.companies c                   ON c.ticker = u.ticker
  LEFT JOIN latest l                           ON l.company_id = c.company_id
  LEFT JOIN analytics.v_security_performance p ON p.company_id = c.company_id
  LEFT JOIN analytics.v_volatility v           ON v.company_id = c.company_id
  LEFT JOIN analytics.v_volume_summary vs      ON vs.ticker = u.ticker
  LEFT JOIN issues i                           ON i.ticker = u.ticker
  LEFT JOIN quarantine q                       ON q.ticker = u.ticker
 WHERE u.is_active;


-- -----------------------------------------------------------------------------
-- Price series for charts: prices, moving averages and volume in one row per day.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_price_chart AS
SELECT d.ticker, d.trade_date, d.open_price, d.high_price, d.low_price, d.close_price, d.adjusted_close,
       d.volume, d.daily_return_pct, d.return_type,
       m.sma_20, m.sma_50, va.volume_ratio, va.is_unusual_volume
  FROM analytics.v_daily_returns d
  JOIN analytics.v_moving_averages m  ON m.company_id = d.company_id AND m.trade_date = d.trade_date
  JOIN analytics.v_volume_analysis va ON va.raw_record_id = d.raw_record_id;


-- -----------------------------------------------------------------------------
-- Ingestion history with outcome counts and duration.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_ingestion_history AS
SELECT l.ingestion_batch_id, l.batch_type, l.source, l.status, l.snapshot_label,
       l.snapshot_start_date, l.snapshot_end_date,
       l.start_timestamp, l.end_timestamp,
       round(extract(epoch FROM l.end_timestamp - l.start_timestamp)::numeric, 3) AS load_seconds,
       l.validated_at,
       l.records_received, l.records_accepted, l.records_rejected, l.records_flagged,
       m.redundant_duplicates, m.held_for_review, m.record_pass_rate_pct,
       left(l.source_checksum, 12) AS checksum_prefix,
       l.retrieval_parameters -> 'request_parameters' AS request_parameters,
       l.error_message
  FROM audit.ingestion_logs l
  LEFT JOIN analytics.v_dq_batch_metrics m USING (ingestion_batch_id);


-- -----------------------------------------------------------------------------
-- Price lineage: production record -> raw provider text -> batch -> source request.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_price_lineage AS
SELECT c.ticker, p.trade_date, p.price_id,
       p.open_price, p.high_price, p.low_price, p.close_price, p.adjusted_close, p.volume,
       r.raw_record_id,
       r.open_price AS raw_open, r.high_price AS raw_high, r.low_price AS raw_low,
       r.close_price AS raw_close, r.adjusted_close AS raw_adjusted_close, r.volume AS raw_volume,
       r.raw_payload,
       r.ingestion_timestamp,
       l.ingestion_batch_id, l.source, l.snapshot_label, l.source_checksum,
       l.retrieval_parameters,
       (SELECT coalesce(jsonb_agg(jsonb_build_object('issue_id', i.issue_id, 'rule_id', i.rule_id,
                                                     'status', i.status, 'observed_value', i.observed_value)
                                  ORDER BY i.rule_id), '[]'::jsonb)
          FROM audit.data_quality_issues i WHERE i.raw_record_id = r.raw_record_id) AS issues
  FROM core.stock_prices p
  JOIN core.companies c           ON c.company_id = p.company_id
  JOIN staging.raw_stock_prices r ON r.raw_record_id = p.raw_record_id
  JOIN audit.ingestion_logs l     ON l.ingestion_batch_id = r.ingestion_batch_id;
