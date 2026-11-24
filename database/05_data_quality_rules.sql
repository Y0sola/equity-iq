-- =============================================================================
-- 05_data_quality_rules.sql
-- Purpose : The central data quality rule catalogue.
-- Phase   : 3 — Quality framework
-- Idempotent: yes (UPSERT)
--
-- Each rule has:
--   severity    CRITICAL = record unusable as-is; WARNING = usable but needs attention;
--               INFO = informational.
--   issue_class CONFIRMED_DEFECT = the data is wrong.
--               REVIEWABLE_ANOMALY = unusual, possibly genuine; a person must decide.
--   handling    QUARANTINE = record is NOT promoted to core.
--               ACCEPT_WITH_WARNING = business record promoted; issue logged.
--               FLAG_FOR_REVIEW = logged for an analyst; never auto-discarded.
--
-- The SQL that implements each rule is in 06_data_validation.sql (search for the rule id).
-- Thresholds live here (threshold_value) so they are documented data, not magic numbers.
-- =============================================================================

INSERT INTO audit.data_quality_rules
    (rule_id, rule_name, rule_category, severity, issue_class, handling, threshold_value,
     target_table, rule_description, expected_condition, business_justification)
VALUES
-- ---------------------------------------------------------------- COMPLETENESS
('DQ-COM-001', 'missing_required_price', 'COMPLETENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Open, high, low, close or adjusted close is null or blank.',
 'All five price fields are present.',
 'A daily record without prices cannot support returns, ranges or valuation; filling it would invent data.'),

('DQ-COM-002', 'missing_volume', 'COMPLETENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Volume is null or blank.',
 'Volume is present.',
 'Volume drives liquidity analysis and volume-spike checks; zero and missing mean different things.'),

('DQ-COM-003', 'missing_identifier', 'COMPLETENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging (all raw tables)',
 'Ticker or date is null or blank.',
 'Ticker and date (where applicable) are present.',
 'Without its business key a record cannot be attributed to a security or a session.'),

('DQ-COM-004', 'missing_trading_session', 'COMPLETENESS', 'WARNING', 'CONFIRMED_DEFECT', 'FLAG_FOR_REVIEW', NULL,
 'ref.trading_calendar vs staging.raw_stock_prices',
 'A requested ticker has no raw price record for an exchange trading session inside the snapshot window. Weekends and holidays are never expected.',
 'One raw record per requested ticker per XNYS trading session in the window.',
 'Gaps silently turn multi-day moves into apparent one-day returns and bias averages.'),

('DQ-COM-005', 'missing_required_reference_field', 'COMPLETENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_company_reference',
 'Company name, exchange or currency is null or blank.',
 'Company name, exchange and currency are present.',
 'The security master must identify the company, where it trades and the price currency.'),

('DQ-COM-006', 'missing_optional_reference_field', 'COMPLETENESS', 'WARNING', 'CONFIRMED_DEFECT', 'ACCEPT_WITH_WARNING', NULL,
 'staging.raw_company_reference',
 'Provider sector or industry is null or blank.',
 'Provider sector and industry are present.',
 'Useful for classification checks but not required: analysis uses the project-assigned sector.'),

('DQ-COM-007', 'missing_company_reference', 'COMPLETENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices / raw_corporate_actions',
 'A price or corporate action refers to a valid ticker that has no validated company record.',
 'A validated core.companies row exists for the ticker.',
 'Market data cannot be attributed to a company whose own reference data failed validation.'),

-- ---------------------------------------------------------------- UNIQUENESS
('DQ-UNI-001', 'exact_duplicate_price', 'UNIQUENESS', 'WARNING', 'CONFIRMED_DEFECT', 'ACCEPT_WITH_WARNING', NULL,
 'staging.raw_stock_prices',
 'The same ticker and date appear more than once in a batch with identical values. The first copy (lowest raw_record_id) is promoted; the redundant copies are not.',
 'One raw record per ticker and date per batch.',
 'Identical duplicates are harmless once removed, but double-count volume and observations if not.'),

('DQ-UNI-002', 'conflicting_duplicate_price', 'UNIQUENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'The same ticker and date appear more than once in a batch with different values. All copies are quarantined.',
 'One raw record per ticker and date per batch.',
 'When the source contradicts itself we cannot know which value is right, so neither is published.'),

('DQ-UNI-003', 'exact_duplicate_corporate_action', 'UNIQUENESS', 'WARNING', 'CONFIRMED_DEFECT', 'ACCEPT_WITH_WARNING', NULL,
 'staging.raw_corporate_actions',
 'The same ticker, date and action type appear more than once with identical values. First copy promoted.',
 'One record per ticker, date and action type per batch.',
 'A doubled dividend would double the income attributed to shareholders.'),

('DQ-UNI-004', 'conflicting_duplicate_corporate_action', 'UNIQUENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_corporate_actions',
 'The same ticker, date and action type appear more than once with different amounts or ratios. All copies quarantined.',
 'One record per ticker, date and action type per batch.',
 'Conflicting dividend amounts or split ratios cannot be resolved without a second source.'),

