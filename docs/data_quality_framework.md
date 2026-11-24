# EquityIQ — Data Quality Framework (Phase 3)

All results below are actual outputs from `scripts/run_quality_tests.sh` (synthetic, test database) and the main database run of 2026-11-24 (real data). Synthetic and real outcomes are reported separately.

## How it works

```
staging.raw_*  ──►  validate_*_batch()   37 SQL rules, one INSERT…SELECT per rule
                        │
                        ▼
              record_violations()  ──►  audit.rule_failures        record × rule × field   (drives quarantine, pass rates)
                                   ──►  audit.data_quality_issues  one row per distinct problem (analyst workflow)
                        │
                        ▼
              audit.v_record_outcomes   QUARANTINED | REDUNDANT_DUPLICATE | HELD_FOR_REVIEW | ACCEPTED_WITH_FLAGS | (clean)
                        │
                        ▼
              promote_*_batch()   clean + accepted-with-flags  ──►  core.*   (OHLC rounded to cents, insert-only)
                        │
                        ▼
              run_post_promotion_checks()   missing sessions, timeliness, anomalies, adjustment steps (on validated data)
```

Run: `CALL audit.process_pending_batches();` (or `.venv/bin/python -m backend.ingestion.validate`).

### Why two tables (failures vs issues)
The brief requires issue counts to stay separate from record counts. Examples from the fixtures:
- One record, several rules: JPM 2026-01-12 (high below low) fails DQ-CNS-001, -002 and -003 → **1 record, 3 failures, 3 issues**.
- One issue, several records: a conflicting duplicate quarantines **both** copies under **one** issue.
- An issue with no record: a missing trading session has nothing to point to, so it exists only as an issue.

### Stable issue identity
`issue_key = rule_id | ticker | date | field` (unique). Re-running validation updates `last_detected_at` and `detection_count` on the existing row and never creates a second one. Failures are unique per `(rule, raw record, field)`.

### Record outcomes and handling

| Outcome | Trigger | Promoted? |
|---|---|---|
| QUARANTINED | Any failure whose rule handling is `QUARANTINE` | No |
| REDUNDANT_DUPLICATE | Extra copy of an *identical* record (DQ-UNI-001/003/005); the first copy (lowest raw id) is promoted | No (the business record is, via the first copy) |
| HELD_FOR_REVIEW | A later batch delivers different values for a production record (DQ-CNS-006) | No: production value kept |
| ACCEPTED_WITH_FLAGS | Only warnings or reviewable anomalies | Yes |
| clean | No failures | Yes |

**Reviewable anomalies are never quarantined.** A CHECK constraint on the rule catalogue makes `REVIEWABLE_ANOMALY` + `QUARANTINE` impossible.

### Issue workflow

```
OPEN ──► UNDER_REVIEW ──► RESOLVED | DISMISSED
  └──────────────────────► RESOLVED | DISMISSED
RESOLVED ──► OPEN   (reopened automatically if a NEW batch repeats the defect)
DISMISSED ──► OPEN  (manual only; re-validation never reopens a dismissed issue)
```
Enforced by trigger `trg_dq_issue_status_transition`; use `audit.set_issue_status(issue_id, status, notes)`. Missing-session and latest-session issues auto-resolve when the record later arrives.

## Rule catalogue

Severity: CRITICAL / WARNING / INFO. Class: Defect = confirmed defect; Anomaly = reviewable, possibly genuine. Thresholds are stored in `audit.data_quality_rules.threshold_value`. SQL implementation: `database/06_data_validation.sql` (search for the rule id).

