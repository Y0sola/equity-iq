-- =============================================================================
-- 02_create_tables.sql
-- Purpose : Create all tables, keys and constraints for EquityIQ.
-- Phase   : 1 — Database architecture
-- Idempotent: yes (CREATE ... IF NOT EXISTS / CREATE OR REPLACE). To apply
--             structural changes to an existing database, run a reset
--             (scripts/db_init.sh --reset) — IF NOT EXISTS will not alter tables.
--
-- DATA TYPE CONVENTIONS (from the project brief)
--   numeric(19,6) for prices  – exact decimal arithmetic; floating point types
--                               (real/double) can store 0.1 as 0.1000000000000000055.
--   bigint for volume         – share volumes can exceed the 2.1 billion int limit.
--   date for trading sessions – a session is a calendar day, not a moment in time.
--   timestamptz for ingestion – an exact instant, stored in UTC.
--
-- CONSTRAINT STRATEGY
--   staging tables: almost no constraints, values kept as TEXT.  Goal = keep
--                   everything so SQL rules can REPORT defects.
--   core tables:    strict NOT NULL / CHECK / UNIQUE / FOREIGN KEY constraints.
--                   Goal = make it impossible for an invalid record to reach the
--                   validated layer, even if validation code has a bug.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Shared trigger function: keep updated_at accurate whenever a row changes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION core.set_updated_at() IS 'BEFORE UPDATE trigger: stamps updated_at with the current transaction time.';


-- =============================================================================
-- REF SCHEMA — project scope and calendar
-- =============================================================================

-- The 20 securities this project tracks, with the sector assigned by the project
-- brief (GICS-style). This is the "security master" whitelist: a ticker that is
-- not here is, by definition, an invalid identifier for this project.
CREATE TABLE IF NOT EXISTS ref.security_universe (
    ticker            varchar(10)  PRIMARY KEY,
    assigned_sector   varchar(60)  NOT NULL,
    is_active         boolean      NOT NULL DEFAULT true,
    added_at          timestamptz  NOT NULL DEFAULT now(),
    notes             text,
    CONSTRAINT ck_universe_ticker_format CHECK (ticker ~ '^[A-Z][A-Z.\-]{0,9}$')
);

COMMENT ON TABLE  ref.security_universe IS 'Whitelist of tracked securities and the sector assigned by the project scope.';
COMMENT ON COLUMN ref.security_universe.assigned_sector IS 'Sector per project brief (GICS-style naming). Provider sector is stored separately in core.companies.provider_sector.';


-- One row per exchange per calendar day in the snapshot period. Weekends and
-- holidays are stored as is_trading_day = false so that "missing session" checks
-- never flag a day the market was closed.
CREATE TABLE IF NOT EXISTS ref.trading_calendar (
    exchange          varchar(10)  NOT NULL,
    calendar_date     date         NOT NULL,
    is_trading_day    boolean      NOT NULL,
    is_early_close    boolean      NOT NULL DEFAULT false,
    holiday_name      varchar(100),
    source            varchar(100) NOT NULL,
    loaded_at         timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_trading_calendar PRIMARY KEY (exchange, calendar_date),
    -- A trading day cannot carry a holiday name; an early close must be a trading day.
    CONSTRAINT ck_calendar_holiday_only_on_closed_days
        CHECK (NOT (is_trading_day AND holiday_name IS NOT NULL)),
    CONSTRAINT ck_calendar_early_close_is_trading_day
        CHECK (NOT is_early_close OR is_trading_day)
);

-- Maps a provider's sector labels to the project's GICS-style sector names, so the
-- provider sector can be compared with the assigned sector (consistency rule DQ-CNS-005).
CREATE TABLE IF NOT EXISTS ref.sector_mapping (
    source            varchar(50)  NOT NULL,
    provider_sector   varchar(100) NOT NULL,
    mapped_sector     varchar(60)  NOT NULL,
    CONSTRAINT pk_sector_mapping PRIMARY KEY (source, provider_sector)
);

COMMENT ON TABLE ref.sector_mapping IS 'Provider sector label -> project (GICS-style) sector name.';

COMMENT ON TABLE ref.trading_calendar IS 'Exchange session calendar (incl. weekends, holidays, exceptional closures) pinned to the snapshot period.';


