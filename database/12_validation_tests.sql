-- =============================================================================
-- 12_validation_tests.sql
-- Purpose : Run the quality framework on the synthetic fixtures and compare ACTUAL
--           results with the EXPECTED outcomes recorded in qa.fixture_expectations.
-- Phase   : 3 — Quality framework
-- Run     : scripts/run_quality_tests.sh (resets equityiq_test, loads 11, runs this)
--
-- Not wrapped in one transaction: the pipeline procedure commits per batch, exactly
-- as in production. Results are stored in qa.test_results and printed at the end.
-- Sections
--   1. Fixture expectations (rules fired + outcome, per fixture)
--   2. Batch count reconciliation and metrics sanity
--   3. Idempotency: re-validating the same batches changes nothing
--   4. Duplicate re-ingestion (identical new batch)
--   5. Provider revision (conflicting new batch) is held, not overwritten
--   6. Late-arriving missing session: auto-resolve + neighbour return re-evaluated
--   7. Issue workflow: dismiss / resolve / reopen / invalid transition
-- =============================================================================

\set ON_ERROR_STOP 1
\pset footer off

DO $$
BEGIN
    IF current_database() NOT LIKE '%test%' THEN
        RAISE EXCEPTION 'Refusing to run validation tests in database "%"', current_database();
    END IF;
END $$;

CREATE TABLE qa.test_results (
    test_no    serial PRIMARY KEY,
    section    text    NOT NULL,
    test_name  text    NOT NULL,
    expected   text,
    actual     text,
    passed     boolean NOT NULL
);

CREATE FUNCTION qa.check(p_section text, p_name text, p_expected text, p_actual text) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO qa.test_results (section, test_name, expected, actual, passed)
    VALUES (p_section, p_name, p_expected, p_actual, p_expected IS NOT DISTINCT FROM p_actual);
$$;

CREATE FUNCTION qa.batch(p_name text) RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT ingestion_batch_id FROM qa.fixture_batches WHERE batch_name = p_name;
$$;

-- Helper to add a new synthetic PRICES batch for a set of tickers.
CREATE FUNCTION qa.new_price_batch(p_name text, p_tickers text[]) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO audit.ingestion_logs (batch_type, source, retrieval_parameters, snapshot_start_date, snapshot_end_date,
                                      snapshot_label, status, end_timestamp)
    VALUES ('PRICES', 'synthetic_fixture',
            jsonb_build_object('tickers_requested', to_jsonb(p_tickers), 'note', 'SYNTHETIC TEST FIXTURE'),
            DATE '2025-11-24', DATE '2026-02-27', 'synthetic_fixture_' || lower(p_name), 'SUCCEEDED', now())
    RETURNING ingestion_batch_id INTO v_id;
    INSERT INTO qa.fixture_batches VALUES (p_name, v_id);
    RETURN v_id;
END;
$$;

CREATE FUNCTION qa.set_received(p_batch bigint) RETURNS void LANGUAGE sql AS $$
    UPDATE audit.ingestion_logs
       SET records_received = (SELECT count(*) FROM staging.raw_stock_prices WHERE ingestion_batch_id = p_batch)
     WHERE ingestion_batch_id = p_batch;
$$;

-- Snapshot of headline counts, used to prove "nothing changed".
CREATE FUNCTION qa.counts() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('issues=%s failures=%s companies=%s prices=%s actions=%s',
                  (SELECT count(*) FROM audit.data_quality_issues),
                  (SELECT count(*) FROM audit.rule_failures),
                  (SELECT count(*) FROM core.companies),
                  (SELECT count(*) FROM core.stock_prices),
                  (SELECT count(*) FROM core.corporate_actions));
$$;


-- =============================================================================
\echo '>>> Running the pipeline on fixture batches R1, P1, A1'
CALL audit.process_pending_batches();


