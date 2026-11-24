-- =============================================================================
-- 06_data_validation.sql
-- Purpose : SQL implementation of the data quality rules in 05_data_quality_rules.sql.
-- Phase   : 3 — Quality framework
-- Idempotent: yes (CREATE OR REPLACE)
--
-- HOW VALIDATION WORKS
--   1. Each validate_*_batch() function runs every rule for one ingestion batch as an
--      INSERT ... SELECT into a temporary "violations" table. Each SELECT is the rule:
--      it returns exactly the rows that break it.
--   2. record_violations() turns violations into
--        - audit.data_quality_issues: one row per distinct problem (stable issue_key)
--        - audit.rule_failures:       one row per raw record x rule x field
--      Both use UPSERT / ON CONFLICT so re-running validation never creates duplicates.
--   3. Promotion (07) reads the outcome of each raw record from audit.v_record_outcomes.
--
-- Contents
--   A. Helper functions (safe casting, rounding, issue keys, thresholds)
--   B. Typed staging views
--   C. Issue recording + status workflow
--   D. Reference data validation
--   E. Price validation
--   F. Corporate action validation
--   G. Post-promotion checks (missing sessions, timeliness, anomalies)
-- =============================================================================


-- =============================================================================
-- A. HELPER FUNCTIONS
-- =============================================================================

