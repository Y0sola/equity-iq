# EquityIQ — Data Dictionary

Status: **updated Phase 3**. Provider behaviour (adjustment conventions, precision) is verified in [data_acquisition.md](data_acquisition.md).

Legend: **PK** primary key · **FK** foreign key · **UK** unique · **NN** not null · **CK** check constraint.

---

## ref.security_universe — tracked securities (project scope)

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| ticker | varchar(10) | Exchange ticker symbol | PK; CK `^[A-Z][A-Z.\-]{0,9}$` | Project brief §3 | `AAPL` |
| assigned_sector | varchar(60) | Sector assigned by project scope (GICS-style name) | NN | Project brief §3 | `Information Technology` |
| is_active | boolean | Whether the ticker is currently tracked | NN, default true | Project | `true` |
| added_at | timestamptz | When the row was seeded | NN, default now() | System | `2026-11-24 12:00:00+00` |
| notes | text | Free-text provenance | — | Project | `Project scope (brief section 3)` |

## ref.trading_calendar — exchange sessions

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| exchange | varchar(10) | Calendar code | PK (with calendar_date) | Calendar library | `XNYS` |
| calendar_date | date | Calendar day | PK (with exchange) | Calendar library | `2025-12-25` |
| is_trading_day | boolean | Market open for a regular or shortened session | NN | Calendar library | `false` |
| is_early_close | boolean | Shortened session | NN; CK only on trading days | Calendar library | `true` (day after Thanksgiving) |
| holiday_name | varchar(100) | Name of the closure | CK null on trading days | Calendar library | `Christmas` |
| source | varchar(100) | Library and version used | NN | System | `exchange_calendars 4.x` |
| loaded_at | timestamptz | Load time | NN | System | — |

## audit.ingestion_logs — one row per load batch

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| ingestion_batch_id | bigint | Batch identifier | PK, identity | System | `1` |
| batch_type | varchar(30) | What was loaded | CK in PRICES, COMPANY_REFERENCE, CORPORATE_ACTIONS, TRADING_CALENDAR, FULL_SNAPSHOT | System | `FULL_SNAPSHOT` |
| source | varchar(100) | Data provider | NN | System | `yfinance` |
| retrieval_parameters | jsonb | Exact request used (tickers, dates, adjustment flags) | — | System | `{"auto_adjust": false}` |
| snapshot_start_date / snapshot_end_date | date | Fixed historical window requested | CK end ≥ start | System | `2025-11-24` / `2026-11-23` |
| snapshot_label | varchar(100) | Local snapshot folder name | — | System | `yahoo_20251124_20261123_retrieved_20261124T132237Z` |
| source_checksum | varchar(64) | SHA-256 of the dataset's source files | CK 64 hex chars; unique per batch_type among RUNNING/SUCCEEDED/PARTIAL batches | System | `297278253ad8…` |
| start_timestamp / end_timestamp | timestamptz | Batch run time | CK end ≥ start; end required once finished | System | — |
| records_received | integer | Rows landed in staging | NN, ≥ 0 | System | — |
| records_accepted | integer | Rows promoted to core | NN, ≥ 0 | System | — |
| records_rejected | integer | Rows quarantined (critical failure) | NN, ≥ 0; accepted + rejected ≤ received | System | — |
| records_flagged | integer | Accepted rows carrying warnings/review flags | NN, ≥ 0 | System | — |
| status | varchar(20) | Batch outcome | CK in RUNNING, SUCCEEDED, PARTIAL, FAILED, SKIPPED (rerun of an already-loaded snapshot) | System | `SUCCEEDED` |
| error_message | text | Failure detail | — | System | — |

## staging.raw_stock_prices — raw daily prices (permissive)

All value columns are **text** so malformed input is preserved for diagnosis. No uniqueness or range checks.

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| raw_record_id | bigint | Raw row identifier | PK, identity | System | `1042` |
| ingestion_batch_id | bigint | Batch that loaded the row | NN, FK → ingestion_logs | System | `1` |
| source_row_number | integer | Position in the source payload | — | System | `17` |
| ticker | text | Ticker as received | — | yfinance request | `AAPL` |
| trade_date | text | Session date as received | — | yfinance index | `2025-03-14` |
| open_price, high_price, low_price, close_price | text | Reported OHLC prices (not dividend-adjusted; float32 precision, e.g. `1025.56005859375` = $1,025.56) | — | yfinance `Open/High/Low/Close` | `275.9200134277344` |
| adjusted_close | text | Dividend-adjusted close (multiplicative factor; verified) | — | yfinance `Adj Close` | `274.9620666503906` |
| volume | text | Shares traded (integer) | — | yfinance `Volume` | `65585800` |
| currency | text | Price currency if supplied | — | yfinance metadata | `USD` |
| source | text | Provider name | NN | System | `yfinance` |
| ingestion_timestamp | timestamptz | Load time | NN | System | — |
| raw_payload | jsonb | Original provider row | — | yfinance | `{"Close": 213.49, ...}` |