-- =============================================================================
-- 1. FIXTURE EXPECTATIONS
-- =============================================================================
WITH actual AS (
    SELECT e.*,
           -- raw rows that belong to this fixture
           CASE e.dataset
             WHEN 'PRICE' THEN (SELECT array_agg(r.raw_record_id) FROM staging.raw_stock_prices r
                                 WHERE r.ingestion_batch_id = qa.batch(e.batch_name)
                                   AND r.ticker = e.ticker AND r.trade_date = e.record_key)
             WHEN 'ACTION' THEN (SELECT array_agg(a.raw_action_id) FROM staging.raw_corporate_actions a
                                  WHERE a.ingestion_batch_id = qa.batch(e.batch_name) AND a.ticker = e.ticker
                                    AND a.action_date || '|' || a.action_type = e.record_key)
             WHEN 'REFERENCE' THEN (SELECT array_agg(c.raw_reference_id) FROM staging.raw_company_reference c
                                     WHERE c.ingestion_batch_id = qa.batch(e.batch_name) AND c.ticker = e.ticker)
           END AS raw_ids
      FROM qa.fixture_expectations e
),
evaluated AS (
    SELECT a.*,
           -- rules that fired: record-level failures + record-less issues (missing sessions)
           coalesce((SELECT array_agg(DISTINCT x.rule_id ORDER BY x.rule_id) FROM (
                SELECT f.rule_id FROM audit.rule_failures f
                 WHERE (a.dataset = 'PRICE'     AND f.raw_record_id    = ANY (a.raw_ids))
                    OR (a.dataset = 'ACTION'    AND f.raw_action_id    = ANY (a.raw_ids))
                    OR (a.dataset = 'REFERENCE' AND f.raw_reference_id = ANY (a.raw_ids))
                UNION
                SELECT i.rule_id FROM audit.data_quality_issues i
                 WHERE a.dataset IN ('PRICE', 'NO_RECORD') AND i.raw_record_id IS NULL
                   AND i.ticker = a.ticker AND i.trade_date::text = a.record_key) x), '{}') AS actual_rules,
           -- outcomes of the raw rows
           (SELECT count(*) FROM unnest(a.raw_ids) id) AS n_rows,
           (SELECT count(*) FROM unnest(a.raw_ids) id JOIN audit.v_record_outcomes o
                ON o.raw_id = id AND o.record_kind = CASE a.dataset WHEN 'PRICE' THEN 'PRICE'
                                                     WHEN 'ACTION' THEN 'CORPORATE_ACTION' ELSE 'COMPANY_REFERENCE' END
             WHERE o.outcome = 'QUARANTINED') AS n_quarantined,
           (SELECT count(*) FROM unnest(a.raw_ids) id JOIN audit.v_record_outcomes o
                ON o.raw_id = id AND o.record_kind = CASE a.dataset WHEN 'PRICE' THEN 'PRICE'
                                                     WHEN 'ACTION' THEN 'CORPORATE_ACTION' ELSE 'COMPANY_REFERENCE' END
             WHERE o.outcome = 'REDUNDANT_DUPLICATE') AS n_redundant,
           -- was a record promoted to core from one of these raw rows?
           CASE a.dataset
             WHEN 'PRICE'     THEN EXISTS (SELECT 1 FROM core.stock_prices p WHERE p.raw_record_id = ANY (a.raw_ids))
             WHEN 'ACTION'    THEN EXISTS (SELECT 1 FROM core.corporate_actions p WHERE p.raw_action_id = ANY (a.raw_ids))
             WHEN 'REFERENCE' THEN EXISTS (SELECT 1 FROM core.companies p WHERE p.raw_reference_id = ANY (a.raw_ids))
             ELSE EXISTS (SELECT 1 FROM core.stock_prices p JOIN core.companies c USING (company_id)
                           WHERE c.ticker = a.ticker AND p.trade_date::text = a.record_key)
           END AS promoted
      FROM actual a
)
INSERT INTO qa.test_results (section, test_name, expected, actual, passed)
SELECT '1 fixtures', fixture_id || ' ' || description,
       expected_outcome || ' ' || expected_rules::text,
       actual_outcome   || ' ' || actual_rules::text,
       expected_outcome = actual_outcome AND expected_rules::text = actual_rules::text
  FROM (SELECT ev.*,
               CASE
                 WHEN n_rows = 0 AND promoted                         THEN 'PROMOTED'
                 WHEN n_rows = 0 AND cardinality(actual_rules) > 0    THEN 'ISSUE_ONLY'
                 WHEN n_rows = 0                                      THEN 'NOT_PROMOTED'
                 WHEN promoted AND n_redundant = n_rows - 1 AND n_rows > 1 THEN 'ONE_PROMOTED_REST_REDUNDANT'
                 WHEN promoted AND cardinality(actual_rules) > 0      THEN 'PROMOTED_FLAGGED'
                 WHEN promoted                                        THEN 'PROMOTED'
                 WHEN n_quarantined = n_rows                          THEN 'QUARANTINED'
                 ELSE 'NOT_PROMOTED'
               END AS actual_outcome
          FROM evaluated ev) t
 ORDER BY fixture_id;