-- True when a text value is NULL or only whitespace.
CREATE OR REPLACE FUNCTION staging.is_blank(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_value IS NULL OR btrim(p_value) = '';
$$;

-- Convert text to numeric, or NULL if blank or not a plain decimal number.
-- Accepted format (strict, documented): optional sign, digits with optional decimal
-- point, optional exponent, surrounding spaces allowed: 100, -0.5, .5, 1e3, +7.
-- Rejected: NaN, Infinity, thousands separators (1,000), and formats PostgreSQL's own
-- numeric parser would accept but a price file should never contain, such as
-- underscores (1_000) or hexadecimal (0x1A = 26). The regex check is also ~7x faster
-- than pg_input_is_valid() on the real snapshot (18 ms vs 127 ms for 30,120 values).
CREATE OR REPLACE FUNCTION staging.to_numeric_or_null(p_value text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN p_value ~ '^\s*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?\s*$'
             THEN btrim(p_value)::numeric
           END;
$$;

-- Convert text to a date only if it is strict ISO format YYYY-MM-DD and a real date.
-- (Formats like 03/04/2026 are rejected: is that 3 April or 4 March?)
CREATE OR REPLACE FUNCTION staging.to_date_or_null(p_value text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN p_value ~ '^\d{4}-\d{2}-\d{2}$' AND pg_input_is_valid(p_value, 'date')
             THEN p_value::date
           END;
$$;

-- THE rounding rules applied on promotion (defined once, used by promotion and by the
-- revision-conflict check). Reported prices: whole cents, proven lossless for Yahoo's
-- float32 values (docs/data_acquisition.md). Adjusted close: 6 dp (derived value).
CREATE OR REPLACE FUNCTION core.to_reported_price(p numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT round(p, 2) $$;

CREATE OR REPLACE FUNCTION core.to_adjusted_price(p numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT round(p, 6) $$;

-- Stable issue identity: rule | ticker | date | field. Same inputs -> same key, every run.
CREATE OR REPLACE FUNCTION audit.make_issue_key(p_rule text, p_ticker text, p_date text, p_field text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT concat_ws('|', p_rule, coalesce(p_ticker, '-'), coalesce(p_date, '-'), coalesce(p_field, '-'));
$$;

-- Threshold for a rule, read from the catalogue (so thresholds are documented data).
CREATE OR REPLACE FUNCTION audit.rule_threshold(p_rule text)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT threshold_value FROM audit.data_quality_rules WHERE rule_id = p_rule;
$$;

-- Readable rendering of a raw value inside an issue.
CREATE OR REPLACE FUNCTION audit.show_value(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_value IS NULL THEN 'NULL'
                WHEN btrim(p_value) = '' THEN '(blank)'
                ELSE left(p_value, 200) END;
$$;


-- =============================================================================
-- B. TYPED STAGING VIEWS
-- Staging keeps text. These views add parsed columns (NULL when unparseable) so every
-- rule and the promotion step use the same conversion.
-- =============================================================================

CREATE OR REPLACE VIEW staging.v_raw_stock_prices_typed AS
SELECT r.raw_record_id,
       r.ingestion_batch_id,
       r.source_row_number,
       r.ticker,
       r.trade_date,
       staging.to_date_or_null(r.trade_date)        AS trade_date_value,
       r.open_price, r.high_price, r.low_price, r.close_price, r.adjusted_close, r.volume,
       staging.to_numeric_or_null(r.open_price)     AS open_value,
       staging.to_numeric_or_null(r.high_price)     AS high_value,
       staging.to_numeric_or_null(r.low_price)      AS low_value,
       staging.to_numeric_or_null(r.close_price)    AS close_value,
       staging.to_numeric_or_null(r.adjusted_close) AS adjusted_close_value,
       staging.to_numeric_or_null(r.volume)         AS volume_value,
       upper(nullif(btrim(r.currency), ''))         AS currency_value,
       r.source,
       r.ingestion_timestamp
  FROM staging.raw_stock_prices r;

COMMENT ON VIEW staging.v_raw_stock_prices_typed IS 'Raw prices with safely parsed typed columns (NULL = blank or unparseable).';

-- One row per (raw record, numeric field): "unpivots" six columns into rows so one
-- rule query can check every field. CROSS JOIN LATERAL (VALUES ...) is the idiom.
CREATE OR REPLACE VIEW staging.v_raw_price_fields AS
-- Unpivot the RAW text first, then convert each value once (converting inside the
-- typed view and unpivoting afterwards re-evaluated conversions for every field).
SELECT r.raw_record_id, r.ingestion_batch_id, r.ticker, r.trade_date,
       staging.to_date_or_null(r.trade_date)       AS trade_date_value,
       f.field_name, f.raw_value,
       staging.to_numeric_or_null(f.raw_value)     AS numeric_value,
       f.is_price
  FROM staging.raw_stock_prices r
 CROSS JOIN LATERAL (VALUES
        ('open_price',     r.open_price,     true),
        ('high_price',     r.high_price,     true),
        ('low_price',      r.low_price,      true),
        ('close_price',    r.close_price,    true),
        ('adjusted_close', r.adjusted_close, true),
        ('volume',         r.volume,         false)
      ) AS f(field_name, raw_value, is_price);

CREATE OR REPLACE VIEW staging.v_raw_corporate_actions_typed AS
SELECT r.raw_action_id,
       r.ingestion_batch_id,
       r.ticker,
       r.action_date,
       staging.to_date_or_null(r.action_date)        AS action_date_value,
       r.action_type,
       r.dividend_amount,
       r.split_ratio,
       staging.to_numeric_or_null(r.dividend_amount) AS dividend_value,
       staging.to_numeric_or_null(r.split_ratio)     AS split_value,
       r.source,
       r.ingestion_timestamp
  FROM staging.raw_corporate_actions r;


-- =============================================================================
-- C. ISSUE RECORDING AND WORKFLOW
-- =============================================================================

-- Scratch table for the current validation run (one per database session).
CREATE OR REPLACE FUNCTION audit.begin_violations()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF to_regclass('pg_temp.tmp_violations') IS NULL THEN
    CREATE TEMP TABLE tmp_violations (
        rule_id            varchar(20) NOT NULL,
        issue_key          text        NOT NULL,
        raw_record_id      bigint,
        raw_action_id      bigint,
        raw_reference_id   bigint,
        company_id         integer,
        ticker             text,
        trade_date         date,
        affected_field     varchar(60) NOT NULL,
        observed_value     text,
        expected_condition text,
        record_batch_id    bigint      -- batch of the raw record, when it differs from the batch being processed
    );
    END IF;
    TRUNCATE tmp_violations;
END;
$$;

-- Write the violations of the current run to issues (one per issue_key) and
-- rule_failures (one per raw record x rule x field). Returns the number of violations.
CREATE OR REPLACE FUNCTION audit.record_violations(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count FROM tmp_violations;

    -- 1. Issues. DISTINCT ON keeps one representative row per issue_key (lowest raw id),
    --    because ON CONFLICT cannot update the same target row twice in one statement.
    INSERT INTO audit.data_quality_issues AS i
          (issue_key, rule_id, raw_record_id, raw_action_id, raw_reference_id, company_id,
           ticker, trade_date, affected_field, observed_value, expected_condition, severity,
           ingestion_batch_id, last_detected_batch_id)
    SELECT DISTINCT ON (v.issue_key)
           v.issue_key, v.rule_id, v.raw_record_id, v.raw_action_id, v.raw_reference_id,
           coalesce(v.company_id, c.company_id),
           v.ticker, v.trade_date, v.affected_field, v.observed_value,
           coalesce(v.expected_condition, r.expected_condition), r.severity, p_batch, p_batch
      FROM tmp_violations v
      JOIN audit.data_quality_rules r ON r.rule_id = v.rule_id AND r.is_active
      LEFT JOIN core.companies c ON c.ticker = v.ticker
     ORDER BY v.issue_key, v.raw_record_id NULLS LAST, v.raw_action_id NULLS LAST, v.raw_reference_id NULLS LAST
    ON CONFLICT (issue_key) DO UPDATE SET
           last_detected_at       = now(),
           detection_count        = i.detection_count + 1,
           last_detected_batch_id = EXCLUDED.last_detected_batch_id,
           observed_value         = EXCLUDED.observed_value,
           company_id             = coalesce(i.company_id, EXCLUDED.company_id),
           -- A RESOLVED issue found again in a DIFFERENT batch is reopened (the defect came
           -- back in new data). DISMISSED issues stay dismissed: an analyst decided the
           -- condition is not a defect for this key.
           status = CASE WHEN i.status = 'RESOLVED'
                          AND EXCLUDED.last_detected_batch_id IS DISTINCT FROM i.last_detected_batch_id
                         THEN 'OPEN' ELSE i.status END,
           resolved_at = CASE WHEN i.status = 'RESOLVED'
                               AND EXCLUDED.last_detected_batch_id IS DISTINCT FROM i.last_detected_batch_id
                              THEN NULL ELSE i.resolved_at END,
           resolution_notes = CASE WHEN i.status = 'RESOLVED'
                                    AND EXCLUDED.last_detected_batch_id IS DISTINCT FROM i.last_detected_batch_id
                                   THEN concat_ws(' | ', i.resolution_notes,
                                                  'Reopened: detected again in batch ' || EXCLUDED.last_detected_batch_id)
                                   ELSE i.resolution_notes END;

    -- 2. Record-level failures (only violations tied to exactly one raw record).
    INSERT INTO audit.rule_failures
          (rule_id, issue_id, ingestion_batch_id, raw_record_id, raw_action_id, raw_reference_id,
           affected_field, observed_value)
    SELECT v.rule_id, i.issue_id, coalesce(v.record_batch_id, p_batch), v.raw_record_id, v.raw_action_id, v.raw_reference_id,
           v.affected_field, v.observed_value
      FROM tmp_violations v
      JOIN audit.data_quality_rules r ON r.rule_id = v.rule_id AND r.is_active
      JOIN audit.data_quality_issues i ON i.issue_key = v.issue_key
     WHERE num_nonnulls(v.raw_record_id, v.raw_action_id, v.raw_reference_id) = 1
    ON CONFLICT ON CONSTRAINT uq_rule_failure DO NOTHING;

    TRUNCATE tmp_violations;
    RETURN v_count;
END;
$$;

-- Allowed issue status transitions (enforced by trigger):
--   OPEN         -> UNDER_REVIEW, RESOLVED, DISMISSED
--   UNDER_REVIEW -> OPEN, RESOLVED, DISMISSED
--   RESOLVED     -> OPEN            (reopened)
--   DISMISSED    -> OPEN            (decision reversed)
CREATE OR REPLACE FUNCTION audit.check_issue_status_transition()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
           (OLD.status = 'OPEN'         AND NEW.status IN ('UNDER_REVIEW', 'RESOLVED', 'DISMISSED'))
        OR (OLD.status = 'UNDER_REVIEW' AND NEW.status IN ('OPEN', 'RESOLVED', 'DISMISSED'))
        OR (OLD.status = 'RESOLVED'     AND NEW.status = 'OPEN')
        OR (OLD.status = 'DISMISSED'    AND NEW.status = 'OPEN'))
    THEN
        RAISE EXCEPTION 'Invalid issue status transition % -> % (issue %)', OLD.status, NEW.status, OLD.issue_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_dq_issue_status_transition
    BEFORE UPDATE OF status ON audit.data_quality_issues
    FOR EACH ROW EXECUTE FUNCTION audit.check_issue_status_transition();

-- Analyst workflow entry point: change status and keep resolved_at consistent.
CREATE OR REPLACE FUNCTION audit.set_issue_status(p_issue_id bigint, p_status text, p_notes text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE audit.data_quality_issues
       SET status           = p_status,
           resolved_at      = CASE WHEN p_status IN ('RESOLVED', 'DISMISSED') THEN now() END,
           resolution_notes = concat_ws(' | ', resolution_notes, p_notes)
     WHERE issue_id = p_issue_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Issue % not found', p_issue_id;
    END IF;
END;
$$;


-- =============================================================================
-- D. REFERENCE DATA VALIDATION (batch_type = COMPANY_REFERENCE)
-- =============================================================================
CREATE OR REPLACE FUNCTION audit.validate_reference_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
    PERFORM audit.begin_violations();

    -- DQ-COM-003 missing identifier (ticker)
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value)
    SELECT 'DQ-COM-003', audit.make_issue_key('DQ-COM-003', 'reference row ' || r.raw_reference_id, NULL, 'ticker'),
           r.raw_reference_id, r.ticker, 'ticker', audit.show_value(r.ticker)
      FROM staging.raw_company_reference r
     WHERE r.ingestion_batch_id = p_batch AND staging.is_blank(r.ticker);

    -- DQ-VAL-004 ticker not in the tracked universe
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value)
    SELECT 'DQ-VAL-004', audit.make_issue_key('DQ-VAL-004', r.ticker, NULL, 'ticker'),
           r.raw_reference_id, r.ticker, 'ticker', audit.show_value(r.ticker)
      FROM staging.raw_company_reference r
     WHERE r.ingestion_batch_id = p_batch AND NOT staging.is_blank(r.ticker)
       AND NOT EXISTS (SELECT 1 FROM ref.security_universe u WHERE u.ticker = r.ticker);

    -- DQ-COM-005 required reference fields / DQ-COM-006 optional reference fields
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value)
    SELECT f.rule_id, audit.make_issue_key(f.rule_id, r.ticker, NULL, f.field),
           r.raw_reference_id, r.ticker, f.field, audit.show_value(f.val)
      FROM staging.raw_company_reference r
     CROSS JOIN LATERAL (VALUES ('DQ-COM-005', 'company_name', r.company_name),
                                ('DQ-COM-005', 'exchange',     r.exchange),
                                ('DQ-COM-005', 'currency',     r.currency),
                                ('DQ-COM-006', 'sector',       r.sector),
                                ('DQ-COM-006', 'industry',     r.industry)) AS f(rule_id, field, val)
     WHERE r.ingestion_batch_id = p_batch AND staging.is_blank(f.val);

    -- DQ-VAL-012 currency not a 3-letter upper-case code
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value)
    SELECT 'DQ-VAL-012', audit.make_issue_key('DQ-VAL-012', r.ticker, NULL, 'currency'),
           r.raw_reference_id, r.ticker, 'currency', audit.show_value(r.currency)
      FROM staging.raw_company_reference r
     WHERE r.ingestion_batch_id = p_batch AND NOT staging.is_blank(r.currency)
       AND r.currency !~ '^[A-Z]{3}$';

    -- DQ-UNI-005 / DQ-UNI-006 duplicate tickers in the batch (exact vs conflicting)
    WITH copies AS (
        SELECT r.*,
               row_number() OVER (PARTITION BY r.ticker ORDER BY r.raw_reference_id) AS copy_no,
               count(*)     OVER (PARTITION BY r.ticker)                           AS copies
          FROM staging.raw_company_reference r
         WHERE r.ingestion_batch_id = p_batch AND NOT staging.is_blank(r.ticker)
    ),
    groups AS (
        SELECT ticker,
               count(DISTINCT (company_name, sector, industry, exchange, currency)) AS versions
          FROM copies WHERE copies > 1 GROUP BY ticker
    )
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value)
    SELECT CASE WHEN g.versions = 1 THEN 'DQ-UNI-005' ELSE 'DQ-UNI-006' END,
           audit.make_issue_key(CASE WHEN g.versions = 1 THEN 'DQ-UNI-005' ELSE 'DQ-UNI-006' END, c.ticker, NULL, 'record'),
           c.raw_reference_id, c.ticker, 'record',
           c.copies || ' copies, ' || g.versions || ' distinct version(s)'
      FROM copies c JOIN groups g USING (ticker)
     WHERE g.versions > 1          -- conflicting: every copy fails
        OR c.copy_no > 1;          -- exact: only the redundant copies fail

    -- DQ-CNS-005 provider sector (mapped) differs from the project-assigned sector
    INSERT INTO tmp_violations (rule_id, issue_key, raw_reference_id, ticker, affected_field, observed_value, expected_condition)
    SELECT 'DQ-CNS-005', audit.make_issue_key('DQ-CNS-005', r.ticker, NULL, 'sector'),
           r.raw_reference_id, r.ticker, 'sector',
           r.sector || ' -> ' || coalesce(m.mapped_sector, '(unmapped)'),
           'mapped sector = ' || u.assigned_sector
      FROM staging.raw_company_reference r
      JOIN ref.security_universe u ON u.ticker = r.ticker
      LEFT JOIN ref.sector_mapping m ON m.source = r.source AND m.provider_sector = r.sector
     WHERE r.ingestion_batch_id = p_batch AND NOT staging.is_blank(r.sector)
       AND m.mapped_sector IS DISTINCT FROM u.assigned_sector;

    RETURN audit.record_violations(p_batch);
END;
$$;


-- =============================================================================
-- E. PRICE VALIDATION (batch_type = PRICES)
-- =============================================================================
CREATE OR REPLACE FUNCTION audit.validate_price_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_start date;
    v_end   date;
BEGIN
    SELECT snapshot_start_date, snapshot_end_date INTO v_start, v_end
      FROM audit.ingestion_logs WHERE ingestion_batch_id = p_batch AND batch_type = 'PRICES';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % is not a PRICES batch', p_batch;
    END IF;

    PERFORM audit.begin_violations();

    -- DQ-COM-001 missing price field / DQ-COM-002 missing volume
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT CASE WHEN f.is_price THEN 'DQ-COM-001' ELSE 'DQ-COM-002' END,
           audit.make_issue_key(CASE WHEN f.is_price THEN 'DQ-COM-001' ELSE 'DQ-COM-002' END,
                                f.ticker, f.trade_date, f.field_name),
           f.raw_record_id, f.ticker, f.trade_date_value, f.field_name, audit.show_value(f.raw_value)
      FROM staging.v_raw_price_fields f
     WHERE f.ingestion_batch_id = p_batch AND staging.is_blank(f.raw_value);

    -- DQ-VAL-001 present but not a finite number within the storable range
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-001', audit.make_issue_key('DQ-VAL-001', f.ticker, f.trade_date, f.field_name),
           f.raw_record_id, f.ticker, f.trade_date_value, f.field_name, audit.show_value(f.raw_value)
      FROM staging.v_raw_price_fields f
     WHERE f.ingestion_batch_id = p_batch AND NOT staging.is_blank(f.raw_value)
       AND (f.numeric_value IS NULL
            OR (f.is_price     AND abs(f.numeric_value) >= 1e12)     -- exceeds numeric(19,6)
            OR (NOT f.is_price AND abs(f.numeric_value) >= 1e18));   -- exceeds bigint

    -- DQ-VAL-002 price zero/negative (also after rounding to the stored precision)
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-002', audit.make_issue_key('DQ-VAL-002', f.ticker, f.trade_date, f.field_name),
           f.raw_record_id, f.ticker, f.trade_date_value, f.field_name, f.raw_value
      FROM staging.v_raw_price_fields f
     WHERE f.ingestion_batch_id = p_batch AND f.is_price
       AND (f.numeric_value <= 0
            OR (f.field_name <> 'adjusted_close' AND core.to_reported_price(f.numeric_value) <= 0)
            OR (f.field_name =  'adjusted_close' AND core.to_adjusted_price(f.numeric_value) <= 0));

    -- DQ-VAL-003 negative volume / DQ-VAL-008 fractional volume
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT x.rule_id, audit.make_issue_key(x.rule_id, t.ticker, t.trade_date, 'volume'),
           t.raw_record_id, t.ticker, t.trade_date_value, 'volume', t.volume
      FROM staging.v_raw_stock_prices_typed t
     CROSS JOIN LATERAL (VALUES ('DQ-VAL-003', t.volume_value < 0),
                                ('DQ-VAL-008', t.volume_value <> trunc(t.volume_value))) AS x(rule_id, failed)
     WHERE t.ingestion_batch_id = p_batch AND x.failed;

    -- DQ-COM-003 missing identifiers
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-COM-003', audit.make_issue_key('DQ-COM-003', coalesce(nullif(btrim(t.ticker), ''), 'price row ' || t.raw_record_id),
                                              t.trade_date, x.field),
           t.raw_record_id, t.ticker, t.trade_date_value, x.field, audit.show_value(x.val)
      FROM staging.v_raw_stock_prices_typed t
     CROSS JOIN LATERAL (VALUES ('ticker', t.ticker), ('trade_date', t.trade_date)) AS x(field, val)
     WHERE t.ingestion_batch_id = p_batch AND staging.is_blank(x.val);

    -- DQ-VAL-004 ticker not in universe
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-004', audit.make_issue_key('DQ-VAL-004', t.ticker, t.trade_date, 'ticker'),
           t.raw_record_id, t.ticker, t.trade_date_value, 'ticker', t.ticker
      FROM staging.v_raw_stock_prices_typed t
     WHERE t.ingestion_batch_id = p_batch AND NOT staging.is_blank(t.ticker)
       AND NOT EXISTS (SELECT 1 FROM ref.security_universe u WHERE u.ticker = t.ticker);

    -- DQ-VAL-005 unparseable date
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, affected_field, observed_value)
    SELECT 'DQ-VAL-005', audit.make_issue_key('DQ-VAL-005', t.ticker, t.trade_date, 'trade_date'),
           t.raw_record_id, t.ticker, 'trade_date', t.trade_date
      FROM staging.v_raw_stock_prices_typed t
     WHERE t.ingestion_batch_id = p_batch AND NOT staging.is_blank(t.trade_date) AND t.trade_date_value IS NULL;

    -- DQ-VAL-006 outside the snapshot window (includes future dates)
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-VAL-006', audit.make_issue_key('DQ-VAL-006', t.ticker, t.trade_date, 'trade_date'),
           t.raw_record_id, t.ticker, t.trade_date_value, 'trade_date', t.trade_date,
           'between ' || v_start || ' and ' || v_end
      FROM staging.v_raw_stock_prices_typed t
     WHERE t.ingestion_batch_id = p_batch AND t.trade_date_value NOT BETWEEN v_start AND v_end;

    -- DQ-VAL-007 weekend or exchange holiday
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-007', audit.make_issue_key('DQ-VAL-007', t.ticker, t.trade_date, 'trade_date'),
           t.raw_record_id, t.ticker, t.trade_date_value, 'trade_date',
           t.trade_date || ' (' || coalesce(c.holiday_name, trim(to_char(c.calendar_date, 'Day'))) || ')'
      FROM staging.v_raw_stock_prices_typed t
      JOIN ref.trading_calendar c ON c.exchange = 'XNYS' AND c.calendar_date = t.trade_date_value
     WHERE t.ingestion_batch_id = p_batch AND NOT c.is_trading_day;

    -- DQ-CNS-001/002/003 OHLC internal consistency
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT x.rule_id, audit.make_issue_key(x.rule_id, t.ticker, t.trade_date, x.field),
           t.raw_record_id, t.ticker, t.trade_date_value, x.field, x.observed
      FROM staging.v_raw_stock_prices_typed t
     CROSS JOIN LATERAL (VALUES
            ('DQ-CNS-001', 'high_price',  t.high_value < t.low_value,
             'high ' || t.high_value || ' < low ' || t.low_value),
            ('DQ-CNS-002', 'open_price',  t.open_value  NOT BETWEEN t.low_value AND t.high_value,
             'open ' || t.open_value || ' outside [' || t.low_value || ', ' || t.high_value || ']'),
            ('DQ-CNS-003', 'close_price', t.close_value NOT BETWEEN t.low_value AND t.high_value,
             'close ' || t.close_value || ' outside [' || t.low_value || ', ' || t.high_value || ']')
          ) AS x(rule_id, field, failed, observed)
     WHERE t.ingestion_batch_id = p_batch AND x.failed;
     -- NOT BETWEEN low AND high with low > high is always true, so a high<low row also
     -- fails CNS-002/003: one bad row, several failed rules (by design).

    -- DQ-COM-007 valid ticker but no validated company / DQ-CNS-004 currency mismatch
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-COM-007', audit.make_issue_key('DQ-COM-007', t.ticker, t.trade_date, 'ticker'),
           t.raw_record_id, t.ticker, t.trade_date_value, 'ticker', t.ticker, 'validated company exists'
      FROM staging.v_raw_stock_prices_typed t
      JOIN ref.security_universe u ON u.ticker = t.ticker
     WHERE t.ingestion_batch_id = p_batch
       AND NOT EXISTS (SELECT 1 FROM core.companies c WHERE c.ticker = t.ticker);

    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, company_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-CNS-004', audit.make_issue_key('DQ-CNS-004', t.ticker, t.trade_date, 'currency'),
           t.raw_record_id, c.company_id, t.ticker, t.trade_date_value, 'currency', t.currency_value,
           'currency = ' || c.currency
      FROM staging.v_raw_stock_prices_typed t
      JOIN core.companies c ON c.ticker = t.ticker
     WHERE t.ingestion_batch_id = p_batch AND t.currency_value IS DISTINCT FROM c.currency
       AND t.currency_value IS NOT NULL;

    -- DQ-UNI-001 / DQ-UNI-002 duplicate ticker+date within the batch
    WITH copies AS (
        SELECT t.*,
               row_number() OVER (PARTITION BY t.ticker, t.trade_date_value ORDER BY t.raw_record_id) AS copy_no,
               count(*)     OVER (PARTITION BY t.ticker, t.trade_date_value)                          AS copies
          FROM staging.v_raw_stock_prices_typed t
         WHERE t.ingestion_batch_id = p_batch
           AND NOT staging.is_blank(t.ticker) AND t.trade_date_value IS NOT NULL
    ),
    groups AS (   -- compare PARSED values, so '100' and '100.0' count as identical
        SELECT ticker, trade_date_value,
               count(DISTINCT (open_value, high_value, low_value, close_value,
                               adjusted_close_value, volume_value, currency_value)) AS versions
          FROM copies WHERE copies > 1
         GROUP BY ticker, trade_date_value
    )
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, ticker, trade_date, affected_field, observed_value)
    SELECT CASE WHEN g.versions = 1 THEN 'DQ-UNI-001' ELSE 'DQ-UNI-002' END,
           audit.make_issue_key(CASE WHEN g.versions = 1 THEN 'DQ-UNI-001' ELSE 'DQ-UNI-002' END,
                                c.ticker, c.trade_date_value::text, 'record'),
           c.raw_record_id, c.ticker, c.trade_date_value, 'record',
           c.copies || ' copies, ' || g.versions || ' distinct version(s)'
      FROM copies c JOIN groups g USING (ticker, trade_date_value)
     WHERE g.versions > 1 OR c.copy_no > 1;

    -- DQ-CNS-006 re-delivered values differ from production (record promoted from another batch)
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, company_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-CNS-006', audit.make_issue_key('DQ-CNS-006', t.ticker, t.trade_date_value::text, 'record'),
           t.raw_record_id, c.company_id, t.ticker, t.trade_date_value, 'record',
           concat_ws('; ',
               CASE WHEN core.to_reported_price(t.open_value)  <> p.open_price  THEN 'open '  || core.to_reported_price(t.open_value)  || ' vs ' || p.open_price  END,
               CASE WHEN core.to_reported_price(t.high_value)  <> p.high_price  THEN 'high '  || core.to_reported_price(t.high_value)  || ' vs ' || p.high_price  END,
               CASE WHEN core.to_reported_price(t.low_value)   <> p.low_price   THEN 'low '   || core.to_reported_price(t.low_value)   || ' vs ' || p.low_price   END,
               CASE WHEN core.to_reported_price(t.close_value) <> p.close_price THEN 'close ' || core.to_reported_price(t.close_value) || ' vs ' || p.close_price END,
               CASE WHEN abs(t.adjusted_close_value - p.adjusted_close) > audit.rule_threshold('DQ-CNS-006') * abs(p.adjusted_close)
                    THEN 'adj close ' || core.to_adjusted_price(t.adjusted_close_value) || ' vs ' || p.adjusted_close END,
               CASE WHEN t.volume_value <> p.volume THEN 'volume ' || t.volume_value || ' vs ' || p.volume END),
           'equal to production record from raw ' || p.raw_record_id
      FROM staging.v_raw_stock_prices_typed t
      JOIN core.companies c     ON c.ticker = t.ticker
      JOIN core.stock_prices p  ON p.company_id = c.company_id AND p.trade_date = t.trade_date_value
      JOIN staging.raw_stock_prices pr ON pr.raw_record_id = p.raw_record_id
     WHERE t.ingestion_batch_id = p_batch
       AND pr.ingestion_batch_id <> p_batch      -- production value came from an earlier batch
       AND num_nulls(t.open_value, t.high_value, t.low_value, t.close_value,
                     t.adjusted_close_value, t.volume_value) = 0
       AND (   (core.to_reported_price(t.open_value), core.to_reported_price(t.high_value),
                core.to_reported_price(t.low_value),  core.to_reported_price(t.close_value), t.volume_value)
               IS DISTINCT FROM
               (p.open_price, p.high_price, p.low_price, p.close_price, p.volume::numeric)
            -- Adjusted close is recomputed by the provider in float32 on every download, so
            -- 1-2 float32-step differences are noise, not revisions: relative tolerance from
            -- the rule catalogue (found by comparing two real downloads; see data_acquisition.md).
            OR abs(t.adjusted_close_value - p.adjusted_close)
               > audit.rule_threshold('DQ-CNS-006') * abs(p.adjusted_close));

    RETURN audit.record_violations(p_batch);
