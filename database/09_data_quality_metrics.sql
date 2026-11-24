-- =============================================================================
-- 09_data_quality_metrics.sql
-- Purpose : Data quality reporting views (read-only, in the analytics schema).
-- Phase   : 3 — Quality framework
-- Idempotent: yes (CREATE OR REPLACE VIEW)
--
-- METRIC CONVENTIONS (see docs/data_quality_framework.md)
--   * Every percentage = numerator / denominator, both exposed as columns.
--   * Zero denominator -> NULL (shown as N/A), never 0% or 100%.
--   * Record counts and issue counts are reported separately: one record can fail
--     several rules, and one issue can cover several records.
--   * REVIEWABLE_ANOMALY failures are excluded from pass rates and dimension scores:
--     an unusual-but-genuine move is not an error.
--   * Batch metrics describe one load; snapshot metrics describe current production.
-- =============================================================================


-- The PRICES batch that dimension scores are computed for: the most recent validated one.
CREATE OR REPLACE VIEW analytics.v_latest_price_batch AS
SELECT ingestion_batch_id, snapshot_start_date, snapshot_end_date, snapshot_label, start_timestamp
  FROM audit.ingestion_logs
 WHERE batch_type = 'PRICES' AND status IN ('SUCCEEDED', 'PARTIAL') AND validated_at IS NOT NULL
 ORDER BY ingestion_batch_id DESC
 LIMIT 1;


-- -----------------------------------------------------------------------------
-- Per-batch record outcomes and pass rate.
-- record_pass_rate = records with no CONFIRMED_DEFECT failure / records evaluated.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_batch_metrics AS
WITH records AS (
    SELECT r.ingestion_batch_id, o.outcome, coalesce(o.has_confirmed_defect, false) AS has_defect
      FROM staging.raw_stock_prices r
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'PRICE' AND o.raw_id = r.raw_record_id
    UNION ALL
    SELECT r.ingestion_batch_id, o.outcome, coalesce(o.has_confirmed_defect, false)
      FROM staging.raw_corporate_actions r
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'CORPORATE_ACTION' AND o.raw_id = r.raw_action_id
    UNION ALL
    SELECT r.ingestion_batch_id, o.outcome, coalesce(o.has_confirmed_defect, false)
      FROM staging.raw_company_reference r
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'COMPANY_REFERENCE' AND o.raw_id = r.raw_reference_id
),
per_batch AS (
    SELECT ingestion_batch_id,
           count(*)                                                    AS records_evaluated,
           count(*) FILTER (WHERE outcome IS NULL)                     AS clean,
           count(*) FILTER (WHERE outcome = 'ACCEPTED_WITH_FLAGS')     AS accepted_with_flags,
           count(*) FILTER (WHERE outcome = 'QUARANTINED')             AS quarantined,
           count(*) FILTER (WHERE outcome = 'REDUNDANT_DUPLICATE')     AS redundant_duplicates,
           count(*) FILTER (WHERE outcome = 'HELD_FOR_REVIEW')         AS held_for_review,
           count(*) FILTER (WHERE NOT has_defect)                      AS records_without_confirmed_defect
      FROM records
     GROUP BY ingestion_batch_id
)
SELECT l.ingestion_batch_id, l.batch_type, l.status, l.source, l.snapshot_label,
       l.start_timestamp, l.validated_at,
       l.records_received,
       coalesce(p.records_evaluated, 0)          AS records_evaluated,
       coalesce(p.clean, 0)                      AS clean,
       coalesce(p.accepted_with_flags, 0)        AS accepted_with_flags,
       coalesce(p.quarantined, 0)                AS quarantined,
       coalesce(p.redundant_duplicates, 0)       AS redundant_duplicates,
       coalesce(p.held_for_review, 0)            AS held_for_review,
       coalesce(p.records_without_confirmed_defect, 0) AS records_without_confirmed_defect,
       round(100.0 * p.records_without_confirmed_defect / nullif(p.records_evaluated, 0), 2) AS record_pass_rate_pct
  FROM audit.ingestion_logs l
  LEFT JOIN per_batch p USING (ingestion_batch_id)
 WHERE l.batch_type <> 'TRADING_CALENDAR';