-- Negative test over the whole window: no missing-session issue on any closed day.
SELECT qa.check('1 fixtures', 'N01 no DQ-COM-004 issue on any weekend or holiday', '0',
    (SELECT count(*)::text FROM audit.data_quality_issues i
       JOIN ref.trading_calendar c ON c.exchange = 'XNYS' AND c.calendar_date = i.trade_date
      WHERE i.rule_id = 'DQ-COM-004' AND NOT c.is_trading_day));

-- Exactly the seeded missing sessions are reported (JPM 01-13, XOM 02-27), nothing else.
SELECT qa.check('1 fixtures', 'N02 missing-session issues are exactly the 2 seeded gaps',
    'JPM 2026-01-13, XOM 2026-02-27',
    (SELECT string_agg(ticker || ' ' || trade_date, ', ' ORDER BY ticker) FROM audit.data_quality_issues
      WHERE rule_id = 'DQ-COM-004'));

-- No anomaly flags on any control-series record of AAPL and JNJ other than the seeded ones.
SELECT qa.check('1 fixtures', 'N03 anomaly rules fire only on seeded rows (XOM 01-14, JNJ 02-10, MSFT 02-03)',
    'JNJ 2026-02-10 DQ-ANO-002, MSFT 2026-02-03 DQ-ANO-003, XOM 2026-01-14 DQ-ANO-001, XOM 2026-01-14 DQ-ANO-003',
    (SELECT string_agg(ticker || ' ' || trade_date || ' ' || rule_id, ', ' ORDER BY ticker, trade_date, rule_id)
       FROM audit.data_quality_issues WHERE rule_id LIKE 'DQ-ANO-%'));

SELECT qa.check('1 fixtures', 'N04 timeliness: load delay vs snapshot cutoff flagged for P1 (batch-level, no record)',
    '1', (SELECT count(*)::text FROM audit.data_quality_issues
           WHERE rule_id = 'DQ-TIM-001' AND issue_key LIKE '%batch ' || qa.batch('P1') || '|%'));


-- =============================================================================
-- 2. BATCH COUNTS AND METRICS
-- =============================================================================
SELECT qa.check('2 counts', 'B' || l.ingestion_batch_id || ' ' || l.batch_type ||
                ': clean+flagged+quarantined+redundant+held = received',
                l.records_received::text,
                (m.clean + m.accepted_with_flags + m.quarantined + m.redundant_duplicates + m.held_for_review)::text)
  FROM audit.ingestion_logs l JOIN analytics.v_dq_batch_metrics m USING (ingestion_batch_id)
 WHERE l.source = 'synthetic_fixture';

SELECT qa.check('2 counts', 'B' || ingestion_batch_id || ' logged accepted/rejected/flagged match outcome view',
                format('%s/%s/%s', m.clean + m.accepted_with_flags, m.quarantined, m.accepted_with_flags),
                format('%s/%s/%s', l.records_accepted, l.records_rejected, l.records_flagged))
  FROM audit.ingestion_logs l JOIN analytics.v_dq_batch_metrics m USING (ingestion_batch_id)
 WHERE l.source = 'synthetic_fixture';