('DQ-UNI-005', 'exact_duplicate_reference', 'UNIQUENESS', 'WARNING', 'CONFIRMED_DEFECT', 'ACCEPT_WITH_WARNING', NULL,
 'staging.raw_company_reference',
 'A ticker appears more than once in a reference batch with identical values. First copy promoted.',
 'One reference record per ticker per batch.',
 'A security master must have exactly one row per security.'),

('DQ-UNI-006', 'conflicting_duplicate_reference', 'UNIQUENESS', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_company_reference',
 'A ticker appears more than once in a reference batch with different values. All copies quarantined.',
 'One reference record per ticker per batch.',
 'Two different names or currencies for one ticker is an identity conflict.'),

-- ---------------------------------------------------------------- VALIDITY
('DQ-VAL-001', 'unparseable_numeric', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging (all raw tables)',
 'A price, volume, dividend or split value is present but is not a finite number (e.g. "abc", "NaN").',
 'Numeric fields parse as finite numbers.',
 'Unparseable values would either crash calculations or be silently converted to something else.'),

('DQ-VAL-002', 'non_positive_price', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'A price field is zero or negative.',
 'All prices > 0.',
 'Listed equities cannot trade at or below zero; such a value is a data error.'),

('DQ-VAL-003', 'negative_volume', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Volume is negative.',
 'Volume >= 0.',
 'Shares traded cannot be negative.'),

('DQ-VAL-004', 'invalid_ticker', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging (all raw tables)',
 'Ticker is not in ref.security_universe (e.g. typo APPL, wrong case, unknown symbol).',
 'Ticker exists in the tracked security universe.',
 'Unknown identifiers cannot be mapped to a security; mis-mapping would corrupt another security.'),

('DQ-VAL-005', 'invalid_date', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging (all raw tables with dates)',
 'Date is present but is not a valid ISO date (YYYY-MM-DD).',
 'Date parses as an ISO calendar date.',
 'Ambiguous or impossible dates (2026-13-45, 03/04/2026) cannot be placed on the timeline reliably.'),

('DQ-VAL-006', 'date_outside_snapshot_window', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging (all raw tables with dates)',
 'Date falls before the snapshot start or after the snapshot end (including future dates).',
 'snapshot_start_date <= date <= snapshot_end_date of the batch.',
 'Records outside the requested period indicate a request or provider error and break period metrics.'),

('DQ-VAL-007', 'non_trading_date', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices / raw_corporate_actions',
 'A price or ex-date falls on a weekend or exchange holiday per ref.trading_calendar.',
 'Date is an XNYS trading session.',
 'No regular-session trading occurs on closed days, so a record dated then is mis-dated.'),

('DQ-VAL-008', 'non_integer_volume', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Volume has a fractional part.',
 'Volume is a whole number of shares.',
 'Fractional share volume indicates a unit or parsing error.'),

('DQ-VAL-009', 'invalid_action_type', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_corporate_actions',
 'Action type is not DIVIDEND or STOCK_SPLIT.',
 'action_type IN (DIVIDEND, STOCK_SPLIT).',
 'Unsupported event types cannot be interpreted or applied consistently.'),

('DQ-VAL-010', 'invalid_dividend_amount', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_corporate_actions',
 'A DIVIDEND has a missing, zero or negative amount, or also carries a split ratio.',
 'dividend_amount > 0 and split_ratio is empty.',
 'An invalid dividend misstates shareholder income and the adjusted price series.'),

('DQ-VAL-011', 'invalid_split_ratio', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_corporate_actions',
 'A STOCK_SPLIT has a missing, zero, negative or 1:1 ratio, or also carries a dividend amount.',
 'split_ratio > 0, split_ratio <> 1, dividend_amount is empty.',
 'A wrong split ratio distorts every pre-split price by that factor.'),

('DQ-VAL-012', 'invalid_currency_code', 'VALIDITY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_company_reference',
 'Currency is not a three-letter upper-case ISO 4217-style code.',
 'currency ~ ^[A-Z]{3}$',
 'Prices are meaningless without a reliable currency.'),

-- ---------------------------------------------------------------- CONSISTENCY
('DQ-CNS-001', 'high_below_low', 'CONSISTENCY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'High price is below low price.',
 'high_price >= low_price',
 'By definition the high is the highest trade of the day; violation proves the record is wrong.'),

('DQ-CNS-002', 'open_outside_range', 'CONSISTENCY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Open price lies outside the day''s low-high range.',
 'low_price <= open_price <= high_price',
 'The opening trade is one of the day''s trades, so it must lie within the range.'),

('DQ-CNS-003', 'close_outside_range', 'CONSISTENCY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices',
 'Close price lies outside the day''s low-high range.',
 'low_price <= close_price <= high_price',
 'The closing price must lie within the day''s range.'),