| Rule | Name | Severity | Class | Handling | Expected condition | Business justification | Test coverage |
|---|---|---|---|---|---|---|---|
| DQ-ANO-001 | large_daily_move | WARNING | Anomaly | FLAG_FOR_REVIEW | \|adjusted return\| <= 10% (otherwise review) | Large moves are often genuine (earnings, news) but are also the signature of bad prints and unadjusted splits. | F08, N03, section 6 |
| DQ-ANO-002 | volume_spike | INFO | Anomaly | FLAG_FOR_REVIEW | volume <= 3 x trailing 20-record average volume | Volume spikes can indicate events, index rebalances or unit errors (e.g. volume in lots vs shares). | F14 |
| DQ-ANO-003 | abnormal_return_zscore | INFO | Anomaly | FLAG_FOR_REVIEW | \|return\| <= 4 x trailing return volatility | Catches moves that are extreme for that particular stock even if below the fixed 10% threshold. | F08, F15 |
| DQ-CNS-001 | high_below_low | CRITICAL | Defect | QUARANTINE | high_price >= low_price | By definition the high is the highest trade of the day; violation proves the record is wrong. | F06 |
| DQ-CNS-002 | open_outside_range | CRITICAL | Defect | QUARANTINE | low_price <= open_price <= high_price | The opening trade is one of the day's trades, so it must lie within the range. | F06, F09 |
| DQ-CNS-003 | close_outside_range | CRITICAL | Defect | QUARANTINE | low_price <= close_price <= high_price | The closing price must lie within the day's range. | F06 |
| DQ-CNS-004 | price_currency_mismatch | CRITICAL | Defect | QUARANTINE | price currency = company currency | Mixing currencies in one series produces false returns. | F13 |
| DQ-CNS-005 | provider_sector_mismatch | INFO | Anomaly | FLAG_FOR_REVIEW | mapped provider sector = assigned sector | Classification disagreements change sector aggregates; a person should confirm which is intended. | R03 |
| DQ-CNS-006 | source_value_conflict | WARNING | Anomaly | FLAG_FOR_REVIEW | Re-delivered values equal production values (after the documented rounding). | Vendor revisions must be visible and approved; silent overwrites destroy auditability. | test section 5 |
| DQ-CNS-007 | adjustment_step_without_action | WARNING | Anomaly | FLAG_FOR_REVIEW | Ratio adjusted_close / close_price only changes on corporate action dates. | An unexplained adjustment step means the adjusted series embeds an event we have no record of. | F15 |
| DQ-COM-001 | missing_required_price | CRITICAL | Defect | QUARANTINE | All five price fields are present. | A daily record without prices cannot support returns, ranges or valuation; filling it would invent data. | F03 |
| DQ-COM-002 | missing_volume | CRITICAL | Defect | QUARANTINE | Volume is present. | Volume drives liquidity analysis and volume-spike checks; zero and missing mean different things. | F09 |
| DQ-COM-003 | missing_identifier | CRITICAL | Defect | QUARANTINE | Ticker and date (where applicable) are present. | Without its business key a record cannot be attributed to a security or a session. | F24 |
| DQ-COM-004 | missing_trading_session | WARNING | Defect | FLAG_FOR_REVIEW | One raw record per requested ticker per XNYS trading session in the window. | Gaps silently turn multi-day moves into apparent one-day returns and bias averages. | F07, F23, N01, N02, section 6 |
| DQ-COM-005 | missing_required_reference_field | CRITICAL | Defect | QUARANTINE | Company name, exchange and currency are present. | The security master must identify the company, where it trades and the price currency. | R06 |
| DQ-COM-006 | missing_optional_reference_field | WARNING | Defect | ACCEPT_WITH_WARNING | Provider sector and industry are present. | Useful for classification checks but not required: analysis uses the project-assigned sector. | R06 |
| DQ-COM-007 | missing_company_reference | CRITICAL | Defect | QUARANTINE | A validated core.companies row exists for the ticker. | Market data cannot be attributed to a company whose own reference data failed validation. | A38, F16 |
| DQ-TIM-001 | ingestion_delay | WARNING | Defect | ACCEPT_WITH_WARNING | load date - snapshot_end_date <= 5 days | Late loads delay downstream reporting. Measured against the snapshot cutoff, never against today. | N04 |
| DQ-TIM-002 | latest_session_not_covered | WARNING | Defect | FLAG_FOR_REVIEW | Every requested ticker covers the latest expected session. | Consumers assume the dataset is current up to its stated as-of date. | F23 |
| DQ-UNI-001 | exact_duplicate_price | WARNING | Defect | ACCEPT_WITH_WARNING | One raw record per ticker and date per batch. | Identical duplicates are harmless once removed, but double-count volume and observations if not. | F01 |
| DQ-UNI-002 | conflicting_duplicate_price | CRITICAL | Defect | QUARANTINE | One raw record per ticker and date per batch. | When the source contradicts itself we cannot know which value is right, so neither is published. | F02 |
| DQ-UNI-003 | exact_duplicate_corporate_action | WARNING | Defect | ACCEPT_WITH_WARNING | One record per ticker, date and action type per batch. | A doubled dividend would double the income attributed to shareholders. | A34 |
| DQ-UNI-004 | conflicting_duplicate_corporate_action | CRITICAL | Defect | QUARANTINE | One record per ticker, date and action type per batch. | Conflicting dividend amounts or split ratios cannot be resolved without a second source. | A35 |
| DQ-UNI-005 | exact_duplicate_reference | WARNING | Defect | ACCEPT_WITH_WARNING | One reference record per ticker per batch. | A security master must have exactly one row per security. | R02 |
| DQ-UNI-006 | conflicting_duplicate_reference | CRITICAL | Defect | QUARANTINE | One reference record per ticker per batch. | Two different names or currencies for one ticker is an identity conflict. | R07 |
| DQ-VAL-001 | unparseable_numeric | CRITICAL | Defect | QUARANTINE | Numeric fields parse as finite numbers. | Unparseable values would either crash calculations or be silently converted to something else. | F11, F25 |
| DQ-VAL-002 | non_positive_price | CRITICAL | Defect | QUARANTINE | All prices > 0. | Listed equities cannot trade at or below zero; such a value is a data error. | F09 |
| DQ-VAL-003 | negative_volume | CRITICAL | Defect | QUARANTINE | Volume >= 0. | Shares traded cannot be negative. | F04 |
| DQ-VAL-004 | invalid_ticker | CRITICAL | Defect | QUARANTINE | Ticker exists in the tracked security universe. | Unknown identifiers cannot be mapped to a security; mis-mapping would corrupt another security. | F05, R05 |
| DQ-VAL-005 | invalid_date | CRITICAL | Defect | QUARANTINE | Date parses as an ISO calendar date. | Ambiguous or impossible dates (2026-13-45, 03/04/2026) cannot be placed on the timeline reliably. | F17 |
| DQ-VAL-006 | date_outside_snapshot_window | CRITICAL | Defect | QUARANTINE | snapshot_start_date <= date <= snapshot_end_date of the batch. | Records outside the requested period indicate a request or provider error and break period metrics. | F12 |
| DQ-VAL-007 | non_trading_date | CRITICAL | Defect | QUARANTINE | Date is an XNYS trading session. | No regular-session trading occurs on closed days, so a record dated then is mis-dated. | A36, F10 |
| DQ-VAL-008 | non_integer_volume | CRITICAL | Defect | QUARANTINE | Volume is a whole number of shares. | Fractional share volume indicates a unit or parsing error. | F19 |
| DQ-VAL-009 | invalid_action_type | CRITICAL | Defect | QUARANTINE | action_type IN (DIVIDEND, STOCK_SPLIT). | Unsupported event types cannot be interpreted or applied consistently. | A37 |
| DQ-VAL-010 | invalid_dividend_amount | CRITICAL | Defect | QUARANTINE | dividend_amount > 0 and split_ratio is empty. | An invalid dividend misstates shareholder income and the adjusted price series. | A32 |
| DQ-VAL-011 | invalid_split_ratio | CRITICAL | Defect | QUARANTINE | split_ratio > 0, split_ratio <> 1, dividend_amount is empty. | A wrong split ratio distorts every pre-split price by that factor. | A33 |
| DQ-VAL-012 | invalid_currency_code | CRITICAL | Defect | QUARANTINE | currency ~ ^[A-Z]{3}$ | Prices are meaningless without a reliable currency. | R04 |