-- Hand-checkable pass rate for P1: records without a confirmed defect / records received.
SELECT qa.check('2 counts', 'P1 record pass rate equals manual calculation',
    (SELECT round(100.0 * (SELECT count(*) FROM staging.raw_stock_prices r
                            WHERE r.ingestion_batch_id = qa.batch('P1')
                              AND NOT EXISTS (SELECT 1 FROM audit.rule_failures f JOIN audit.data_quality_rules d USING (rule_id)
                                               WHERE f.raw_record_id = r.raw_record_id AND d.issue_class = 'CONFIRMED_DEFECT'))
                  / (SELECT count(*) FROM staging.raw_stock_prices WHERE ingestion_batch_id = qa.batch('P1')), 2)::text),
    (SELECT record_pass_rate_pct::text FROM analytics.v_dq_batch_metrics WHERE ingestion_batch_id = qa.batch('P1')));

SELECT qa.check('2 counts', 'Anomaly-only records count as passing (F08 XOM 01-14 not a confirmed defect)', 'false',
    (SELECT o.has_confirmed_defect::text FROM audit.v_record_outcomes o JOIN staging.raw_stock_prices r
        ON o.record_kind = 'PRICE' AND o.raw_id = r.raw_record_id
      WHERE r.ingestion_batch_id = qa.batch('P1') AND r.ticker = 'XOM' AND r.trade_date = '2026-01-14'));

SELECT qa.check('2 counts', 'Dimension scores: 7 rows, none NULL (non-zero denominators)', '7 rows, 0 null',
    (SELECT count(*) || ' rows, ' || count(*) FILTER (WHERE score_pct IS NULL) || ' null' FROM analytics.v_dq_dimension_scores));

SELECT qa.check('2 counts', 'Promoted reported prices are rounded to cents', '0',
    (SELECT count(*)::text FROM core.stock_prices WHERE scale(close_price) > 2 AND close_price <> round(close_price, 2)));


-- =============================================================================
-- 3. IDEMPOTENCY: re-validate R1, P1, A1 on purpose
-- =============================================================================
CREATE TEMP TABLE before_rerun AS SELECT qa.counts() AS c,
       (SELECT detection_count FROM audit.data_quality_issues WHERE rule_id = 'DQ-COM-001' AND ticker = 'MSFT') AS dc;

SELECT audit.revalidate_batch(qa.batch('R1'));
SELECT audit.revalidate_batch(qa.batch('P1'));
SELECT audit.revalidate_batch(qa.batch('A1'));

SELECT qa.check('3 idempotency', 'Re-validation leaves issue, failure and core counts unchanged',
                (SELECT c FROM before_rerun), qa.counts());
SELECT qa.check('3 idempotency', 'Re-detected issue: same row, detection_count incremented',
                ((SELECT dc FROM before_rerun) + 1)::text,
                (SELECT detection_count::text FROM audit.data_quality_issues WHERE rule_id = 'DQ-COM-001' AND ticker = 'MSFT'));


-- =============================================================================
-- 4. DUPLICATE RE-INGESTION: new batch P2 = identical copy of P1's AAPL rows
-- =============================================================================
CREATE TEMP TABLE before_p2 AS SELECT
    (SELECT count(*) FROM audit.data_quality_issues WHERE rule_id <> 'DQ-TIM-001') AS issues,
    (SELECT count(*) FROM core.stock_prices) AS prices;

SELECT qa.new_price_batch('P2', ARRAY['AAPL']);   -- create the batch once
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT qa.batch('P2'), source_row_number, ticker, trade_date, open_price, high_price, low_price,
       close_price, adjusted_close, volume, currency, source
  FROM staging.raw_stock_prices WHERE ingestion_batch_id = qa.batch('P1') AND ticker = 'AAPL';
SELECT qa.set_received(qa.batch('P2'));
CALL audit.process_pending_batches();

SELECT qa.check('4 re-ingestion', 'Identical re-delivery adds no production rows',
                (SELECT prices::text FROM before_p2), (SELECT count(*)::text FROM core.stock_prices));
SELECT qa.check('4 re-ingestion', 'Identical re-delivery adds no issues (other than its own batch timeliness)',
                (SELECT issues::text FROM before_p2),
                (SELECT count(*)::text FROM audit.data_quality_issues WHERE rule_id <> 'DQ-TIM-001'));