END;
$$;


-- =============================================================================
-- F. CORPORATE ACTION VALIDATION (batch_type = CORPORATE_ACTIONS)
-- =============================================================================
CREATE OR REPLACE FUNCTION audit.validate_action_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_start date;
    v_end   date;
BEGIN
    SELECT snapshot_start_date, snapshot_end_date INTO v_start, v_end
      FROM audit.ingestion_logs WHERE ingestion_batch_id = p_batch AND batch_type = 'CORPORATE_ACTIONS';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % is not a CORPORATE_ACTIONS batch', p_batch;
    END IF;

    PERFORM audit.begin_violations();

    -- DQ-COM-003 missing identifiers
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-COM-003', audit.make_issue_key('DQ-COM-003', coalesce(nullif(btrim(a.ticker), ''), 'action row ' || a.raw_action_id),
                                              a.action_date, x.field),
           a.raw_action_id, a.ticker, a.action_date_value, x.field, audit.show_value(x.val)
      FROM staging.v_raw_corporate_actions_typed a
     CROSS JOIN LATERAL (VALUES ('ticker', a.ticker), ('action_date', a.action_date)) AS x(field, val)
     WHERE a.ingestion_batch_id = p_batch AND staging.is_blank(x.val);

    -- DQ-VAL-004 ticker / DQ-VAL-005 date / DQ-VAL-006 window / DQ-VAL-007 non-trading date
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-004', audit.make_issue_key('DQ-VAL-004', a.ticker, a.action_date, 'ticker'),
           a.raw_action_id, a.ticker, a.action_date_value, 'ticker', a.ticker
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch AND NOT staging.is_blank(a.ticker)
       AND NOT EXISTS (SELECT 1 FROM ref.security_universe u WHERE u.ticker = a.ticker);

    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, affected_field, observed_value)
    SELECT 'DQ-VAL-005', audit.make_issue_key('DQ-VAL-005', a.ticker, a.action_date, 'action_date'),
           a.raw_action_id, a.ticker, 'action_date', a.action_date
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch AND NOT staging.is_blank(a.action_date) AND a.action_date_value IS NULL;

    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-VAL-006', audit.make_issue_key('DQ-VAL-006', a.ticker, a.action_date, 'action_date'),
           a.raw_action_id, a.ticker, a.action_date_value, 'action_date', a.action_date,
           'between ' || v_start || ' and ' || v_end
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch AND a.action_date_value NOT BETWEEN v_start AND v_end;

    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-007', audit.make_issue_key('DQ-VAL-007', a.ticker, a.action_date, 'action_date'),
           a.raw_action_id, a.ticker, a.action_date_value, 'action_date',
           a.action_date || ' (' || coalesce(c.holiday_name, trim(to_char(c.calendar_date, 'Day'))) || ')'
      FROM staging.v_raw_corporate_actions_typed a
      JOIN ref.trading_calendar c ON c.exchange = 'XNYS' AND c.calendar_date = a.action_date_value
     WHERE a.ingestion_batch_id = p_batch AND NOT c.is_trading_day;

    -- DQ-VAL-009 unsupported action type
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-009', audit.make_issue_key('DQ-VAL-009', a.ticker, a.action_date, 'action_type'),
           a.raw_action_id, a.ticker, a.action_date_value, 'action_type', audit.show_value(a.action_type)
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch
       AND (a.action_type IS NULL OR a.action_type NOT IN ('DIVIDEND', 'STOCK_SPLIT'));

    -- DQ-VAL-001 amount/ratio present but unparseable
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-001', audit.make_issue_key('DQ-VAL-001', a.ticker, a.action_date, x.field),
           a.raw_action_id, a.ticker, a.action_date_value, x.field, x.raw_value
      FROM staging.v_raw_corporate_actions_typed a
     CROSS JOIN LATERAL (VALUES ('dividend_amount', a.dividend_amount, a.dividend_value),
                                ('split_ratio',     a.split_ratio,     a.split_value)) AS x(field, raw_value, num_value)
     WHERE a.ingestion_batch_id = p_batch AND NOT staging.is_blank(x.raw_value)
       AND (x.num_value IS NULL OR abs(x.num_value) >= 1e12);

    -- DQ-VAL-010 invalid dividend / DQ-VAL-011 invalid split
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-010', audit.make_issue_key('DQ-VAL-010', a.ticker, a.action_date, 'dividend_amount'),
           a.raw_action_id, a.ticker, a.action_date_value, 'dividend_amount',
           'amount ' || audit.show_value(a.dividend_amount) || ', split ratio ' || audit.show_value(a.split_ratio)
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch AND a.action_type = 'DIVIDEND'
       AND (staging.is_blank(a.dividend_amount) OR a.dividend_value <= 0 OR NOT staging.is_blank(a.split_ratio));

    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-VAL-011', audit.make_issue_key('DQ-VAL-011', a.ticker, a.action_date, 'split_ratio'),
           a.raw_action_id, a.ticker, a.action_date_value, 'split_ratio',
           'ratio ' || audit.show_value(a.split_ratio) || ', dividend ' || audit.show_value(a.dividend_amount)
      FROM staging.v_raw_corporate_actions_typed a
     WHERE a.ingestion_batch_id = p_batch AND a.action_type = 'STOCK_SPLIT'
       AND (staging.is_blank(a.split_ratio) OR a.split_value <= 0 OR a.split_value = 1
            OR NOT staging.is_blank(a.dividend_amount));

    -- DQ-COM-007 no validated company for a valid ticker
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-COM-007', audit.make_issue_key('DQ-COM-007', a.ticker, a.action_date || '/' || a.action_type, 'ticker'),
           a.raw_action_id, a.ticker, a.action_date_value, 'ticker', a.ticker, 'validated company exists'
      FROM staging.v_raw_corporate_actions_typed a
      JOIN ref.security_universe u ON u.ticker = a.ticker
     WHERE a.ingestion_batch_id = p_batch
       AND NOT EXISTS (SELECT 1 FROM core.companies c WHERE c.ticker = a.ticker);

    -- DQ-UNI-003 / DQ-UNI-004 duplicate ticker+date+type within the batch
    WITH copies AS (
        SELECT a.*,
               row_number() OVER (PARTITION BY a.ticker, a.action_date_value, a.action_type ORDER BY a.raw_action_id) AS copy_no,
               count(*)     OVER (PARTITION BY a.ticker, a.action_date_value, a.action_type)                         AS copies
          FROM staging.v_raw_corporate_actions_typed a
         WHERE a.ingestion_batch_id = p_batch AND NOT staging.is_blank(a.ticker)
           AND a.action_date_value IS NOT NULL AND a.action_type IS NOT NULL
    ),
    groups AS (
        SELECT ticker, action_date_value, action_type,
               count(DISTINCT (dividend_value, split_value)) AS versions
          FROM copies WHERE copies > 1
         GROUP BY ticker, action_date_value, action_type
    )
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, ticker, trade_date, affected_field, observed_value)
    SELECT CASE WHEN g.versions = 1 THEN 'DQ-UNI-003' ELSE 'DQ-UNI-004' END,
           audit.make_issue_key(CASE WHEN g.versions = 1 THEN 'DQ-UNI-003' ELSE 'DQ-UNI-004' END,
                                c.ticker, c.action_date_value || '/' || c.action_type, 'record'),
           c.raw_action_id, c.ticker, c.action_date_value, 'record',
           c.copies || ' copies, ' || g.versions || ' distinct version(s)'
      FROM copies c JOIN groups g USING (ticker, action_date_value, action_type)
     WHERE g.versions > 1 OR c.copy_no > 1;

    -- DQ-CNS-006 re-delivered action differs from production
    INSERT INTO tmp_violations (rule_id, issue_key, raw_action_id, company_id, ticker, trade_date, affected_field, observed_value)
    SELECT 'DQ-CNS-006', audit.make_issue_key('DQ-CNS-006', a.ticker, a.action_date_value || '/' || a.action_type, 'record'),
           a.raw_action_id, c.company_id, a.ticker, a.action_date_value, 'record',
           'amount ' || coalesce(round(a.dividend_value, 6)::text, '-') || ' vs ' || coalesce(p.dividend_amount::text, '-')
           || ', ratio ' || coalesce(round(a.split_value, 6)::text, '-') || ' vs ' || coalesce(p.split_ratio::text, '-')
      FROM staging.v_raw_corporate_actions_typed a
      JOIN core.companies c ON c.ticker = a.ticker
      JOIN core.corporate_actions p ON p.company_id = c.company_id AND p.action_date = a.action_date_value
                                   AND p.action_type = a.action_type
      JOIN staging.raw_corporate_actions pr ON pr.raw_action_id = p.raw_action_id
     WHERE a.ingestion_batch_id = p_batch AND pr.ingestion_batch_id <> p_batch
       AND (round(a.dividend_value, 6), round(a.split_value, 6)) IS DISTINCT FROM (p.dividend_amount, p.split_ratio);

    RETURN audit.record_violations(p_batch);