### Design notes
- **Missing sessions** are expected sessions (requested tickers × XNYS trading days in the window) with no raw record in *any* price batch. Weekends and holidays are never expected (fixtures F10b, F18, N01).
- **Timeliness** is measured against the snapshot cutoff (`snapshot_end_date`), never against today, so a deliberately fixed historical snapshot is not "stale".
- **Large moves** use the adjusted close and are evaluated only when the previous validated record is the *immediately preceding trading session*. A return across a gap is not called a one-day return (F21); when a late record closes the gap, the neighbour is re-evaluated (test section 6).
- **No look-ahead:** volume and volatility baselines use only prior records (`ROWS BETWEEN n PRECEDING AND 1 PRECEDING`).
- **Corporate actions are cited, not used as excuses:** a large move on an action date is still flagged, with the action named in the observed value.
- **Rounding:** reported OHLC → 2 dp (proven lossless for Yahoo float32 values, see data_acquisition.md); adjusted close → 6 dp. One function each (`core.to_reported_price`, `core.to_adjusted_price`) shared by promotion and the revision check.

## Metrics (views in `analytics`)

| View | What it reports | Definition |
|---|---|---|
| `v_dq_dimension_scores` | Score per dimension for the latest price batch | numerator / denominator shown; NULL if denominator is 0 |
| `v_dq_batch_metrics` | Per-batch outcomes and **record pass rate** | records with no confirmed defect / records evaluated (anomalies excluded) |
| `v_dq_field_completeness` | Per field: present, parseable, % | present and parseable / evaluated |
| `v_dq_rule_results` | Per rule: failing records vs issues vs unresolved issues | records and issues counted separately |
| `v_dq_issue_summary` | Issues by class × severity × status | issue counts, not record counts |
| `v_dq_issues` | Filterable issue list with rule explanation | for the dashboard |
| `v_quarantined_records` | Quarantined raw records with failed rules and raw values | |
| `v_dq_snapshot_summary` | Production state: validated vs expected records, open defects vs open anomalies | expected = active universe × XNYS sessions |

**Batch vs snapshot:** batch metrics describe what one load contained; snapshot metrics describe what analysts can query now (core), which may combine several batches.