COMMENT ON VIEW analytics.v_dq_batch_metrics IS
  'Per batch: record outcomes and record pass rate = records without confirmed defects / records evaluated (anomalies excluded).';


-- -----------------------------------------------------------------------------
-- Dimension scores for the latest PRICES batch.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_dimension_scores AS
WITH b AS (SELECT * FROM analytics.v_latest_price_batch),
evaluated AS (
    SELECT r.raw_record_id FROM staging.raw_stock_prices r JOIN b USING (ingestion_batch_id)
),
defects AS (     -- confirmed-defect failures of evaluated price records, by dimension
    SELECT DISTINCT f.raw_record_id, d.rule_category
      FROM audit.rule_failures f
      JOIN audit.data_quality_rules d ON d.rule_id = f.rule_id
      JOIN evaluated e ON e.raw_record_id = f.raw_record_id
     WHERE d.issue_class = 'CONFIRMED_DEFECT'
),
requested AS (
    SELECT coalesce((SELECT array_agg(x) FROM jsonb_array_elements_text(l.retrieval_parameters -> 'tickers_requested') x),
                    (SELECT array_agg(ticker) FROM ref.security_universe WHERE is_active)) AS tickers
      FROM audit.ingestion_logs l JOIN b USING (ingestion_batch_id)
),
expected_sessions AS (
    SELECT t.ticker, c.calendar_date
      FROM requested, unnest(requested.tickers) AS t(ticker)
     CROSS JOIN b
      JOIN ref.trading_calendar c ON c.exchange = 'XNYS' AND c.is_trading_day
                                 AND c.calendar_date BETWEEN b.snapshot_start_date AND b.snapshot_end_date
),
received_sessions AS (
    SELECT DISTINCT t.ticker, t.trade_date_value
      FROM staging.v_raw_stock_prices_typed t JOIN b USING (ingestion_batch_id)
),
latest AS (
    SELECT max(calendar_date) AS last_session FROM expected_sessions
),
n AS (SELECT count(*) AS evaluated FROM evaluated)
SELECT dimension, scope, numerator, denominator,
       round(100.0 * numerator / nullif(denominator, 0), 2) AS score_pct,
       definition
  FROM (
    SELECT 1 AS ord, 'COMPLETENESS' AS dimension, 'records' AS scope,
           n.evaluated - (SELECT count(*) FROM defects WHERE rule_category = 'COMPLETENESS') AS numerator,
           n.evaluated AS denominator,
           'Received records with no confirmed completeness defect / received records' AS definition
      FROM n
    UNION ALL
    SELECT 2, 'COMPLETENESS', 'expected sessions',
           (SELECT count(*) FROM expected_sessions e JOIN received_sessions r
                 ON r.ticker = e.ticker AND r.trade_date_value = e.calendar_date),
           (SELECT count(*) FROM expected_sessions),
           'Expected (ticker, XNYS session) pairs with at least one raw record / expected pairs. Absent records cannot be counted as raw rows, so this is reported separately.'
    UNION ALL
    SELECT 3, 'UNIQUENESS', 'records',
           n.evaluated - (SELECT count(*) FROM defects WHERE rule_category = 'UNIQUENESS'), n.evaluated,
           'Received records not involved in a duplicate defect / received records'
      FROM n
    UNION ALL
    SELECT 4, 'VALIDITY', 'records',
           n.evaluated - (SELECT count(*) FROM defects WHERE rule_category = 'VALIDITY'), n.evaluated,
           'Received records with no validity defect / received records'
      FROM n
    UNION ALL
    SELECT 5, 'CONSISTENCY', 'records',
           n.evaluated - (SELECT count(*) FROM defects WHERE rule_category = 'CONSISTENCY'), n.evaluated,
           'Received records with no confirmed consistency defect / received records (reviewable conflicts excluded)'
      FROM n
    UNION ALL
    SELECT 6, 'TIMELINESS', 'requested tickers',
           (SELECT count(DISTINCT e.ticker) FROM expected_sessions e JOIN latest ON e.calendar_date = latest.last_session
              JOIN received_sessions r ON r.ticker = e.ticker AND r.trade_date_value = e.calendar_date),
           (SELECT count(DISTINCT ticker) FROM expected_sessions),
           'Requested tickers with a record for the last expected session on/before the snapshot cutoff / requested tickers'
    UNION ALL
    SELECT 7, 'OVERALL', 'records',
           n.evaluated - (SELECT count(DISTINCT raw_record_id) FROM defects), n.evaluated,
           'Record pass rate: received records with no confirmed defect in any dimension / received records'
      FROM n
  ) s
 ORDER BY ord;