## staging.raw_corporate_actions / staging.raw_company_reference

Same pattern: identity PK, `ingestion_batch_id` FK, text columns mirroring the core table, `source`, `ingestion_timestamp`, `raw_payload`.

---

## core.companies — validated security master

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| company_id | integer | Surrogate key | PK, identity | System | `1` |
| ticker | varchar(10) | Ticker | NN, UK, FK → ref.security_universe | Universe | `AAPL` |
| company_name | varchar(200) | Registered/display name | NN, CK not blank | yfinance `longName` | `Apple Inc.` |
| sector | varchar(60) | Project-assigned sector used in analysis | NN | ref.security_universe | `Information Technology` |
| provider_sector | varchar(100) | Sector label from the provider | — | yfinance `sector` | `Technology` |
| industry | varchar(150) | Industry | — | yfinance `industry` | `Consumer Electronics` |
| exchange | varchar(20) | Listing exchange | NN | yfinance `exchange` | `NMS` |
| currency | char(3) | ISO 4217 currency | NN, CK `^[A-Z]{3}$` | yfinance `currency` | `USD` |
| source | varchar(100) | Provider | NN | System | `yfinance` |
| raw_reference_id | bigint | Lineage to raw row | FK → raw_company_reference | System | — |
| created_at / updated_at | timestamptz | Audit timestamps (updated by trigger) | NN | System | — |

## core.stock_prices — validated daily prices

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| price_id | bigint | Surrogate key | PK, identity | System | — |
| company_id | integer | Company | NN, FK → companies; UK with trade_date | System | `1` |
| trade_date | date | Trading session | NN | Staging | `2025-03-14` |
| open_price, high_price, low_price, close_price | numeric(19,6) | Reported prices | NN; CK > 0; high ≥ low; open and close within [low, high] | Staging | `213.490000` |
| adjusted_close | numeric(19,6) | Adjusted close (basis for returns) | NN; CK > 0; **not** range-checked | Staging | `212.710000` |
| volume | bigint | Shares traded | NN; CK ≥ 0 | Staging | `60107600` |
| source | varchar(100) | Provider | NN | Staging | `yfinance` |
| ingestion_timestamp | timestamptz | When the raw row was loaded | NN | Staging | — |
| updated_at | timestamptz | Last change (trigger) | NN | System | — |
| raw_record_id | bigint | Lineage to the staging row | NN, FK → raw_stock_prices | System | `1042` |

## core.corporate_actions — validated dividends and splits

| Field | Type | Definition | Constraints | Source | Example |
|---|---|---|---|---|---|
| action_id | bigint | Surrogate key | PK, identity | System | — |
| company_id | integer | Company | NN, FK → companies | System | — |
| action_date | date | Ex-date (as reported by provider) | NN | yfinance index | `2025-02-10` |
| action_type | varchar(20) | Event type | CK in DIVIDEND, STOCK_SPLIT; UK with company_id + action_date | Derived | `DIVIDEND` |
| dividend_amount | numeric(19,6) | Cash per share | Required and > 0 for DIVIDEND; null for splits | yfinance `Dividends` | `0.250000` |
| split_ratio | numeric(12,6) | New shares per old share | Required, > 0 and ≠ 1 for STOCK_SPLIT; null for dividends | yfinance `Stock Splits` | `4.000000` (4-for-1), `0.100000` (1-for-10) |
| source, ingestion_timestamp | — | Provenance | NN | System | — |
| raw_action_id | bigint | Lineage | FK → raw_corporate_actions | System | — |

---

## audit.data_quality_rules — rule catalogue

| Field | Type | Definition | Constraints | Example |
|---|---|---|---|---|
| rule_id | varchar(20) | Rule identifier | PK | `DQ-CON-001` |
| rule_name | varchar(100) | Short name | NN, UK | `high_below_low` |
| rule_category | varchar(20) | Quality dimension | CK in COMPLETENESS, UNIQUENESS, VALIDITY, CONSISTENCY, TIMELINESS, ANOMALY | `CONSISTENCY` |
| rule_description | text | What the rule checks and why | NN | — |
| expected_condition | text | Condition a valid record satisfies | NN | `high_price >= low_price` |
| target_table | varchar(60) | Table evaluated | NN | `staging.raw_stock_prices` |
| severity | varchar(10) | Impact | CK in CRITICAL, WARNING, INFO | `CRITICAL` |
| issue_class | varchar(20) | Confirmed defect vs anomaly needing review | CK in CONFIRMED_DEFECT, REVIEWABLE_ANOMALY | `CONFIRMED_DEFECT` |
| handling | varchar(20) | What the pipeline does | CK in QUARANTINE, ACCEPT_WITH_WARNING, FLAG_FOR_REVIEW; anomalies must be FLAG_FOR_REVIEW | `QUARANTINE` |
| threshold_value | numeric | Numeric threshold, where relevant | — | `10` |
| is_active | boolean | Rule enabled | NN | `true` |
| created_at | timestamptz | — | NN | — |