('DQ-CNS-004', 'price_currency_mismatch', 'CONSISTENCY', 'CRITICAL', 'CONFIRMED_DEFECT', 'QUARANTINE', NULL,
 'staging.raw_stock_prices vs core.companies',
 'Currency on the price record differs from the validated company currency.',
 'price currency = company currency',
 'Mixing currencies in one series produces false returns.'),

('DQ-CNS-005', 'provider_sector_mismatch', 'CONSISTENCY', 'INFO', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', NULL,
 'staging.raw_company_reference vs ref.security_universe',
 'Provider sector, mapped through ref.sector_mapping, differs from the project-assigned sector, or is unmapped.',
 'mapped provider sector = assigned sector',
 'Classification disagreements change sector aggregates; a person should confirm which is intended.'),

('DQ-CNS-006', 'source_value_conflict', 'CONSISTENCY', 'WARNING', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', 0.000001,
 'staging.raw_stock_prices vs core.stock_prices',
 'A later batch delivers different values for a record already in production. The production value is kept and the new value is held for review, never silently overwritten. Reported OHLC (cents) and volume must match exactly; adjusted close, a value the provider recomputes in 32-bit floating point, is compared with a relative tolerance (threshold 1e-6, about 8 float32 steps): two downloads 2h45m apart differed in 904 adjusted closes by only 1-2 float32 steps (max 2.4e-7 relative).',
 'Re-delivered reported prices and volume equal production; |adjusted close difference| <= 1e-6 x production adjusted close.',
 'Vendor revisions must be visible and approved; silent overwrites destroy auditability.'),

('DQ-CNS-007', 'adjustment_step_without_action', 'CONSISTENCY', 'WARNING', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', 0.00001,
 'core.stock_prices vs core.corporate_actions',
 'The adjusted/reported close ratio changes between consecutive sessions on a date with no dividend or split. Threshold: relative change > 0.00001 (float noise).',
 'Ratio adjusted_close / close_price only changes on corporate action dates.',
 'An unexplained adjustment step means the adjusted series embeds an event we have no record of.'),

-- ---------------------------------------------------------------- TIMELINESS
('DQ-TIM-001', 'ingestion_delay', 'TIMELINESS', 'WARNING', 'CONFIRMED_DEFECT', 'ACCEPT_WITH_WARNING', 5,
 'audit.ingestion_logs',
 'Calendar days between the snapshot end date and the batch load exceed the threshold (5 days).',
 'load date - snapshot_end_date <= 5 days',
 'Late loads delay downstream reporting. Measured against the snapshot cutoff, never against today.'),

('DQ-TIM-002', 'latest_session_not_covered', 'TIMELINESS', 'WARNING', 'CONFIRMED_DEFECT', 'FLAG_FOR_REVIEW', NULL,
 'ref.trading_calendar vs staging.raw_stock_prices',
 'A requested ticker has no record for the last trading session on or before the snapshot cutoff.',
 'Every requested ticker covers the latest expected session.',
 'Consumers assume the dataset is current up to its stated as-of date.'),

-- ---------------------------------------------------------------- ANOMALIES (review only)
('DQ-ANO-001', 'large_daily_move', 'ANOMALY', 'WARNING', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', 10,
 'core.stock_prices',
 'Absolute one-session adjusted-close return exceeds 10%. Only evaluated when the previous record is the immediately preceding trading session (no gaps). Corporate actions on the date are cited.',
 '|adjusted return| <= 10% (otherwise review)',
 'Large moves are often genuine (earnings, news) but are also the signature of bad prints and unadjusted splits.'),

('DQ-ANO-002', 'volume_spike', 'ANOMALY', 'INFO', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', 3,
 'core.stock_prices',
 'Volume exceeds 3x the average of the previous 20 records for the security (current day excluded: no look-ahead). Requires 20 prior records.',
 'volume <= 3 x trailing 20-record average volume',
 'Volume spikes can indicate events, index rebalances or unit errors (e.g. volume in lots vs shares).'),

('DQ-ANO-003', 'abnormal_return_zscore', 'ANOMALY', 'INFO', 'REVIEWABLE_ANOMALY', 'FLAG_FOR_REVIEW', 4,
 'core.stock_prices',
 'One-session return is more than 4 standard deviations from zero, using the sample standard deviation of up to 60 previous one-session returns (min 20; current day excluded).',
 '|return| <= 4 x trailing return volatility',
 'Catches moves that are extreme for that particular stock even if below the fixed 10% threshold.')

ON CONFLICT (rule_id) DO UPDATE SET
    rule_name              = EXCLUDED.rule_name,
    rule_category          = EXCLUDED.rule_category,
    severity               = EXCLUDED.severity,
    issue_class            = EXCLUDED.issue_class,
    handling               = EXCLUDED.handling,
    threshold_value        = EXCLUDED.threshold_value,
    target_table           = EXCLUDED.target_table,
    rule_description       = EXCLUDED.rule_description,
    expected_condition     = EXCLUDED.expected_condition,
    business_justification = EXCLUDED.business_justification;
