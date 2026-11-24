-- =============================================================================
-- 07_data_transformation.sql
-- Purpose : Promote validated staging records to core, quarantine critical failures,
--           maintain batch counts, and orchestrate the whole validation pipeline.
-- Phase   : 3 — Quality framework
-- Idempotent: yes
--
-- Entry point:   CALL audit.process_pending_batches();
--   Processes every loaded batch not yet validated, in dependency order:
--   calendar -> company reference -> prices -> corporate actions -> post-promotion checks.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Record outcome: the single definition of what happens to each raw record.
-- Records with no rule failures do not appear here (they are CLEAN).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_record_outcomes AS
WITH failures AS (
    SELECT CASE WHEN f.raw_record_id    IS NOT NULL THEN 'PRICE'
                WHEN f.raw_action_id    IS NOT NULL THEN 'CORPORATE_ACTION'
                ELSE 'COMPANY_REFERENCE' END                         AS record_kind,
           coalesce(f.raw_record_id, f.raw_action_id, f.raw_reference_id) AS raw_id,
           f.rule_id, r.handling, r.issue_class, r.severity
      FROM audit.rule_failures f
      JOIN audit.data_quality_rules r ON r.rule_id = f.rule_id
)
SELECT record_kind,
       raw_id,
       CASE
         WHEN bool_or(handling = 'QUARANTINE')                                   THEN 'QUARANTINED'
         WHEN bool_or(rule_id IN ('DQ-UNI-001', 'DQ-UNI-003', 'DQ-UNI-005'))     THEN 'REDUNDANT_DUPLICATE'
         WHEN bool_or(rule_id = 'DQ-CNS-006')                                    THEN 'HELD_FOR_REVIEW'
         ELSE 'ACCEPTED_WITH_FLAGS'
       END                                                         AS outcome,
       bool_or(issue_class = 'CONFIRMED_DEFECT')                   AS has_confirmed_defect,
       array_agg(DISTINCT rule_id ORDER BY rule_id)                AS failed_rules,
       count(*)                                                    AS failure_count
  FROM failures
 GROUP BY record_kind, raw_id;

COMMENT ON VIEW audit.v_record_outcomes IS
  'Outcome per raw record with at least one rule failure: QUARANTINED, REDUNDANT_DUPLICATE, HELD_FOR_REVIEW or ACCEPTED_WITH_FLAGS. Absent = CLEAN.';


-- -----------------------------------------------------------------------------
-- Promotion functions. Each returns the number of rows inserted or changed in core.
-- -----------------------------------------------------------------------------

-- Company reference: reference data describes the CURRENT state of a company, so a
-- newer validated record updates the security master (type-1 change). The previous
-- version stays in staging and is still reachable through lineage.
CREATE OR REPLACE FUNCTION audit.promote_reference_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO core.companies AS c
          (ticker, company_name, sector, provider_sector, industry, exchange, currency, source, raw_reference_id)
    SELECT DISTINCT ON (r.ticker)
           r.ticker, btrim(r.company_name), u.assigned_sector, nullif(btrim(r.sector), ''),
           nullif(btrim(r.industry), ''), btrim(r.exchange), btrim(r.currency), r.source, r.raw_reference_id
      FROM staging.raw_company_reference r
      JOIN ref.security_universe u ON u.ticker = r.ticker
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'COMPANY_REFERENCE' AND o.raw_id = r.raw_reference_id
     WHERE r.ingestion_batch_id = p_batch
       AND (o.outcome IS NULL OR o.outcome = 'ACCEPTED_WITH_FLAGS')
     ORDER BY r.ticker, r.raw_reference_id
    ON CONFLICT (ticker) DO UPDATE SET
           company_name     = EXCLUDED.company_name,
           provider_sector  = EXCLUDED.provider_sector,
           industry         = EXCLUDED.industry,
           exchange         = EXCLUDED.exchange,
           currency         = EXCLUDED.currency,
           source           = EXCLUDED.source,
           raw_reference_id = EXCLUDED.raw_reference_id
     -- Only touch the row when something actually changed (keeps updated_at meaningful).
     WHERE (c.company_name, c.provider_sector, c.industry, c.exchange, c.currency)
           IS DISTINCT FROM
           (EXCLUDED.company_name, EXCLUDED.provider_sector, EXCLUDED.industry, EXCLUDED.exchange, EXCLUDED.currency);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Prices: insert-only. An existing production record is never overwritten here:
