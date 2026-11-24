-- =============================================================================
-- 03_create_indexes.sql
-- Purpose : Secondary indexes for the most common lookups.
-- Phase   : 1 — Database architecture
-- Idempotent: yes
--
-- WHAT IS AN INDEX?
--   Like the index at the back of a book: instead of reading every row to find
--   AAPL's prices, PostgreSQL jumps straight to them. Primary keys and UNIQUE
--   constraints already create an index automatically, so we only add indexes
--   for other frequent filters and joins. Each index speeds up reads but adds a
--   small cost to every insert, so we keep the list deliberate.
--
-- Already indexed automatically (no action needed):
--   core.stock_prices (company_id, trade_date)   via uq_stock_prices_company_date
--   core.stock_prices (raw_record_id)            via uq_stock_prices_raw_record (lineage lookups)
--   core.corporate_actions (company_id, action_date, action_type) via unique constraint
--   ref.trading_calendar (exchange, calendar_date) via primary key
--   audit.data_quality_issues (issue_key)        via unique constraint
-- =============================================================================

-- Staging: validation rules group raw rows by business key to find duplicates,
-- and pipeline steps select all rows from one batch.
CREATE INDEX IF NOT EXISTS ix_raw_prices_ticker_date   ON staging.raw_stock_prices (ticker, trade_date);
CREATE INDEX IF NOT EXISTS ix_raw_prices_batch         ON staging.raw_stock_prices (ingestion_batch_id);
CREATE INDEX IF NOT EXISTS ix_raw_actions_ticker_date  ON staging.raw_corporate_actions (ticker, action_date);
CREATE INDEX IF NOT EXISTS ix_raw_actions_batch        ON staging.raw_corporate_actions (ingestion_batch_id);
CREATE INDEX IF NOT EXISTS ix_raw_reference_ticker     ON staging.raw_company_reference (ticker);
CREATE INDEX IF NOT EXISTS ix_raw_reference_batch      ON staging.raw_company_reference (ingestion_batch_id);

-- Core: cross-sectional queries ("all securities on date X") filter on trade_date alone,
-- which the (company_id, trade_date) index cannot serve efficiently.
CREATE INDEX IF NOT EXISTS ix_stock_prices_trade_date  ON core.stock_prices (trade_date);
CREATE INDEX IF NOT EXISTS ix_corp_actions_date        ON core.corporate_actions (action_date);
CREATE INDEX IF NOT EXISTS ix_companies_sector         ON core.companies (sector);

-- Calendar: partial index containing only trading days, used by missing-session checks.
CREATE INDEX IF NOT EXISTS ix_calendar_trading_days
    ON ref.trading_calendar (exchange, calendar_date) WHERE is_trading_day;

-- Audit: the Data Quality dashboard filters issues by status/severity, rule and security.
CREATE INDEX IF NOT EXISTS ix_dq_issues_status_severity ON audit.data_quality_issues (status, severity);
CREATE INDEX IF NOT EXISTS ix_dq_issues_rule            ON audit.data_quality_issues (rule_id);
CREATE INDEX IF NOT EXISTS ix_dq_issues_ticker_date     ON audit.data_quality_issues (ticker, trade_date);
CREATE INDEX IF NOT EXISTS ix_dq_issues_raw_record      ON audit.data_quality_issues (raw_record_id);
CREATE INDEX IF NOT EXISTS ix_dq_issues_batch           ON audit.data_quality_issues (ingestion_batch_id);
CREATE INDEX IF NOT EXISTS ix_ingestion_logs_start      ON audit.ingestion_logs (start_timestamp DESC);

-- Rerun protection: the same source snapshot (same checksum) can be successfully loaded
-- only once per dataset type. A PARTIAL unique index applies only to rows matching the
-- WHERE clause, so FAILED and SKIPPED attempts can still be logged any number of times.
CREATE UNIQUE INDEX IF NOT EXISTS ux_ingestion_snapshot_loaded_once
    ON audit.ingestion_logs (batch_type, source_checksum)
    WHERE status IN ('RUNNING', 'SUCCEEDED', 'PARTIAL') AND source_checksum IS NOT NULL;

-- Rule failures: looked up by raw record (quarantine/promotion), by batch (metrics) and by issue (drill-down).
CREATE INDEX IF NOT EXISTS ix_rule_failures_raw_record ON audit.rule_failures (raw_record_id) WHERE raw_record_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_rule_failures_raw_action ON audit.rule_failures (raw_action_id) WHERE raw_action_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_rule_failures_raw_ref    ON audit.rule_failures (raw_reference_id) WHERE raw_reference_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_rule_failures_batch      ON audit.rule_failures (ingestion_batch_id);
CREATE INDEX IF NOT EXISTS ix_rule_failures_issue      ON audit.rule_failures (issue_id);