-- =============================================================================
-- AUDIT SCHEMA (part 1) — ingestion batches
-- Created before staging because every raw row points to the batch that loaded it.
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.ingestion_logs (
    ingestion_batch_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_type           varchar(30)  NOT NULL,
    source               varchar(100) NOT NULL,
    retrieval_parameters jsonb,                     -- e.g. tickers, period, auto_adjust setting
    snapshot_start_date  date,
    snapshot_end_date    date,
    snapshot_label       varchar(100),               -- folder name of the local source snapshot
    source_checksum      varchar(64),                -- SHA-256 of the source files loaded by this batch
    start_timestamp      timestamptz  NOT NULL DEFAULT now(),
    end_timestamp        timestamptz,
    records_received     integer      NOT NULL DEFAULT 0,
    records_accepted     integer      NOT NULL DEFAULT 0,
    records_rejected     integer      NOT NULL DEFAULT 0,  -- quarantined (critical failures)
    records_flagged      integer      NOT NULL DEFAULT 0,  -- accepted with warnings / review flags
    status               varchar(20)  NOT NULL DEFAULT 'RUNNING',
    error_message        text,
    validated_at         timestamptz,                -- when SQL validation/promotion last processed this batch
    CONSTRAINT ck_ingestion_batch_type
        CHECK (batch_type IN ('PRICES', 'COMPANY_REFERENCE', 'CORPORATE_ACTIONS', 'TRADING_CALENDAR', 'FULL_SNAPSHOT')),
    CONSTRAINT ck_ingestion_status
        -- SKIPPED = rerun of a snapshot that was already loaded; logged for audit, nothing inserted.
        CHECK (status IN ('RUNNING', 'SUCCEEDED', 'PARTIAL', 'FAILED', 'SKIPPED')),
    CONSTRAINT ck_ingestion_checksum_format
        CHECK (source_checksum IS NULL OR source_checksum ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_ingestion_counts_non_negative
        CHECK (records_received >= 0 AND records_accepted >= 0
               AND records_rejected >= 0 AND records_flagged >= 0),
    -- Every received record ends up either accepted or rejected (flagged records are a subset of accepted).
    CONSTRAINT ck_ingestion_counts_reconcile
        CHECK (status = 'RUNNING' OR records_accepted + records_rejected <= records_received),
    CONSTRAINT ck_ingestion_end_after_start
        CHECK (end_timestamp IS NULL OR end_timestamp >= start_timestamp),
    CONSTRAINT ck_ingestion_finished_has_end
        CHECK (status = 'RUNNING' OR end_timestamp IS NOT NULL),
    CONSTRAINT ck_ingestion_snapshot_range
        CHECK (snapshot_end_date IS NULL OR snapshot_start_date IS NULL
               OR snapshot_end_date >= snapshot_start_date)
);

COMMENT ON TABLE audit.ingestion_logs IS 'One row per ingestion batch: what was requested, when, and how many records were received/accepted/rejected/flagged.';


-- =============================================================================
-- STAGING SCHEMA — permissive raw landing tables
-- Source values are stored as TEXT exactly as received. No uniqueness, range or
-- type checks: duplicates, negative values and unparseable text must be able to
-- land here so the SQL validation rules (Phase 3) can detect and report them.
-- =============================================================================

CREATE TABLE IF NOT EXISTS staging.raw_company_reference (
    raw_reference_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingestion_batch_id   bigint       NOT NULL REFERENCES audit.ingestion_logs (ingestion_batch_id),
    source_row_number    integer,
    ticker               text,
    company_name         text,
    sector               text,
    industry             text,
    exchange             text,
    currency             text,
    source               text         NOT NULL,
    ingestion_timestamp  timestamptz  NOT NULL DEFAULT now(),
    raw_payload          jsonb        -- original provider fields, for lineage and re-parsing
);

COMMENT ON TABLE staging.raw_company_reference IS 'Raw company metadata as received from the source, one row per ticker per batch.';


CREATE TABLE IF NOT EXISTS staging.raw_stock_prices (
    raw_record_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingestion_batch_id   bigint       NOT NULL REFERENCES audit.ingestion_logs (ingestion_batch_id),
    source_row_number    integer,
    ticker               text,
    trade_date           text,
    open_price           text,
    high_price           text,
    low_price            text,
    close_price          text,
    adjusted_close       text,
    volume               text,
    currency             text,
    source               text         NOT NULL,
    ingestion_timestamp  timestamptz  NOT NULL DEFAULT now(),
    raw_payload          jsonb
);

COMMENT ON TABLE  staging.raw_stock_prices IS 'Raw daily OHLCV rows as received. Text columns preserve malformed values for diagnosis.';
COMMENT ON COLUMN staging.raw_stock_prices.close_price    IS 'Provider-reported close (yfinance auto_adjust=False: split-adjusted, not dividend-adjusted — verified in Phase 2).';
COMMENT ON COLUMN staging.raw_stock_prices.adjusted_close IS 'Provider adjusted close (split- and dividend-adjusted).';


CREATE TABLE IF NOT EXISTS staging.raw_corporate_actions (
    raw_action_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingestion_batch_id   bigint       NOT NULL REFERENCES audit.ingestion_logs (ingestion_batch_id),
    source_row_number    integer,
    ticker               text,
    action_date          text,
    action_type          text,
    dividend_amount      text,
    split_ratio          text,
    source               text         NOT NULL,
    ingestion_timestamp  timestamptz  NOT NULL DEFAULT now(),
    raw_payload          jsonb
);

COMMENT ON TABLE staging.raw_corporate_actions IS 'Raw dividend and stock split events as received from the source.';


-- =============================================================================
-- CORE SCHEMA — validated production records
-- =============================================================================

CREATE TABLE IF NOT EXISTS core.companies (
    company_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticker            varchar(10)  NOT NULL,
    company_name      varchar(200) NOT NULL,
    sector            varchar(60)  NOT NULL,   -- project-assigned sector (from ref.security_universe)
    provider_sector   varchar(100),            -- sector label reported by the data provider
    industry          varchar(150),
    exchange          varchar(20)  NOT NULL,
    currency          char(3)      NOT NULL,
    source            varchar(100) NOT NULL,
    raw_reference_id  bigint REFERENCES staging.raw_company_reference (raw_reference_id),  -- lineage
    created_at        timestamptz  NOT NULL DEFAULT now(),
    updated_at        timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_companies_ticker UNIQUE (ticker),
    -- Only tickers in the project universe can become production companies.
    CONSTRAINT fk_companies_universe FOREIGN KEY (ticker) REFERENCES ref.security_universe (ticker),
    CONSTRAINT ck_companies_currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_companies_name_not_blank CHECK (btrim(company_name) <> '')
);

COMMENT ON TABLE core.companies IS 'Validated security master: one row per tracked company.';

CREATE OR REPLACE TRIGGER trg_companies_updated_at
    BEFORE UPDATE ON core.companies
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();


CREATE TABLE IF NOT EXISTS core.stock_prices (
    price_id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id           integer       NOT NULL REFERENCES core.companies (company_id),
    trade_date           date          NOT NULL,
    open_price           numeric(19,6) NOT NULL,
    high_price           numeric(19,6) NOT NULL,
    low_price            numeric(19,6) NOT NULL,
    close_price          numeric(19,6) NOT NULL,
    adjusted_close       numeric(19,6) NOT NULL,
    volume               bigint        NOT NULL,
    source               varchar(100)  NOT NULL,
    ingestion_timestamp  timestamptz   NOT NULL,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    -- Lineage: the exact staging row this record was promoted from. ON DELETE is
    -- the default (NO ACTION), so a raw record cannot be deleted while a
    -- production record still depends on it.
    raw_record_id        bigint        NOT NULL REFERENCES staging.raw_stock_prices (raw_record_id),
    -- One price record per security per trading session (business key).
    CONSTRAINT uq_stock_prices_company_date UNIQUE (company_id, trade_date),
    -- A raw row can be promoted at most once.
    CONSTRAINT uq_stock_prices_raw_record UNIQUE (raw_record_id),
    -- Validity: prices strictly positive, volume never negative.
    CONSTRAINT ck_prices_positive
        CHECK (open_price > 0 AND high_price > 0 AND low_price > 0
               AND close_price > 0 AND adjusted_close > 0),
    CONSTRAINT ck_volume_non_negative CHECK (volume >= 0),
    -- Consistency: the high is the highest and the low is the lowest trade of the day.
    CONSTRAINT ck_high_gte_low  CHECK (high_price >= low_price),
    CONSTRAINT ck_open_in_range CHECK (open_price  BETWEEN low_price AND high_price),
    CONSTRAINT ck_close_in_range CHECK (close_price BETWEEN low_price AND high_price)
);

COMMENT ON TABLE  core.stock_prices IS 'Validated daily OHLCV records, unique per company and trading session, with lineage to staging.';
COMMENT ON COLUMN core.stock_prices.adjusted_close IS 'Not range-checked against high/low: dividend adjustment legitimately moves it outside the reported range.';

CREATE OR REPLACE TRIGGER trg_stock_prices_updated_at
    BEFORE UPDATE ON core.stock_prices
    FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();


CREATE TABLE IF NOT EXISTS core.corporate_actions (
    action_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id           integer       NOT NULL REFERENCES core.companies (company_id),
    action_date          date          NOT NULL,
    action_type          varchar(20)   NOT NULL,
    dividend_amount      numeric(19,6),          -- per share, in the company currency
    split_ratio          numeric(12,6),          -- new shares per old share: 4-for-1 = 4.0, 1-for-10 reverse = 0.1
    source               varchar(100)  NOT NULL,
    ingestion_timestamp  timestamptz   NOT NULL,
    raw_action_id        bigint REFERENCES staging.raw_corporate_actions (raw_action_id),  -- lineage
    CONSTRAINT ck_action_type CHECK (action_type IN ('DIVIDEND', 'STOCK_SPLIT')),
    -- Type-specific rules: each action type carries exactly its own value field.
    CONSTRAINT ck_action_dividend_fields CHECK (
        action_type <> 'DIVIDEND'
        OR (dividend_amount IS NOT NULL AND dividend_amount > 0 AND split_ratio IS NULL)),
    CONSTRAINT ck_action_split_fields CHECK (
        action_type <> 'STOCK_SPLIT'
        OR (split_ratio IS NOT NULL AND split_ratio > 0 AND split_ratio <> 1 AND dividend_amount IS NULL)),
    -- Documented uniqueness: at most one event of each type per company per date.
    CONSTRAINT uq_corporate_actions_company_date_type UNIQUE (company_id, action_date, action_type)
);

COMMENT ON TABLE core.corporate_actions IS 'Validated dividends and stock splits. Unique per company, date and action type.';


-- =============================================================================
-- AUDIT SCHEMA (part 2) — data quality rule catalogue and issues
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.data_quality_rules (
    rule_id              varchar(20)   PRIMARY KEY,      -- e.g. 'DQ-VAL-003'
    rule_name            varchar(100)  NOT NULL,
    rule_category        varchar(20)   NOT NULL,
    rule_description     text          NOT NULL,
    expected_condition   text          NOT NULL,         -- the condition a valid record satisfies
    target_table         varchar(60)   NOT NULL,
    severity             varchar(10)   NOT NULL,
    issue_class          varchar(20)   NOT NULL,
    handling             varchar(20)   NOT NULL,
    threshold_value      numeric,                         -- e.g. 10 (%) for the large-move rule
    business_justification text,                          -- why the rule matters to data consumers
    is_active            boolean       NOT NULL DEFAULT true,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT uq_dq_rules_name UNIQUE (rule_name),
    CONSTRAINT ck_dq_rule_category CHECK (rule_category IN
        ('COMPLETENESS', 'UNIQUENESS', 'VALIDITY', 'CONSISTENCY', 'TIMELINESS', 'ANOMALY')),
    CONSTRAINT ck_dq_rule_severity CHECK (severity IN ('CRITICAL', 'WARNING', 'INFO')),
    -- CONFIRMED_DEFECT: the record is wrong.  REVIEWABLE_ANOMALY: unusual but may be genuine.
    CONSTRAINT ck_dq_rule_issue_class CHECK (issue_class IN ('CONFIRMED_DEFECT', 'REVIEWABLE_ANOMALY')),
    CONSTRAINT ck_dq_rule_handling CHECK (handling IN ('QUARANTINE', 'ACCEPT_WITH_WARNING', 'FLAG_FOR_REVIEW')),
    -- Anomalies are never quarantined automatically: large genuine moves must not be discarded.
    CONSTRAINT ck_dq_rule_anomaly_not_quarantined
        CHECK (issue_class <> 'REVIEWABLE_ANOMALY' OR handling = 'FLAG_FOR_REVIEW')
);

COMMENT ON TABLE audit.data_quality_rules IS 'Central catalogue of SQL data quality rules: category, severity, expected condition and handling.';


CREATE TABLE IF NOT EXISTS audit.data_quality_issues (
    issue_id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Stable identity: rule + business key + field, e.g. 'DQ-CON-001|AAPL|2025-03-14|high_price'.
    -- Re-running validation on the same snapshot updates this row instead of creating a new one.
    issue_key            text          NOT NULL,
    rule_id              varchar(20)   NOT NULL REFERENCES audit.data_quality_rules (rule_id),
    -- At most one of the raw lineage columns is set. All may be NULL for issues about
    -- records that do not exist (e.g. a missing trading session).
    raw_record_id        bigint REFERENCES staging.raw_stock_prices (raw_record_id),
    raw_action_id        bigint REFERENCES staging.raw_corporate_actions (raw_action_id),
    raw_reference_id     bigint REFERENCES staging.raw_company_reference (raw_reference_id),
    company_id           integer REFERENCES core.companies (company_id),
    ticker               text,
    trade_date           date,
    affected_field       varchar(60),
    observed_value       text,
    expected_condition   text,
    severity             varchar(10)   NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'OPEN',
    detected_at          timestamptz   NOT NULL DEFAULT now(),   -- first detection
    last_detected_at     timestamptz   NOT NULL DEFAULT now(),   -- most recent re-detection
    detection_count      integer       NOT NULL DEFAULT 1,
    resolved_at          timestamptz,
    resolution_notes     text,
    ingestion_batch_id   bigint REFERENCES audit.ingestion_logs (ingestion_batch_id),  -- batch that first raised it
    last_detected_batch_id bigint REFERENCES audit.ingestion_logs (ingestion_batch_id), -- most recent batch that raised it
    CONSTRAINT uq_dq_issues_issue_key UNIQUE (issue_key),
    CONSTRAINT ck_dq_issue_severity CHECK (severity IN ('CRITICAL', 'WARNING', 'INFO')),
    CONSTRAINT ck_dq_issue_status CHECK (status IN ('OPEN', 'UNDER_REVIEW', 'RESOLVED', 'DISMISSED')),
    -- Closed issues must say when they were closed; open issues must not.
    CONSTRAINT ck_dq_issue_resolution CHECK (
        (status IN ('RESOLVED', 'DISMISSED') AND resolved_at IS NOT NULL)
        OR (status IN ('OPEN', 'UNDER_REVIEW') AND resolved_at IS NULL)),
    CONSTRAINT ck_dq_issue_single_raw_source CHECK (
        num_nonnulls(raw_record_id, raw_action_id, raw_reference_id) <= 1),
    CONSTRAINT ck_dq_issue_detection_order CHECK (last_detected_at >= detected_at),
    CONSTRAINT ck_dq_issue_detection_count CHECK (detection_count >= 1)
);

COMMENT ON TABLE  audit.data_quality_issues IS 'One row per distinct data quality issue (stable issue_key), with workflow status and lineage.';
COMMENT ON COLUMN audit.data_quality_issues.issue_key IS 'Deterministic identity = rule_id|ticker|date|field. Prevents duplicate issues on re-runs.';


-- One row per (raw record, rule, field) failure. This is the RECORD-level fact table:
-- quarantine decisions and pass rates are computed from it. data_quality_issues is the
-- ISSUE-level workflow table (one row per distinct problem). Keeping both lets us
-- report "how many records failed" separately from "how many issues exist", since one
-- record can fail several rules and one issue can cover several records (e.g. every
-- copy of a conflicting duplicate).
CREATE TABLE IF NOT EXISTS audit.rule_failures (
    failure_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id              varchar(20)  NOT NULL REFERENCES audit.data_quality_rules (rule_id),
    issue_id             bigint       NOT NULL REFERENCES audit.data_quality_issues (issue_id),
    ingestion_batch_id   bigint       NOT NULL REFERENCES audit.ingestion_logs (ingestion_batch_id),
    raw_record_id        bigint REFERENCES staging.raw_stock_prices (raw_record_id),
    raw_action_id        bigint REFERENCES staging.raw_corporate_actions (raw_action_id),
    raw_reference_id     bigint REFERENCES staging.raw_company_reference (raw_reference_id),
    affected_field       varchar(60)  NOT NULL,
    observed_value       text,
    detected_at          timestamptz  NOT NULL DEFAULT now(),
    -- Exactly one raw record per failure.
    CONSTRAINT ck_rule_failure_one_source CHECK (num_nonnulls(raw_record_id, raw_action_id, raw_reference_id) = 1),
    -- Re-running validation cannot record the same failure twice. NULLS NOT DISTINCT
    -- (PostgreSQL 15+) treats the empty lineage columns as equal for uniqueness.
    CONSTRAINT uq_rule_failure UNIQUE NULLS NOT DISTINCT
        (rule_id, raw_record_id, raw_action_id, raw_reference_id, affected_field)
);

COMMENT ON TABLE audit.rule_failures IS 'Record-level rule failures (raw record x rule x field). Drives quarantine and pass-rate metrics.';
