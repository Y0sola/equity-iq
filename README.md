# EquityIQ — Equity Market Data Management & Quality Analysis

![Status](https://img.shields.io/badge/status-active%20development-blue)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-336791)
![SQL](https://img.shields.io/badge/core-SQL-0f1e36)
![Python](https://img.shields.io/badge/Python-3.12-3776AB)
![FastAPI](https://img.shields.io/badge/API-FastAPI%20(read--only)-009688)
![React](https://img.shields.io/badge/UI-React%20%2B%20TypeScript-61DAFB)

An independent financial data management project that acquires real historical equity market data, preserves the raw source records, validates them with a SQL data quality framework, quarantines confirmed defects, flags genuine anomalies for review, and delivers validated data and SQL analytics through a read-only API and dashboard.

**SQL is the core of the project**: validation rules, promotion to production tables, quality metrics and every financial calculation are implemented in PostgreSQL. Python is used only for data acquisition, orchestration and the API layer.

> **Status: active development.** The data pipeline, quality framework, analytics, API and dashboard are implemented and tested (see [Project status](#project-status)). Final documentation, screenshots and a clean-environment reproduction are in progress.
> Historical snapshot only — not live data, not investment advice. Independent portfolio project, not affiliated with any data vendor or financial institution.

---

## Contents
[Business problem](#business-problem) · [Objectives](#objectives) · [Project status](#project-status) · [Verified results](#verified-results) · [Technology](#technology-stack) · [Data](#data-sources-and-scope) · [Architecture](#database-architecture) · [Data quality](#data-quality-methodology) · [Financial analysis](#financial-analysis) · [SQL competencies](#sql-competencies-demonstrated) · [API & security](#read-only-api-and-security) · [Dashboard](#dashboard) · [Testing](#testing-and-verification) · [Structure](#project-structure) · [Getting started](#getting-started) · [Roadmap](#roadmap) · [Limitations](#limitations)

---

## Business problem

Market data is only useful if the people consuming it can trust it. Vendor feeds arrive with duplicates, gaps, malformed values, impossible prices, revisions and genuine-but-extreme market moves that look like errors. A data management team must be able to answer, for any published number:

- **Is it complete?** Was every expected trading session received, without counting weekends and holidays as missing?
- **Is it valid and consistent?** Are prices positive, is the high above the low, is the currency right?
- **Is it unique?** Were duplicates or conflicting re-deliveries detected rather than silently overwritten?
- **Is it explained?** Which rule flagged it, why it matters, and what happened to the record?
- **Where did it come from?** Which raw record, which ingestion batch, which source request?

EquityIQ implements that workflow end to end for a defined universe of US equities.

## Objectives

1. Model a layered relational database that separates raw, validated, audit and analytical data.
2. Ingest a fixed, reproducible 12-month historical snapshot from a real source, with batch metadata and rerun protection.
3. Validate every record with a central, documented SQL rule catalogue; quarantine confirmed defects; flag anomalies for review.
4. Report data quality with explicit, auditable metrics (numerator, denominator, scope).
5. Compute financial analytics in SQL with correct handling of gaps, adjustments and minimum samples.
6. Expose results safely through a read-only API and a dashboard, with full data lineage.
7. Prove behaviour with tests, including deliberately seeded synthetic defects, and report actual results.

---

## Project status

| Area | Status | Notes |
|---|---|---|
| Database architecture (schemas, keys, constraints, indexes, ER diagram, data dictionary) | ✅ Complete | 5 schemas, 13 tables, schema tests |
| Data acquisition (real historical snapshot, batch metadata, checksums, rerun protection) | ✅ Complete | Yahoo Finance via `yfinance`, fixed window |
| SQL data quality framework (37 rules, quarantine, issue workflow, metrics) | ✅ Complete | Synthetic fixture tests |
| SQL financial analytics (returns, moving averages, volatility, sectors, corporate actions) | ✅ Complete | Edge-case tests + independent cross-check |
| Read-only API (FastAPI, 25 GET endpoints, allowlisted SQL library) | ✅ Complete | API tests including security cases |
| Dashboard (Overview, Data Quality, SQL Library, Securities, Corporate Actions, Ingestion & Lineage) | ✅ Complete | Verified manually in the browser |
| Final documentation, screenshots, case study, clean-environment reproduction | 🔄 In progress | |
| Automated frontend tests, continuous integration, hosted demo | 📋 Planned | See [Roadmap](#roadmap) |

## Verified results

All figures below were produced by the project's own scripts on **2026-11-24** against snapshot `yahoo_20251124_20261123_retrieved_20261124T132237Z`. Real-data and synthetic-data results are reported separately.

**Real data (main database)**

| Measure | Result |
|---|---|
| Securities / sectors | 20 / 5 (4 per sector) |
| Snapshot window | 2025-11-24 → 2026-11-23 (251 NYSE trading sessions) |
| Daily price records received / expected | 5,020 / 5,020 (100.00 % session coverage) |
| Corporate actions | 72 dividends; 0 stock splits in the window |
| Confirmed defects found | 0 (record pass rate 100.00 %) |
| Records quarantined | 0 |
| Reviewable anomalies flagged | 79 issues on 58 records (16 daily moves > 10 %, 33 volume spikes > 3× trailing average, 30 returns > 4 standard deviations) |
| Rerun of the same snapshot | logged as `SKIPPED`, 0 rows added |

A clean first snapshot means the provider data passed every confirmed-defect rule; it does **not** by itself prove the rules work. The synthetic fixtures below do that.

**Synthetic data (isolated test database only)**

| Measure | Result |
|---|---|
| Seeded fixtures, expected outcomes written before running | 45 (25 price, 9 corporate action, 7 reference, 4 missing-record cases) |
| Data quality tests (fixtures, negative tests, idempotency, re-ingestion, revision, late arrival, workflow) | 77 / 77 passed |
| Rules exercised by tests | 37 / 37 (35 through fixtures, 2 through scenario tests) |

## Technology stack

| Layer | Technology |
|---|---|
| Database & core logic | **PostgreSQL 17**, SQL (DDL, constraints, views, functions, procedures, triggers, window functions) |
| Ingestion & orchestration | Python 3.12, `yfinance`, `exchange_calendars` (NYSE calendar), `pandas` (reading provider data only), `psycopg` 3 |
| API | FastAPI, `psycopg-pool`, read-only database role |
| Dashboard | React 19, TypeScript 5.9, Tailwind CSS 4, Recharts 3, Vite 7 |
| Testing | SQL test suites (transactions, savepoints), `pytest`, FastAPI `TestClient`, pandas cross-check |
| Environment | Homebrew PostgreSQL or Docker Compose; credentials via `.env` (template: `.env.example`) |

---

## Data sources and scope

| Item | Value |
|---|---|
| Source | Yahoo Finance via `yfinance` (subject to Yahoo's terms of use) |
| Universe | 20 US-listed companies, 5 sectors |
| Window | Fixed 12-month historical snapshot, 2025-11-24 → 2026-11-23, ending on a completed session |
| Calendar | `exchange_calendars` XNYS (holidays, early closes) |
| Price settings | `auto_adjust=False`, `back_adjust=False`, `repair=False`, `actions=True`, set explicitly so reported and adjusted prices stay separate and no provider "repair" hides defects |

| Sector | Securities |
|---|---|
| Information Technology | AAPL, MSFT, NVDA, AVGO |
| Financials | JPM, BAC, GS, MS |
| Healthcare | JNJ, PFE, UNH, MRK |
| Energy | XOM, CVX, COP, EOG |
| Consumer Discretionary | AMZN, TSLA, NKE, MCD |

**Verified provider behaviour** (tested in SQL, not assumed; details in [docs/data_acquisition.md](docs/data_acquisition.md)):
- `Close` is the reported close; `Adj Close` applies a multiplicative dividend adjustment. The ratio `adjusted / close` changed on exactly the 72 ex-dividend dates and nowhere else, by the expected factor to 6 decimal places.
- Prices arrive as 32-bit floats (e.g. `1025.56005859375`). All 20,080 open/high/low/close values are exactly the float representation of a whole-cent price, so reported prices are rounded to cents on promotion without information loss; the raw text is preserved in staging.

**Redistribution:** raw provider downloads are **not** committed. The repository contains reproducible download and load scripts instead.

---

## Database architecture

```
Yahoo Finance + NYSE calendar
        │  fetch_snapshot.py — saves untouched provider data + manifest (SHA-256 checksums)
        ▼
audit.ingestion_logs ── one batch per dataset; checksum-based rerun protection
        ▼
staging.raw_*        ── permissive: values stored as TEXT + original JSON payload
        │  SQL validation (37 rules) → audit.rule_failures (record level) + audit.data_quality_issues (workflow)
        ├──────────────► quarantine (critical confirmed defects are never promoted)
        ▼
core.*               ── validated, strictly typed and constrained; lineage to the raw record
        ▼
analytics.* views    ── quality metrics and financial analytics (one SQL definition each)
        ▼
read-only API  ──►  dashboard
```

| Schema | Purpose |
|---|---|
| `ref` | Tracked security universe, NYSE trading calendar, provider sector mapping |
| `staging` | Raw landing tables; text columns so malformed values are kept and reported rather than rejected at insert |
| `core` | Validated companies, daily prices and corporate actions with strict keys and CHECK constraints |
| `audit` | Ingestion batches, rule catalogue, record-level failures and the issue register |
| `analytics` | Read-only views for quality metrics, financial analytics and the dashboard |

**Design highlights**
- **Types for finance:** `numeric(19,6)` prices (exact decimals), `bigint` volume, `date` sessions, `timestamptz` load times.
- **Integrity in the database, not only in code:** unique business keys (one price per security per session), CHECK constraints (positive prices, `high ≥ low`, open/close within range, type-specific corporate-action rules), and foreign keys including a ticker whitelist.
- **Lineage:** every validated price references exactly one raw record (`NOT NULL` + `UNIQUE` foreign key); a raw record used in production cannot be deleted.
- **Idempotency:** a partial unique index makes a second successful load of the same snapshot impossible; stable issue keys make re-validation update issues rather than duplicate them.
- **No silent overwrites:** a later batch with different values for an existing production record is held for review, and the production value is kept.

Diagrams and definitions: [ER diagram](docs/er_diagram.md) · [Data dictionary](docs/data_dictionary.md) · [Architecture & design decisions](docs/database_architecture.md)

---

## Data quality methodology

**37 SQL rules** in a central catalogue (`audit.data_quality_rules`), each with severity, issue class, handling, expected condition, threshold and business justification:

| Dimension | Rules | Examples |
|---|---|---|
| Completeness | 7 | Missing prices, volume, identifiers or reference fields; missing trading sessions (calendar-aware) |
| Uniqueness | 6 | Identical vs conflicting duplicate prices, corporate actions and reference records |
| Validity | 12 | Unparseable numbers, non-positive prices, negative or fractional volume, unknown tickers, invalid/future/non-trading dates, invalid dividends and split ratios, invalid currency codes |
| Consistency | 7 | High below low, open/close outside range, currency mismatch, sector classification mismatch, conflicting re-deliveries, unexplained adjustment steps |
| Timeliness | 2 | Load delay vs snapshot cutoff (never vs today's date), latest-session coverage |
| Anomaly (review only) | 3 | Daily move > 10 %, volume > 3× trailing 20-session average, return > 4 standard deviations (no look-ahead) |

**Confirmed defects vs reviewable anomalies.** Provably wrong records (e.g. high below low) are **quarantined**: kept in staging, never published. Unusual but possibly genuine records (e.g. a 31 % daily move) are **published and flagged** for an analyst. A database constraint makes it impossible to configure an anomaly rule to quarantine data.

**Records vs issues.** `audit.rule_failures` stores one row per record × rule × field (drives quarantine and pass rates); `audit.data_quality_issues` stores one row per distinct problem (the analyst workflow OPEN → UNDER_REVIEW → RESOLVED / DISMISSED, enforced by a trigger). One record can fail several rules; one issue can cover several records.

**Metrics** are SQL views with an explicit numerator, denominator and scope; zero denominators return N/A; dimensions with different scopes are not averaged into a single score.

Full rule catalogue with test coverage: [docs/data_quality_framework.md](docs/data_quality_framework.md)

---

## Financial analysis

All implemented as SQL views over validated data ([docs/financial_methodology.md](docs/financial_methodology.md)):

- **Daily returns** with `LAG()`, gap-aware: a return is labelled one-session only when the previous record is the immediately preceding trading session; returns across gaps are reported separately.
- **20- and 50-session moving averages** using window frames, NULL until the minimum observations exist.
- **Performance** over the common analysis window: adjusted-price return, price-only return, dividends, approximate total return (clearly distinguished from a precise total return), highest/lowest close, maximum drawdown, rankings.
- **Volatility:** sample standard deviation of one-session returns, annualised by √252, minimum 20 returns.
- **Sector analysis:** equal-weight indices of the selected companies (explicitly not official sector indices), sector volatility vs average constituent volatility.
- **Volume analysis:** trailing averages without look-ahead, unusual-volume flags, medians.
- **Normalised performance** (base 100) and **corporate-action analysis** (reported vs adjusted ex-date returns; descriptive, no causal claims).

**Verification:** 27 edge-case tests on synthetic data (gaps, holidays, weekends, minimum samples, hand formulas), and an independent pandas recomputation from the raw files that agrees with the SQL views on 8 / 8 metrics for all 20 securities (maximum difference 2.1 × 10⁻⁶ percentage points).

---

## SQL competencies demonstrated

| Concept | Where |
|---|---|
| Schema design, primary/foreign/unique keys, CHECK constraints, partial unique indexes | `database/02_create_tables.sql`, `03_create_indexes.sql` |
| Safe conversion of untrusted text, typed staging views | `database/06_data_validation.sql` (sections A–B) |
| Data quality rules as `INSERT … SELECT`; unpivoting with `CROSS JOIN LATERAL (VALUES …)` | `database/06_data_validation.sql` |
| UPSERT (`INSERT … ON CONFLICT`), idempotent loads, `UNIQUE NULLS NOT DISTINCT` | `04`, `06`, `07` |
| Window functions: `LAG`, `ROW_NUMBER`, `RANK`, `PARTITION BY`, frames, running maximum | `database/08_financial_analysis.sql` |
| CTEs, correlated and scalar subqueries, `GROUP BY` / `HAVING`, `FILTER`, `percentile_cont` | `08`, `09`, `queries/` |
| Views as a single source of truth; presentation views | `08`, `09`, `10` |
| PL/pgSQL functions, procedures with per-batch `COMMIT`, triggers enforcing a workflow | `06`, `07` |
| Transactions, savepoints and rollback-based tests | `database/tests/`, `database/12_validation_tests.sql` |
| Least-privilege roles and grants | `database/13_security_grants.sql` |
| Query tuning with `EXPLAIN ANALYZE` and planner statistics (`ANALYZE`) | documented in [docs/api.md](docs/api.md) |

The **SQL Query Library** (`queries/`, 16 files) contains documented business questions (completeness, duplicates, anomalies, lineage, returns, moving averages, performance, sectors, volatility, volume, corporate actions and quality reporting), each with objective, SQL concepts and assumptions.

---

## Read-only API and security

FastAPI service with **25 GET endpoints**, connecting as `equityiq_reader`:

1. **Privileges:** SELECT only; no write or DDL rights; pipeline functions revoked.
2. **Role defaults:** every session read-only; 5-second statement timeout.
3. **Application:** fixed SQL with bound parameters, validated and size-capped inputs, GET-only routes, and **no endpoint that accepts SQL text**. The SQL Library runs allowlisted, start-up-checked files only.

Verified on the real database as the reader role: INSERT, DELETE (even in an explicit read-write transaction), calling pipeline functions and DDL were all refused. Details: [docs/api.md](docs/api.md).

## Dashboard

React + TypeScript dashboard that **computes nothing itself**: every figure comes from the API (SQL views).

- **Overview:** headline figures with source and as-of dates, normalised performance, sector performance, best/worst performers, recent issues.
- **Data Quality:** dimension scores with definitions, a filterable issue register with rule explanations and affected records, the rule catalogue, quarantine, and clearly labelled synthetic test results.
- **SQL Library:** view, copy and run allowlisted queries, and see the definitions of the views they use.
- **Securities, Corporate Actions, Ingestion & Lineage:** price and volume charts, ex-date behaviour, batch history, and record-level lineage from a published price back to the raw provider value.

Accessibility choices: status shown with colour **and** icon **and** text, a colour-vision-checked chart palette, one y-axis per chart, table views alongside charts. Details: [docs/dashboard.md](docs/dashboard.md). Screenshots will be added.

---

## Testing and verification

| Suite | Command | Last result (2026-11-24) |
|---|---|---|
| Schema constraints | `scripts/run_schema_tests.sh` | 56 / 56 passed |
| Ingestion reconciliation (real data, read-only) | `scripts/run_ingestion_checks.sh` | 5,020 / 5,020 records; 0 duplicates, 0 unparseable values, 0 off-calendar dates |
| Data quality framework (synthetic fixtures) | `scripts/run_quality_tests.sh` | 77 / 77 passed |
| Financial analytics edge cases (synthetic) | `scripts/run_analytics_tests.sh` | 27 / 27 passed |
| Independent analytics cross-check (real data) | `.venv/bin/python scripts/crosscheck_analytics.py` | 8 / 8 metrics within tolerance |
| SQL Query Library (read-only execution) | `scripts/run_query_library.sh` | 16 / 16 executed |
| API (security, validation, endpoints, errors) | `scripts/run_api_tests.sh` | 67 / 67 passed |
| Dashboard | manual browser verification + TypeScript build | all 6 pages verified; no automated UI tests yet |

Synthetic tests run in a **separate database** (`equityiq_test`) built from the same DDL; the fixture loader refuses to run against any database whose name does not contain `test`.

---

## Project structure

```
equity-iq/
├── database/                 # numbered SQL scripts: schema → rules → validation → promotion → analytics → views → grants
│   ├── 01_create_schema.sql … 13_security_grants.sql
│   ├── 11_quality_test_data.sql, 12_validation_tests.sql   # synthetic fixtures and tests (test DB only)
│   └── tests/                # schema, ingestion reconciliation and analytics tests
├── queries/                  # SQL Query Library (16 documented, read-only queries)
├── backend/
│   ├── ingestion/            # fetch_snapshot.py, load_snapshot.py, validate.py
│   ├── routes/               # read-only API routes
│   ├── tests/                # pytest API tests
│   └── main.py, database.py, query_library.py
├── frontend/                 # React + TypeScript dashboard (Vite)
├── scripts/                  # db_init, test runners, analytics cross-check
├── docs/                     # architecture, data dictionary, ER diagram, methodology, API, dashboard
├── data/                     # raw/ (git-ignored), quality-tests/ (synthetic test results)
├── docker-compose.yml        # optional PostgreSQL via Docker
├── requirements.txt          # pinned Python dependencies
└── .env.example              # configuration template (no secrets)
```

---

## Getting started

**Prerequisites:** PostgreSQL 17 (Homebrew or Docker), Python 3.12, Node.js 20+.

```bash
# 1. Database
brew install postgresql@17 && brew services start postgresql@17
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
#    (or: docker compose up -d, and set PG_ADMIN_USER=postgres in .env)

# 2. Configuration: copy and replace the placeholder passwords
cp .env.example .env

# 3. Roles, databases and all SQL objects
scripts/db_init.sh            # main database
scripts/db_init.sh --test     # isolated test database

# 4. Python environment
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt

# 5. Pipeline: download snapshot → load staging → validate and promote
.venv/bin/python -m backend.ingestion.fetch_snapshot
.venv/bin/python -m backend.ingestion.load_snapshot
.venv/bin/python -m backend.ingestion.validate

# 6. Dashboard + API in one process → http://127.0.0.1:8000 (API docs at /docs)
cd frontend && npm install && npm run build && cd ..
.venv/bin/uvicorn backend.main:app
```

The snapshot window is fixed in `backend/ingestion/config.py`. Data downloaded on a different date may differ if the provider revises history; the pipeline detects such revisions and holds them for review.

---

## Roadmap

- [x] Phase 1: Database architecture, constraints, ER diagram, data dictionary
- [x] Phase 2: Real data acquisition with batch metadata, checksums and rerun protection
- [x] Phase 3: SQL data quality framework, quarantine, issue workflow, metrics, synthetic tests
- [x] Phase 4: SQL financial analytics with edge-case tests and an independent cross-check
- [x] Phase 5: Read-only API with a least-privilege role and an allowlisted SQL library
- [x] Phase 6: Dashboard (Overview, Data Quality, SQL Library, Securities, Corporate Actions, Ingestion & Lineage)
- [ ] Phase 7: Final documentation, screenshots, project case study, clean-environment reproduction, end-to-end verification
- [ ] Continuous integration (SQL and API test suites on every push)
- [ ] Automated frontend tests
- [ ] Hosted demo
- [ ] Possible extensions: second data source for cross-validation, versioned adjusted-price history, issue workflow actions in the UI, dark mode

## Limitations

- Single data provider; anomalies cannot be confirmed or refuted without a second source.
- Company reference data reflects the retrieval date, not point-in-time history; the universe was chosen at build time (survivorship).
- No stock splits occurred in the snapshot, so split handling is demonstrated with synthetic fixtures only.
- Sector figures are equal-weight indices of four selected companies, not official indices; √252 annualisation assumes independent returns.
- Adjusted prices follow the provider's methodology; a later download will legitimately restate adjusted history.

## Data terms and disclaimer

Market data is sourced from Yahoo Finance through the open-source `yfinance` library and is subject to Yahoo's terms of use; raw data is not redistributed in this repository. All figures describe a fixed historical period and are provided to demonstrate data management techniques only. Nothing here is investment advice.