-- identical re-deliveries are no-ops (ON CONFLICT DO NOTHING) and differing ones were
-- already HELD_FOR_REVIEW by rule DQ-CNS-006.
CREATE OR REPLACE FUNCTION audit.promote_price_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO core.stock_prices
          (company_id, trade_date, open_price, high_price, low_price, close_price, adjusted_close,
           volume, source, ingestion_timestamp, raw_record_id)
    SELECT c.company_id, t.trade_date_value,
           core.to_reported_price(t.open_value),  core.to_reported_price(t.high_value),
           core.to_reported_price(t.low_value),   core.to_reported_price(t.close_value),
           core.to_adjusted_price(t.adjusted_close_value),
           t.volume_value::bigint, t.source, t.ingestion_timestamp, t.raw_record_id
      FROM staging.v_raw_stock_prices_typed t
      JOIN core.companies c ON c.ticker = t.ticker
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'PRICE' AND o.raw_id = t.raw_record_id
     WHERE t.ingestion_batch_id = p_batch
       AND (o.outcome IS NULL OR o.outcome = 'ACCEPTED_WITH_FLAGS')
    ON CONFLICT (company_id, trade_date) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION audit.promote_action_batch(p_batch bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO core.corporate_actions
          (company_id, action_date, action_type, dividend_amount, split_ratio, source, ingestion_timestamp, raw_action_id)
    SELECT c.company_id, a.action_date_value, a.action_type,
           round(a.dividend_value, 6), round(a.split_value, 6), a.source, a.ingestion_timestamp, a.raw_action_id
      FROM staging.v_raw_corporate_actions_typed a
      JOIN core.companies c ON c.ticker = a.ticker
      LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'CORPORATE_ACTION' AND o.raw_id = a.raw_action_id
     WHERE a.ingestion_batch_id = p_batch
       AND (o.outcome IS NULL OR o.outcome = 'ACCEPTED_WITH_FLAGS')
    ON CONFLICT (company_id, action_date, action_type) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;


-- -----------------------------------------------------------------------------
-- Batch counts (definitions documented in docs/data_quality_framework.md):
--   rejected = records QUARANTINED
--   accepted = records CLEAN or ACCEPTED_WITH_FLAGS (business record promoted or already
--              identical in production); excludes redundant duplicates and held records
--   flagged  = accepted records that carry at least one warning/anomaly failure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.refresh_batch_counts(p_batch bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_type text;
BEGIN
    SELECT batch_type INTO v_type FROM audit.ingestion_logs WHERE ingestion_batch_id = p_batch;

    IF v_type = 'TRADING_CALENDAR' THEN
        UPDATE audit.ingestion_logs SET validated_at = now() WHERE ingestion_batch_id = p_batch;
        RETURN;
    END IF;

    WITH records AS (
        SELECT o.outcome
          FROM staging.raw_stock_prices r
          LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'PRICE' AND o.raw_id = r.raw_record_id
         WHERE v_type = 'PRICES' AND r.ingestion_batch_id = p_batch
        UNION ALL
        SELECT o.outcome
          FROM staging.raw_corporate_actions r
          LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'CORPORATE_ACTION' AND o.raw_id = r.raw_action_id
         WHERE v_type = 'CORPORATE_ACTIONS' AND r.ingestion_batch_id = p_batch
        UNION ALL
        SELECT o.outcome
          FROM staging.raw_company_reference r
          LEFT JOIN audit.v_record_outcomes o ON o.record_kind = 'COMPANY_REFERENCE' AND o.raw_id = r.raw_reference_id
         WHERE v_type = 'COMPANY_REFERENCE' AND r.ingestion_batch_id = p_batch
    )
    UPDATE audit.ingestion_logs l
       SET records_rejected = x.rejected,
           records_accepted = x.accepted,
           records_flagged  = x.flagged,
           validated_at     = now()
      FROM (SELECT count(*) FILTER (WHERE outcome = 'QUARANTINED')                                  AS rejected,
                   count(*) FILTER (WHERE outcome IS NULL OR outcome = 'ACCEPTED_WITH_FLAGS')       AS accepted,
                   count(*) FILTER (WHERE outcome = 'ACCEPTED_WITH_FLAGS')                          AS flagged
              FROM records) x
     WHERE l.ingestion_batch_id = p_batch;
END;
$$;


-- -----------------------------------------------------------------------------
-- Orchestration
-- -----------------------------------------------------------------------------

-- Update planner statistics for the tables the pipeline changes (ANALYZE is allowed
-- inside a transaction; VACUUM is not, and is left to autovacuum).
CREATE OR REPLACE FUNCTION audit.analyze_project_tables()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    ANALYZE ref.trading_calendar, staging.raw_stock_prices, staging.raw_corporate_actions,
            staging.raw_company_reference, core.companies, core.stock_prices, core.corporate_actions,
            audit.ingestion_logs, audit.rule_failures, audit.data_quality_issues;
END;
$$;

-- Validate and promote one batch. Safe to call again on the same batch: issues are
-- upserted, failures de-duplicated and promotion is insert-if-absent.
CREATE OR REPLACE FUNCTION audit.process_batch(p_batch bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_type       text;
    v_violations integer := 0;
    v_promoted   integer := 0;
BEGIN
    SELECT batch_type INTO v_type
      FROM audit.ingestion_logs
     WHERE ingestion_batch_id = p_batch AND status IN ('SUCCEEDED', 'PARTIAL');
    IF v_type IS NULL THEN
        RAISE EXCEPTION 'Batch % does not exist or was not loaded successfully', p_batch;
    END IF;

    CASE v_type
        WHEN 'TRADING_CALENDAR'  THEN NULL;   -- reference data, loaded directly into ref
        WHEN 'COMPANY_REFERENCE' THEN
            v_violations := audit.validate_reference_batch(p_batch);
            v_promoted   := audit.promote_reference_batch(p_batch);
        WHEN 'PRICES' THEN
            v_violations := audit.validate_price_batch(p_batch);
            v_promoted   := audit.promote_price_batch(p_batch);
        WHEN 'CORPORATE_ACTIONS' THEN
            v_violations := audit.validate_action_batch(p_batch);
            v_promoted   := audit.promote_action_batch(p_batch);
        ELSE
            RAISE EXCEPTION 'Unsupported batch type % for batch %', v_type, p_batch;
    END CASE;

    PERFORM audit.refresh_batch_counts(p_batch);
    RETURN format('batch %s %s: %s violations, %s rows promoted', p_batch, v_type, v_violations, v_promoted);
END;
$$;

-- Process every successfully loaded, not-yet-validated batch in dependency order, then
-- run post-promotion checks for the new price batches. Each batch commits separately,
-- so a failure stops the run but leaves earlier batches processed and auditable.
CREATE OR REPLACE PROCEDURE audit.process_pending_batches()
LANGUAGE plpgsql AS $$
DECLARE
    b         record;
    v_msg     text;
    v_prices  bigint[] := '{}';
    v_batch   bigint;
    v_n       integer;
BEGIN
    FOR b IN
        SELECT ingestion_batch_id, batch_type
          FROM audit.ingestion_logs
         WHERE validated_at IS NULL AND status IN ('SUCCEEDED', 'PARTIAL')
         ORDER BY CASE batch_type WHEN 'TRADING_CALENDAR' THEN 1 WHEN 'COMPANY_REFERENCE' THEN 2
                                  WHEN 'PRICES' THEN 3 WHEN 'CORPORATE_ACTIONS' THEN 4 ELSE 5 END,
                  ingestion_batch_id
    LOOP
        v_msg := audit.process_batch(b.ingestion_batch_id);
        RAISE NOTICE '%', v_msg;
        IF b.batch_type = 'PRICES' THEN
            v_prices := v_prices || b.ingestion_batch_id;
        END IF;
        COMMIT;
    END LOOP;

    -- Refresh planner statistics after bulk changes. Without them PostgreSQL guesses that
    -- freshly loaded tables are tiny and can pick plans that are ~1,000x slower (measured:
    -- dimension scores view 3,330 ms before vs 2.5 ms after ANALYZE on the test database).
    PERFORM audit.analyze_project_tables();
    COMMIT;

    FOREACH v_batch IN ARRAY v_prices LOOP
        v_n := audit.run_post_promotion_checks(v_batch);
        RAISE NOTICE 'batch % post-promotion checks: % violations', v_batch, v_n;
        COMMIT;
    END LOOP;

    -- Post-promotion checks can add flags to records of EARLIER price batches (see 06, G),
    -- so refresh the counts of every validated price batch.
    IF cardinality(v_prices) > 0 THEN
        PERFORM audit.refresh_batch_counts(ingestion_batch_id)
           FROM audit.ingestion_logs
          WHERE batch_type = 'PRICES' AND validated_at IS NOT NULL;
        PERFORM audit.analyze_project_tables();   -- issues/failures changed again
        COMMIT;
    END IF;
END;
$$;

-- Re-run validation for one batch on purpose (used to prove idempotency).
CREATE OR REPLACE FUNCTION audit.revalidate_batch(p_batch bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_msg text;
BEGIN
    v_msg := audit.process_batch(p_batch);
    IF (SELECT batch_type FROM audit.ingestion_logs WHERE ingestion_batch_id = p_batch) = 'PRICES' THEN
        v_msg := v_msg || format('; post-promotion: %s violations', audit.run_post_promotion_checks(p_batch));
        PERFORM audit.refresh_batch_counts(ingestion_batch_id)
           FROM audit.ingestion_logs WHERE batch_type = 'PRICES' AND validated_at IS NOT NULL;
    END IF;
    RETURN v_msg;
END;
$$;