END;
$$;


-- =============================================================================
-- G. POST-PROMOTION CHECKS for a PRICES batch
-- Run after prices AND corporate actions are promoted: they need validated history
-- (anomalies) and the corporate action calendar (cross-referencing).
-- =============================================================================
CREATE OR REPLACE FUNCTION audit.run_post_promotion_checks(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_start   date;
    v_end     date;
    v_loaded  date;
    v_tickers text[];
BEGIN
    SELECT snapshot_start_date, snapshot_end_date,
           (start_timestamp AT TIME ZONE 'America/New_York')::date,
           -- Expected tickers = what the batch requested; fall back to the active universe.
           coalesce((SELECT array_agg(x) FROM jsonb_array_elements_text(retrieval_parameters -> 'tickers_requested') x),
                    (SELECT array_agg(ticker) FROM ref.security_universe WHERE is_active))
      INTO v_start, v_end, v_loaded, v_tickers
      FROM audit.ingestion_logs WHERE ingestion_batch_id = p_batch AND batch_type = 'PRICES';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch % is not a PRICES batch', p_batch;
    END IF;

    PERFORM audit.begin_violations();

    -- DQ-COM-004 expected trading session with no raw record in ANY price batch.
    -- Expected = requested tickers x XNYS trading sessions in the window. Weekends and
    -- holidays are not trading sessions, so they can never be "missing".
    INSERT INTO tmp_violations (rule_id, issue_key, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-COM-004', audit.make_issue_key('DQ-COM-004', e.ticker, e.calendar_date::text, 'record'),
           e.ticker, e.calendar_date, 'record', 'no record received', 'raw record for XNYS session ' || e.calendar_date
      FROM (SELECT t.ticker, c.calendar_date
              FROM unnest(v_tickers) AS t(ticker)
             CROSS JOIN ref.trading_calendar c
             WHERE c.exchange = 'XNYS' AND c.is_trading_day
               AND c.calendar_date BETWEEN v_start AND v_end) e
     WHERE NOT EXISTS (SELECT 1 FROM staging.v_raw_stock_prices_typed r
                        WHERE r.ticker = e.ticker AND r.trade_date_value = e.calendar_date);

    -- DQ-TIM-002 latest expected session (last session on/before cutoff) not covered
    INSERT INTO tmp_violations (rule_id, issue_key, ticker, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-TIM-002', audit.make_issue_key('DQ-TIM-002', t.ticker, s.last_session::text, 'latest_session'),
           t.ticker, s.last_session, 'latest_session',
           'latest record: ' || coalesce((SELECT max(r.trade_date_value)::text FROM staging.v_raw_stock_prices_typed r
                                           WHERE r.ticker = t.ticker AND r.trade_date_value <= v_end), 'none'),
           'record for ' || s.last_session
      FROM unnest(v_tickers) AS t(ticker)
     CROSS JOIN (SELECT max(calendar_date) AS last_session FROM ref.trading_calendar
                  WHERE exchange = 'XNYS' AND is_trading_day AND calendar_date BETWEEN v_start AND v_end) s
     WHERE NOT EXISTS (SELECT 1 FROM staging.v_raw_stock_prices_typed r
                        WHERE r.ticker = t.ticker AND r.trade_date_value = s.last_session);

    -- DQ-TIM-001 load delay relative to the snapshot cutoff (never relative to today)
    INSERT INTO tmp_violations (rule_id, issue_key, trade_date, affected_field, observed_value, expected_condition)
    SELECT 'DQ-TIM-001', audit.make_issue_key('DQ-TIM-001', 'batch ' || p_batch, v_end::text, 'ingestion_timestamp'),
           v_end, 'ingestion_timestamp',
           (v_loaded - v_end) || ' calendar days after cutoff ' || v_end,
           '<= ' || audit.rule_threshold('DQ-TIM-001') || ' days'
     WHERE v_loaded - v_end > audit.rule_threshold('DQ-TIM-001');

    -- Anomaly and adjustment checks on VALIDATED prices. Returns and trailing volume come
    -- from the analytics views in 08_financial_analysis.sql (resolved when this function
    -- runs), so the quality framework and the dashboard share ONE definition of a daily
    -- return: gap-aware, i.e. a return spanning a missing session is not a one-session
    -- return and is not evaluated here.
    WITH returns AS (
        SELECT d.price_id, d.raw_record_id, d.company_id, d.ticker, d.trade_date, d.volume,
               d.session_no, d.prev_session_no, d.prev_trade_date AS prev_date,
               d.adjusted_close / d.close_price            AS ratio,
               d.prev_adjusted_close / d.prev_close_price  AS prev_ratio,
               d.daily_return_pct / 100                    AS one_day_return,
               v.avg_prev_20_volume, v.volume_ratio, v.is_unusual_volume
          FROM analytics.v_daily_returns d
          JOIN analytics.v_volume_analysis v ON v.raw_record_id = d.raw_record_id
    ),
    stats AS (
        SELECT r.*,
               stddev_samp(one_day_return) OVER w60 AS sd_prev_60,
               count(one_day_return)       OVER w60 AS n_prev_returns,
               (SELECT string_agg(a.action_type || coalesce(' ' || a.dividend_amount, '') ||
                                  coalesce(' ratio ' || a.split_ratio, ''), ', ')
                  FROM core.corporate_actions a
                 WHERE a.company_id = r.company_id AND a.action_date = r.trade_date) AS actions_on_date
          FROM returns r
        WINDOW w60 AS (PARTITION BY company_id ORDER BY trade_date ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING)
    ),
    -- The WHOLE validated series of the requested tickers is evaluated, not only this
    -- batch's records: a late-arriving record can close a gap and turn its neighbour's
    -- multi-session return into a true one-day return. Stable issue keys mean
    -- re-evaluation never duplicates issues. Each failure is attributed to the batch the
    -- raw record came from.
    flagged AS (
        SELECT s.*, pr.ingestion_batch_id AS record_batch_id FROM stats s
          JOIN staging.raw_stock_prices pr ON pr.raw_record_id = s.raw_record_id
         WHERE s.ticker = ANY (v_tickers)
    )
    INSERT INTO tmp_violations (rule_id, issue_key, raw_record_id, company_id, ticker, trade_date, affected_field,
                                observed_value, record_batch_id)
    SELECT x.rule_id, audit.make_issue_key(x.rule_id, f.ticker, f.trade_date::text, x.field),
           f.raw_record_id, f.company_id, f.ticker, f.trade_date, x.field, x.observed, f.record_batch_id
      FROM flagged f
     CROSS JOIN LATERAL (VALUES
        -- DQ-ANO-001 large one-session move
        ('DQ-ANO-001', 'adjusted_close',
         abs(f.one_day_return) * 100 > audit.rule_threshold('DQ-ANO-001'),
         to_char(f.one_day_return * 100, 'FMSG990.00') || '% vs ' || f.prev_date ||
         '; corporate action on date: ' || coalesce(f.actions_on_date, 'none')),
        -- DQ-ANO-002 volume spike vs trailing 20-record average
        ('DQ-ANO-002', 'volume',
         f.is_unusual_volume,       -- defined once in analytics.v_volume_analysis
         f.volume || ' = ' || to_char(f.volume_ratio, 'FM990.0')
                  || 'x trailing 20-record average ' || round(f.avg_prev_20_volume)),
        -- DQ-ANO-003 return extreme relative to the stock's own recent volatility
        ('DQ-ANO-003', 'adjusted_close',
         f.n_prev_returns >= 20 AND f.sd_prev_60 > 0
             AND abs(f.one_day_return) > audit.rule_threshold('DQ-ANO-003') * f.sd_prev_60,
         to_char(f.one_day_return * 100, 'FMSG990.00') || '% = ' ||
         to_char(abs(f.one_day_return) / nullif(f.sd_prev_60, 0), 'FM990.0') || ' sd (trailing sd ' ||
         to_char(f.sd_prev_60 * 100, 'FM990.00') || '%, n=' || f.n_prev_returns || ')'),
        -- DQ-CNS-007 adjustment ratio step on a day without a corporate action
        ('DQ-CNS-007', 'adjusted_close',
         f.session_no - f.prev_session_no = 1 AND f.actions_on_date IS NULL
             AND abs(f.ratio / f.prev_ratio - 1) > audit.rule_threshold('DQ-CNS-007'),
         'adj/close ratio ' || round(f.prev_ratio, 6) || ' -> ' || round(f.ratio, 6))
     ) AS x(rule_id, field, failed, observed)
     WHERE x.failed;

    -- Missing-session and latest-session issues whose record has since arrived are
    -- auto-resolved, so the open issue list reflects the current data.
    UPDATE audit.data_quality_issues i
       SET status = 'RESOLVED', resolved_at = now(),
           resolution_notes = concat_ws(' | ', i.resolution_notes,
                                        'Auto-resolved: record now received (checked in batch ' || p_batch || ')')
     WHERE i.rule_id IN ('DQ-COM-004', 'DQ-TIM-002')
       AND i.status IN ('OPEN', 'UNDER_REVIEW')
       AND NOT EXISTS (SELECT 1 FROM tmp_violations v WHERE v.issue_key = i.issue_key)
       AND EXISTS (SELECT 1 FROM staging.v_raw_stock_prices_typed r
                    WHERE r.ticker = i.ticker AND r.trade_date_value = i.trade_date);

    RETURN audit.record_violations(p_batch);
END;
$$;
