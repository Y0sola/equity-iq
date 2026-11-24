# EquityIQ — Database Architecture

## Design goal

Model how a financial data team handles vendor data: **never lose what the source sent, never let bad data reach analysts, and always be able to explain where a number came from.**

## Data flow

```
Yahoo Finance (yfinance)  +  exchange calendar library
          │  Python: fetch, record retrieval parameters, open batch
          ▼
audit.ingestion_logs  ◄── one row per batch (counts, status, timings)
          │
          ▼
staging.raw_*            permissive, text columns, duplicates allowed
          │  SQL validation rules (Phase 3) write to audit.data_quality_issues
          ├──────────────► quarantine (critical confirmed defects — not promoted)
          ▼
core.*                   validated, typed, strictly constrained
          │
          ▼
analytics.* views        returns, volatility, quality metrics (Phases 3–4)
          │
          ▼
FastAPI (read-only role) ──► dashboard (Phases 5–6)
```

## Schemas (layers)

| Schema | Holds | Trust level | Why separate |
|---|---|---|---|
| `ref` | Security universe (20 tickers), trading calendar | Curated reference | Defines *what should exist*: which tickers are valid, which days are sessions. |
| `staging` | Raw prices, corporate actions, company metadata | Untrusted | Lets defects land so they can be measured; a strict table would reject them silently. |
| `core` | Companies, validated prices, validated corporate actions | Trusted | What analysts query. Constraints guarantee basic integrity even if validation code has a bug. |
| `audit` | Ingestion logs, rule catalogue, issues | Operational metadata | Governance: who loaded what, when, which rules ran, what failed. |
| `analytics` | Views only | Derived | Reporting logic lives in SQL views, reused by the API. |

Synthetic test fixtures are **not** stored here. `scripts/db_init.sh --test` builds an identical database `equityiq_test`, which receives synthetic defects in Phase 3. Real and synthetic data therefore cannot mix, and the same validation SQL is tested exactly as it runs in production.

## Key design decisions

| Decision | Alternative considered | Reason |
|---|---|---|
| Staging columns are `text` | Typed staging columns | A non-numeric price (`"abc"`) or impossible date (`2025-13-45`) would make a typed insert fail and the evidence would be lost. Text keeps it; SQL casts and reports it. |
| Raw payload kept as `jsonb` | Discard after parsing | Lineage: we can always show the exact provider values behind a record. |
| Surrogate keys (`company_id`, `price_id`) + unique business keys (`ticker`; `company_id + trade_date`) | Natural keys only | Ticker changes (e.g. FB → META) don't cascade through every table; uniqueness of the business key is still enforced. |
| `numeric(19,6)` for prices | `double precision` | Exact decimals; avoids float rounding in comparisons such as `close <= high`. |
| `adjusted_close` not range-checked | Check it against high/low | Dividend adjustment legitimately moves adjusted close below the reported low. |
| Ticker FK to `ref.security_universe` | Check against a hard-coded list | A data-driven whitelist is easier to extend and is itself documented data. |
| Raw → core lineage FK (`raw_record_id`, unique) | No lineage | Every validated price points to exactly one raw row; that raw row cannot be deleted while used. |
| Stable `issue_key` (unique) | New issue row per run | Re-running validation on the same snapshot updates existing issues instead of inflating counts. |
| Anomaly rules cannot be `QUARANTINE` (CHECK) | Rely on convention | Large genuine market moves must never be discarded automatically. |
| Separate test database | Test schema in the main DB | Strongest isolation; identical DDL guarantees tests reflect production behaviour. |
| `GENERATED ALWAYS AS IDENTITY` | `serial` | Modern SQL-standard identity; prevents accidental manual ids. |

## Constraint inventory (core layer)

| Table | Constraint | Enforces |
|---|---|---|
| companies | `uq_companies_ticker`, `fk_companies_universe` | One row per ticker; only tracked tickers |
| companies | `ck_companies_currency_iso` | ISO 4217-style code |
| stock_prices | `uq_stock_prices_company_date` | One price per security per session |
| stock_prices | `uq_stock_prices_raw_record` | Raw row promoted at most once |
| stock_prices | `ck_prices_positive`, `ck_volume_non_negative` | Validity |
| stock_prices | `ck_high_gte_low`, `ck_open_in_range`, `ck_close_in_range` | OHLC consistency |
| corporate_actions | `ck_action_type`, `ck_action_dividend_fields`, `ck_action_split_fields` | Type-specific value rules |
| corporate_actions | `uq_corporate_actions_company_date_type` | No duplicate events |
| data_quality_issues | `uq_dq_issues_issue_key` | Idempotent issue detection |
| data_quality_issues | `ck_dq_issue_resolution` | Closed issues have `resolved_at`; open ones do not |

## Known limitations (Phase 1)

- Trade dates in `core.stock_prices` are not foreign-keyed to `ref.trading_calendar`; non-trading-day records are caught by a validation rule instead (Phase 3), so they are reported rather than silently rejected.
- Issue status *transition order* is documented but enforced in Phase 3 workflow logic, not by constraint.
- Read-only API role `equityiq_reader` (Phase 5): SELECT-only grants (`13_security_grants.sql`), read-only sessions and 5 s statement timeout (`db_init.sh`). See [api.md](api.md).


## SQL file map (final)

| File | Contents | Applied by |
|---|---|---|
| `00_reset_schemas.sql` | drops all project schemas (destructive) | `db_init.sh --reset` only |
| `01`–`04` | schemas, tables/constraints, indexes, reference seed | `db_init.sh` |
| `05_data_quality_rules.sql` | 37-rule catalogue (upsert) | `db_init.sh` |
| `06_data_validation.sql` | safe casts, typed staging views, issue recording, status workflow trigger, validation functions, post-promotion checks | `db_init.sh` |
| `07_data_transformation.sql` | record outcomes view, promotion, batch counts, `ANALYZE`, `process_pending_batches()` | `db_init.sh` |
| `08_financial_analysis.sql` | analytics views | `db_init.sh` |
| `09_data_quality_metrics.sql` | quality metric views | `db_init.sh` |
| `10_create_views.sql` | presentation views for the API | `db_init.sh` |
| `11_quality_test_data.sql`, `12_validation_tests.sql` | synthetic fixtures and tests | `run_quality_tests.sh` (test DB only) |
| `13_security_grants.sql` | read-only role grants | `db_init.sh` (last) |

Runtime dependency note: functions in `06` read views defined in `08`. PL/pgSQL resolves names when a function runs, so file order is safe; this keeps one definition of "daily return" and "unusual volume" for both analytics and data quality checks.