COMMENT ON VIEW analytics.v_dq_dimension_scores IS
  'Quality dimension scores for the latest validated PRICES batch, with numerator, denominator and definition.';


-- -----------------------------------------------------------------------------
-- Field completeness (latest PRICES batch): present AND parseable / evaluated.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_field_completeness AS
SELECT f.field_name,
       count(*)                                                       AS records_evaluated,
       count(*) FILTER (WHERE NOT staging.is_blank(f.raw_value))      AS present,
       count(*) FILTER (WHERE f.numeric_value IS NOT NULL)            AS present_and_parseable,
       round(100.0 * count(*) FILTER (WHERE f.numeric_value IS NOT NULL) / nullif(count(*), 0), 2) AS completeness_pct
  FROM staging.v_raw_price_fields f
  JOIN analytics.v_latest_price_batch b USING (ingestion_batch_id)
 GROUP BY f.field_name;


-- -----------------------------------------------------------------------------
-- Rule-level view: catalogue + how often each rule fired.
-- failing_records = distinct raw records; issues = distinct issue rows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_rule_results AS
SELECT r.rule_id, r.rule_name, r.rule_category, r.severity, r.issue_class, r.handling, r.threshold_value,
       r.rule_description, r.expected_condition, r.business_justification,
       (SELECT count(DISTINCT coalesce(f.raw_record_id, f.raw_action_id, f.raw_reference_id))
          FROM audit.rule_failures f WHERE f.rule_id = r.rule_id)                              AS failing_records,
       (SELECT count(*) FROM audit.data_quality_issues i WHERE i.rule_id = r.rule_id)          AS issues_total,
       (SELECT count(*) FROM audit.data_quality_issues i
         WHERE i.rule_id = r.rule_id AND i.status IN ('OPEN', 'UNDER_REVIEW'))                 AS issues_unresolved
  FROM audit.data_quality_rules r
 WHERE r.is_active;


-- -----------------------------------------------------------------------------
-- Issue counts by class, severity and status (issues, not records).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_issue_summary AS
SELECT r.issue_class, i.severity, i.status, count(*) AS issues,
       count(DISTINCT i.ticker) AS tickers_affected
  FROM audit.data_quality_issues i
  JOIN audit.data_quality_rules r USING (rule_id)
 GROUP BY r.issue_class, i.severity, i.status;


-- -----------------------------------------------------------------------------
-- Issue list for the dashboard (filterable), with rule explanation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_issues AS
SELECT i.issue_id, i.ticker, i.trade_date, i.rule_id, r.rule_name, r.rule_category, r.issue_class,
       i.affected_field, i.observed_value, i.expected_condition, i.severity, i.status, r.handling,
       i.detected_at, i.last_detected_at, i.detection_count, i.resolved_at, i.resolution_notes,
       i.ingestion_batch_id, i.last_detected_batch_id,
       (SELECT count(*) FROM audit.rule_failures f WHERE f.issue_id = i.issue_id) AS affected_records,
       r.rule_description, r.business_justification
  FROM audit.data_quality_issues i
  JOIN audit.data_quality_rules r USING (rule_id);