SELECT qa.check('4 re-ingestion', 'No revision conflicts raised for identical values', '0',
                (SELECT count(*)::text FROM audit.data_quality_issues WHERE rule_id = 'DQ-CNS-006'));
SELECT qa.check('4 re-ingestion', 'Duplicate defect in P2 maps to the SAME issue (detection_count >= 2)', 'true',
                (SELECT (detection_count >= 2)::text FROM audit.data_quality_issues
                  WHERE rule_id = 'DQ-UNI-001' AND ticker = 'AAPL'));
SELECT qa.check('4 re-ingestion', 'P2 failures attributed to P2 records (lineage per batch)', 'true',
                (SELECT (count(*) > 0)::text FROM audit.rule_failures WHERE ingestion_batch_id = qa.batch('P2')));


-- =============================================================================
-- 5. PROVIDER REVISION: P3 delivers a different close for AAPL 2026-01-05
-- =============================================================================
CREATE TEMP TABLE before_p3 AS
SELECT p.close_price FROM core.stock_prices p JOIN core.companies c USING (company_id)
 WHERE c.ticker = 'AAPL' AND p.trade_date = DATE '2026-01-05';

SELECT qa.new_price_batch('P3', ARRAY['AAPL']);   -- create the batch once
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT qa.batch('P3'), 1, ticker, trade_date, open_price, high_price, low_price,
       (close_price::numeric + 1)::text, adjusted_close, volume, currency, source
  FROM staging.raw_stock_prices WHERE ingestion_batch_id = qa.batch('P1') AND ticker = 'AAPL' AND trade_date = '2026-01-05';
SELECT qa.set_received(qa.batch('P3'));
CALL audit.process_pending_batches();

SELECT qa.check('5 revision', 'Conflicting re-delivery raises DQ-CNS-006', '1',
                (SELECT count(*)::text FROM audit.data_quality_issues WHERE rule_id = 'DQ-CNS-006'));
SELECT qa.check('5 revision', 'Production value NOT overwritten', (SELECT close_price::text FROM before_p3),
                (SELECT p.close_price::text FROM core.stock_prices p JOIN core.companies c USING (company_id)
                  WHERE c.ticker = 'AAPL' AND p.trade_date = DATE '2026-01-05'));
SELECT qa.check('5 revision', 'Revised record counted as held for review', '1',
                (SELECT held_for_review::text FROM analytics.v_dq_batch_metrics WHERE ingestion_batch_id = qa.batch('P3')));


-- =============================================================================
-- 6. LATE-ARRIVING MISSING SESSION: P4 delivers JPM 2026-01-13
-- =============================================================================
SELECT qa.new_price_batch('P4', ARRAY['JPM']);   -- create the batch once
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT qa.batch('P4'), 1, 'JPM', '2026-01-13',
       '249.50', '252.50', '247.50', '250.00', '250.00', '1000000', 'USD', 'synthetic_fixture';
SELECT qa.set_received(qa.batch('P4'));
CALL audit.process_pending_batches();

SELECT qa.check('6 late arrival', 'Missing-session issue auto-resolved', 'RESOLVED',
                (SELECT status FROM audit.data_quality_issues
                  WHERE rule_id = 'DQ-COM-004' AND ticker = 'JPM' AND trade_date = DATE '2026-01-13'));
SELECT qa.check('6 late arrival', 'Late record promoted to production', '1',
                (SELECT count(*)::text FROM core.stock_prices p JOIN core.companies c USING (company_id)
                  WHERE c.ticker = 'JPM' AND p.trade_date = DATE '2026-01-13'));
SELECT qa.check('6 late arrival', 'Gap closed: JPM 01-14 +20% is now a true one-day return and is flagged', 'DQ-ANO-001',
                (SELECT string_agg(rule_id, ',') FROM audit.data_quality_issues
                  WHERE ticker = 'JPM' AND trade_date = DATE '2026-01-14' AND rule_id = 'DQ-ANO-001'));