Dimension definitions (latest price batch):
- **Completeness (records):** records without a confirmed completeness defect / records received.
- **Completeness (expected sessions):** expected (ticker, session) pairs with ≥1 raw record / expected pairs. Reported separately because absent records cannot be counted as raw rows.
- **Uniqueness / Validity / Consistency:** records without a confirmed defect in that dimension / records received. Reviewable conflicts (DQ-CNS-005/006/007) are excluded.
- **Timeliness:** requested tickers covering the last expected session / requested tickers.
- **Overall (record pass rate):** records without any confirmed defect / records received. The dimensions are **not averaged**: they have different scopes.

## Results — synthetic fixtures (test database only)

`scripts/run_quality_tests.sh`: **77 tests run, 77 passed, 0 failed** (≈4 s). (76/76 at the end of Phase 3; fixture F25 was added in Phase 5 for the stricter numeric parser.)

| Section | Tests | Passed |
|---|---|---|
| 1 Fixture expectations (exact rule set + outcome per fixture, incl. 5 controls and negative tests) | 49 | 49 |
| 2 Batch count reconciliation, pass-rate hand check, metric sanity | 10 | 10 |
| 3 Idempotency (re-validate same batches) | 2 | 2 |
| 4 Duplicate re-ingestion (identical new batch) | 5 | 5 |
| 5 Provider revision held, production not overwritten | 3 | 3 |
| 6 Late-arriving missing session | 4 | 4 |
| 7 Issue workflow | 4 | 4 |

Synthetic batch outcomes (defects were seeded on purpose, so low pass rates are expected):

| Batch | Received | Clean | Accepted with flags | Quarantined | Redundant | Held | Record pass rate |
|---|---|---|---|---|---|---|---|
| R1 reference | 11 | 4 | 1 | 5 | 1 | 0 | 45.45 % |
| P1 prices | 395 | 308 | 7 | 79 | 1 | 0 | 79.75 % |
| A1 corporate actions | 11 | 3 | 0 | 7 | 1 | 0 | 27.27 % |
| P2 re-ingestion (AAPL copy) | 67 | 63 | 0 | 3 | 1 | 0 | 94.03 % |
| P3 revision | 1 | 0 | 0 | 0 | 0 | 1 | 100.00 % (held for review is a reviewable conflict, not a confirmed defect) |
| P4 late session | 1 | 1 | 0 | 0 | 0 | 0 | 100.00 % |
| P5 repeated defect | 1 | 0 | 0 | 1 | 0 | 0 | 0.00 % |

P1's 79 quarantined records include all 65 MCD prices (company reference quarantined → DQ-COM-007), which shows how one reference-data defect cascades to market data.

How the 76/76 was reached, honestly: the first runs failed on bugs in the *test setup* (a float/numeric type error; a helper called once per row). After fixing those, the framework met every written expectation on the first evaluation. Writing the fixtures also exposed one framework gap (anomaly checks did not re-evaluate a neighbour after a late record closed a gap), which was fixed and is now covered by test section 6.

## Results — real data (main database)

Snapshot `yahoo_20251124_20261123_retrieved_20261124T132237Z`:

| Measure | Result |
|---|---|
| Records evaluated | 20 reference, 5,020 prices, 72 corporate actions |
| Confirmed defects | **0** (no rule with class Defect fired) |
| Quarantined / redundant / held | 0 / 0 / 0 |
| Promoted to core | 20 companies, 5,020 prices, 72 dividends |
| Record pass rate | 100.00 % (5,020 / 5,020 prices) |
| Expected-session coverage | 100.00 % (5,020 / 5,020) |
| Reviewable anomalies | **79 issues on 58 records**: 16 large daily moves (>10 %), 33 volume spikes (>3× trailing 20), 30 extreme returns (>4 sd) |
| Sector consistency (DQ-CNS-005) | 0 mismatches after mapping Yahoo labels |
| Adjustment steps without action (DQ-CNS-007) | 0 |
| Validation runtime | ≈4 s for all batches |
| Re-validation | issues 79 → 79, failures 79 → 79, prices 5,020 → 5,020 |

Largest flagged move: NVDA 2026-11-23, +31.48 % (adjusted close 125.53 → 165.05; checked by hand), immediately after −14.01 % on 2026-11-20. OHLC is internally consistent and volume roughly doubled on both days. The cause cannot be established from a single provider, so it remains a **reviewable anomaly** for an analyst, not a confirmed error.

A clean first snapshot means the provider data passed every confirmed-defect rule. It does not prove the rules are effective; the synthetic fixtures do that.

## Limitations
- Single provider: no cross-source price verification; anomaly review needs an external source.
- Re-delivered adjusted closes will legitimately differ after any later dividend (the whole adjusted history is restated). DQ-CNS-006 would hold those for review; a production design would version adjusted series per snapshot.
- Reference data promotion is type-1 (current state overwrites); previous versions remain in staging.
- Corporate actions extracted from the price history only cover the window; there were no splits in the real data, so split handling is tested only with synthetic fixtures.