-- -----------------------------------------------------------------------------
-- Quarantine: raw records NOT promoted because of a critical (QUARANTINE) failure.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_quarantined_records AS
SELECT o.record_kind, o.raw_id, r.ingestion_batch_id, r.ticker, r.trade_date AS record_date,
       o.failed_rules, o.failure_count,
       concat_ws(' | ', 'O ' || audit.show_value(r.open_price), 'H ' || audit.show_value(r.high_price),
                 'L ' || audit.show_value(r.low_price), 'C ' || audit.show_value(r.close_price),
                 'AC ' || audit.show_value(r.adjusted_close), 'V ' || audit.show_value(r.volume)) AS raw_values
  FROM audit.v_record_outcomes o
  JOIN staging.raw_stock_prices r ON o.record_kind = 'PRICE' AND r.raw_record_id = o.raw_id
 WHERE o.outcome = 'QUARANTINED'
UNION ALL
SELECT o.record_kind, o.raw_id, a.ingestion_batch_id, a.ticker, a.action_date,
       o.failed_rules, o.failure_count,
       concat_ws(' | ', a.action_type, 'amount ' || audit.show_value(a.dividend_amount),
                 'ratio ' || audit.show_value(a.split_ratio))
  FROM audit.v_record_outcomes o
  JOIN staging.raw_corporate_actions a ON o.record_kind = 'CORPORATE_ACTION' AND a.raw_action_id = o.raw_id
 WHERE o.outcome = 'QUARANTINED'
UNION ALL
SELECT o.record_kind, o.raw_id, c.ingestion_batch_id, c.ticker, NULL,
       o.failed_rules, o.failure_count,
       concat_ws(' | ', c.company_name, c.exchange, c.currency)
  FROM audit.v_record_outcomes o
  JOIN staging.raw_company_reference c ON o.record_kind = 'COMPANY_REFERENCE' AND c.raw_reference_id = o.raw_id
 WHERE o.outcome = 'QUARANTINED';


-- -----------------------------------------------------------------------------
-- Snapshot (production) summary: current state of validated data.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_dq_snapshot_summary AS
WITH b AS (SELECT * FROM analytics.v_latest_price_batch),
expected AS (
    SELECT count(*) * (SELECT count(*) FROM ref.security_universe WHERE is_active) AS n
      FROM ref.trading_calendar c, b
     WHERE c.exchange = 'XNYS' AND c.is_trading_day
       AND c.calendar_date BETWEEN b.snapshot_start_date AND b.snapshot_end_date
),
validated AS (
    SELECT count(*) AS n FROM core.stock_prices p, b
     WHERE p.trade_date BETWEEN b.snapshot_start_date AND b.snapshot_end_date
)
SELECT b.snapshot_start_date, b.snapshot_end_date, b.snapshot_label,
       (SELECT count(*) FROM core.companies)                                  AS validated_companies,
       (SELECT count(DISTINCT sector) FROM core.companies)                    AS sectors,
       (SELECT count(*) FROM staging.raw_stock_prices)                        AS raw_price_records_all_batches,
       validated.n                                                            AS validated_price_records,
       expected.n                                                             AS expected_price_records,
       round(100.0 * validated.n / nullif(expected.n, 0), 2)                  AS validated_coverage_pct,
       (SELECT count(*) FROM core.corporate_actions)                          AS validated_corporate_actions,
       (SELECT count(*) FROM analytics.v_quarantined_records)                 AS quarantined_records,
       (SELECT count(*) FROM audit.data_quality_issues i JOIN audit.data_quality_rules r USING (rule_id)
         WHERE r.issue_class = 'CONFIRMED_DEFECT' AND i.status IN ('OPEN','UNDER_REVIEW'))  AS open_confirmed_defect_issues,
       (SELECT count(*) FROM audit.data_quality_issues i JOIN audit.data_quality_rules r USING (rule_id)
         WHERE r.issue_class = 'REVIEWABLE_ANOMALY' AND i.status IN ('OPEN','UNDER_REVIEW')) AS open_anomaly_issues,
       (SELECT max(start_timestamp) FROM audit.ingestion_logs WHERE status IN ('SUCCEEDED','PARTIAL')) AS last_ingestion
  FROM b, expected, validated;

COMMENT ON VIEW analytics.v_dq_snapshot_summary IS
  'Production snapshot: validated records vs expected (universe x sessions), quarantine and open issue counts.';