## audit.data_quality_issues — detected issues

| Field | Type | Definition | Constraints | Example |
|---|---|---|---|---|
| issue_id | bigint | Surrogate key | PK | — |
| issue_key | text | Stable identity: `rule_id\|ticker\|date\|field` | NN, UK | `DQ-CON-001\|AAPL\|2025-03-14\|high_price` |
| rule_id | varchar(20) | Rule raised | NN, FK → rules | `DQ-CON-001` |
| raw_record_id / raw_action_id / raw_reference_id | bigint | Lineage to the failing raw row | FKs; at most one set; all null for missing records | `1042` |
| company_id | integer | Company if resolvable | FK → companies | — |
| ticker, trade_date | text, date | Business key (kept even if ticker is invalid) | — | `AAPL`, `2025-03-14` |
| affected_field | varchar(60) | Column at fault (`record` for whole-row issues) | — | `high_price` |
| observed_value | text | What was found | — | `98.5` |
| expected_condition | text | What should be true | — | `high_price >= low_price (99.1)` |
| severity | varchar(10) | Copied from the rule at detection | CK | `CRITICAL` |
| status | varchar(20) | Workflow state | CK in OPEN, UNDER_REVIEW, RESOLVED, DISMISSED | `OPEN` |
| detected_at / last_detected_at | timestamptz | First and most recent detection | last ≥ first | — |
| detection_count | integer | Number of validation runs that saw it | ≥ 1 | `2` |
| resolved_at | timestamptz | Close time | Required iff RESOLVED/DISMISSED | — |
| resolution_notes | text | Analyst explanation | — | — |
| ingestion_batch_id | bigint | Batch that first raised it | FK → ingestion_logs | `1` |

### Issue status transitions

```
OPEN ──► UNDER_REVIEW ──► RESOLVED   (defect corrected or explained)
  │            │
  │            └────────► DISMISSED  (not a defect, e.g. genuine market move)
  └──────────────────────► RESOLVED / DISMISSED
RESOLVED / DISMISSED ──► OPEN        (only if a later validation run detects it again)
```
Enforced in Phase 1 by CHECK constraints (valid statuses; `resolved_at` present exactly when closed). Transition order will be enforced by the Phase 3 workflow logic.


---

## Phase 3 additions

### ref.sector_mapping
| Field | Type | Definition | Constraints | Example |
|---|---|---|---|---|
| source | varchar(50) | Provider whose labels are mapped | PK (with provider_sector) | `yahoo_finance` |
| provider_sector | varchar(100) | Provider's sector label | PK | `Consumer Cyclical` |
| mapped_sector | varchar(60) | Project sector name | NN | `Consumer Discretionary` |

### audit.rule_failures — record-level failures
| Field | Type | Definition | Constraints | Example |
|---|---|---|---|---|
| failure_id | bigint | Surrogate key | PK, identity | — |
| rule_id | varchar(20) | Rule that failed | NN, FK → data_quality_rules | `DQ-CNS-001` |
| issue_id | bigint | Issue this failure belongs to | NN, FK → data_quality_issues | — |
| ingestion_batch_id | bigint | Batch of the failing raw record | NN, FK → ingestion_logs | `3` |
| raw_record_id / raw_action_id / raw_reference_id | bigint | The failing raw record | FKs; exactly one set | `1042` |
| affected_field | varchar(60) | Column at fault, or `record` | NN | `high_price` |
| observed_value | text | Value seen | — | `high 98 < low 99` |
| detected_at | timestamptz | First detection | NN | — |
Unique `(rule_id, raw_record_id, raw_action_id, raw_reference_id, affected_field)` with NULLS NOT DISTINCT.

### Added columns
| Table | Field | Type | Definition |
|---|---|---|---|
| audit.ingestion_logs | validated_at | timestamptz | When SQL validation/promotion last processed the batch (NULL = pending) |
| audit.data_quality_rules | business_justification | text | Why the rule matters to data consumers |
| audit.data_quality_issues | last_detected_batch_id | bigint FK | Most recent batch that raised the issue (drives reopen logic) |

### Views
`staging.v_raw_stock_prices_typed`, `staging.v_raw_price_fields`, `staging.v_raw_corporate_actions_typed` (parsed staging); `audit.v_record_outcomes` (outcome per raw record); quality metric views in `analytics` described in [data_quality_framework.md](data_quality_framework.md).