SELECT qa.check('6 late arrival', 'Neighbour flag attributed to the batch of the flagged record (P1)',
                qa.batch('P1')::text,
                (SELECT f.ingestion_batch_id::text FROM audit.rule_failures f JOIN audit.data_quality_issues i USING (issue_id)
                  WHERE i.rule_id = 'DQ-ANO-001' AND i.ticker = 'JPM' AND i.trade_date = DATE '2026-01-14'));


-- =============================================================================
-- 7. ISSUE WORKFLOW
-- =============================================================================
-- Analyst reviews the XOM +15% move and dismisses it as genuine.
SELECT audit.set_issue_status(issue_id, 'DISMISSED', 'Genuine level shift (synthetic test)')
  FROM audit.data_quality_issues WHERE rule_id = 'DQ-ANO-001' AND ticker = 'XOM';
-- Analyst resolves the MSFT null-close issue.
SELECT audit.set_issue_status(issue_id, 'RESOLVED', 'Record excluded; vendor notified (synthetic test)')
  FROM audit.data_quality_issues WHERE rule_id = 'DQ-COM-001' AND ticker = 'MSFT';

SELECT audit.revalidate_batch(qa.batch('P1'));

SELECT qa.check('7 workflow', 'Dismissed anomaly stays DISMISSED after re-validation', 'DISMISSED',
                (SELECT status FROM audit.data_quality_issues WHERE rule_id = 'DQ-ANO-001' AND ticker = 'XOM'));
SELECT qa.check('7 workflow', 'Resolved issue stays RESOLVED when the SAME batch is re-validated', 'RESOLVED',
                (SELECT status FROM audit.data_quality_issues WHERE rule_id = 'DQ-COM-001' AND ticker = 'MSFT'));

-- A NEW batch re-delivers the same defect -> the resolved issue reopens.
SELECT qa.new_price_batch('P5', ARRAY['MSFT']);   -- create the batch once
INSERT INTO staging.raw_stock_prices (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price,
                                      low_price, close_price, adjusted_close, volume, currency, source)
SELECT qa.batch('P5'), 1, ticker, trade_date, open_price, high_price, low_price,
       close_price, adjusted_close, volume, currency, source
  FROM staging.raw_stock_prices WHERE ingestion_batch_id = qa.batch('P1') AND ticker = 'MSFT' AND trade_date = '2026-01-08';
SELECT qa.set_received(qa.batch('P5'));
CALL audit.process_pending_batches();

SELECT qa.check('7 workflow', 'Resolved issue REOPENS when a new batch repeats the defect', 'OPEN',
                (SELECT status FROM audit.data_quality_issues WHERE rule_id = 'DQ-COM-001' AND ticker = 'MSFT'));

DO $$
BEGIN
    PERFORM audit.set_issue_status(issue_id, 'RESOLVED', 'should fail')
       FROM audit.data_quality_issues WHERE rule_id = 'DQ-ANO-001' AND ticker = 'XOM';
    PERFORM qa.check('7 workflow', 'Invalid transition DISMISSED -> RESOLVED rejected', 'error 23514', 'no error');
EXCEPTION WHEN check_violation THEN
    PERFORM qa.check('7 workflow', 'Invalid transition DISMISSED -> RESOLVED rejected', 'error 23514', 'error 23514');
END $$;


-- =============================================================================
-- RESULTS
-- =============================================================================
\echo
\echo '=== Phase 3 validation test results (synthetic fixtures) ==='
SELECT test_no AS "#", section, left(test_name, 75) AS test, left(expected, 48) AS expected,
       left(actual, 48) AS actual, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM qa.test_results ORDER BY test_no;

SELECT section, count(*) AS tests, count(*) FILTER (WHERE passed) AS passed, count(*) FILTER (WHERE NOT passed) AS failed
  FROM qa.test_results GROUP BY section ORDER BY section;

SELECT count(*) AS total_tests, count(*) FILTER (WHERE passed) AS passed, count(*) FILTER (WHERE NOT passed) AS failed
  FROM qa.test_results;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM qa.test_results WHERE NOT passed) THEN
        RAISE EXCEPTION 'Validation tests FAILED: % failing test(s)', (SELECT count(*) FROM qa.test_results WHERE NOT passed);
    END IF;
END $$;
