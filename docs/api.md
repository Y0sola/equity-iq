# EquityIQ — Read-only API (Phase 5)

FastAPI service over the validated database. It serves the dashboard (Phase 6) and exposes **only predefined, read-only queries**. Historical snapshot; not live data; not investment advice.

```bash
.venv/bin/uvicorn backend.main:app --reload     # http://127.0.0.1:8000/docs (interactive OpenAPI docs)
scripts/run_api_tests.sh                        # API tests against the synthetic test database
```

## Security model: three independent layers

| Layer | What it enforces | Where |
|---|---|---|
| 1. Database privileges | Role `equityiq_reader`: `SELECT` on tables/views only; no INSERT/UPDATE/DELETE/DDL; `EXECUTE` revoked on all pipeline functions and procedures | `database/13_security_grants.sql` |
| 2. Role defaults | `default_transaction_read_only = on`, `statement_timeout = 5s`, connection limit 20, NOSUPERUSER/NOCREATEDB/NOCREATEROLE | `scripts/db_init.sh` |
| 3. Application | Pool connections opened `read_only`; GET-only routes; fixed SQL with bound parameters (`%(name)s`); validated and bounded inputs; capped result sizes; **no endpoint accepts SQL text**; library runs allowlisted files only | `backend/` |

Verified directly as the reader role on the real database: INSERT, DELETE (even inside an explicit `BEGIN READ WRITE`), calling `audit.set_issue_status`, `CALL audit.process_pending_batches()`, `CREATE TABLE` → all refused; `pg_sleep(6)` cancelled by the 5 s timeout.

### Inputs and limits
- Tickers: `^[A-Z][A-Z.\-]{0,9}$`, and must be in the tracked universe (else 404).
- Enumerations (severity, status, issue class, category, sector, action type, quality status): fixed lists, else 422.
- Dates: ISO; `date_from ≤ date_to` else 422.
- `limit` 1–500, `offset` ≥ 0; price series ≤ 1,000 rows; library results ≤ 500 rows (`truncated` flag).
- Search text is matched with `strpos()`: plain substring, so `%` and `_` are not wildcards and nothing is ever concatenated into SQL.

### SQL Query Library allowlist
`backend/query_library.py` loads `queries/*.sql` at start-up and **refuses** any file that has an unsafe name, lacks the metadata header, is not a single `SELECT`/`WITH` statement, or does not end with `LIMIT n`. Queries are run by id only (`^[a-z0-9_]{1,64}$`). The detail endpoint also returns the definitions of the views a query reads (`pg_get_viewdef`), so the full logic is visible.

### Errors (no SQL or stack traces leak)
| Situation | Status | Body |
|---|---|---|
| Invalid parameter | 422 | FastAPI validation detail |
| Unknown ticker / issue / query / lineage record | 404 | `detail` |
| Database unreachable / pool exhausted | 503 | `{"error": "database_unavailable"}` |
| Statement timeout | 504 | `{"error": "query_timeout"}` |
| Any other database error | 500 | `{"error": "query_failed"}` (logged server-side) |
| Non-GET method | 405 | |

## Endpoints (all GET)

| Area | Endpoint | Purpose |
|---|---|---|
| System | `/api/health` | Role, database, read-only setting, timeout, library size |
| Overview (P1) | `/api/overview` | KPIs with source and as-of dates, best/worst 5, sector performance, recent issues |
| | `/api/performance/normalised?tickers=&sector=` | Base-100 series (≤ 20 tickers) |
| Data Quality (P1) | `/api/quality/summary` | Dimension scores (numerator/denominator), field completeness, issue counts, batch metrics |
| | `/api/quality/rules` | 37 rules with failing records vs issues |
| | `/api/quality/issues?ticker=&rule_id=&severity=&status=&issue_class=&category=&date_from=&date_to=&limit=&offset=` | Filterable, paged issue table (`total` included) |
| | `/api/quality/issues/{issue_id}` | Rule explanation, justification, proposed handling, affected records with outcomes |
| | `/api/quality/quarantine` | Quarantined raw records |
| | `/api/quality/synthetic-tests` | Exported synthetic test results, labelled `SYNTHETIC` |
| SQL Library (P1) | `/api/library`, `/api/library/{id}`, `/api/library/{id}/run` | List, inspect (SQL + view definitions), run with timing |
| Securities (P2) | `/api/securities?search=&sector=&quality_status=` | Table incl. not-validated securities |
| | `/api/securities/{ticker}` | Company, performance, volatility, volume |
| | `/api/securities/{ticker}/prices?date_from=&date_to=` | OHLC, adjusted close, SMA20/50, volume, unusual-volume flag |
| | `/api/securities/{ticker}/corporate-actions`, `/issues` | Per-security actions and issues |
| Analytics | `/api/performance/ranking`, `/api/volatility`, `/api/sectors`, `/api/sectors/index` | Performance, volatility, sector tables and index series |
| Corporate Actions (P2) | `/api/corporate-actions?ticker=&action_type=&date_from=&date_to=` | Filterable actions with ex-date behaviour |
| Ingestion & Lineage (P2) | `/api/ingestion/batches`, `/api/lineage/flow`, `/api/lineage/{ticker}/{date}` | Batch history, stage counts, record-level lineage |

Numbers: PostgreSQL `numeric` values are exact in the database and converted to JSON numbers at the API boundary.

## Test results

`scripts/run_api_tests.sh` rebuilds `equityiq_test`, loads the synthetic fixtures, runs the SQL pipeline and runs pytest as the read-only role: **67 passed, 0 failed** (0.47 s). Coverage: role and read-only enforcement, refused write methods, injection attempts in path and search, wildcard handling, every endpoint and filter, validation errors, pagination, 404s, all 16 library queries, view-definition display, simulated database outage (503), timeout (504), and no SQL leakage in 500 responses.

## Response times (real data, main database, median of 3, TestClient)

All 25 endpoints returned 200. Medians: 0.8–54 ms for most endpoints; `/api/securities/{ticker}` 193 ms and `/api/library/volume_analysis/run` 168 ms (both compute per-security statistics across the full series). Measured 2026-11-24 on a local machine; indicative only.

## Problems found while building the API
- **Decimals serialised as strings:** Pydantic v2 emits Python `Decimal` as JSON strings. Fixed by converting at the API boundary (`_json_ready`).
- **Stale planner statistics:** directly after a bulk load, the dimension-scores view took 3,330 ms because PostgreSQL had no statistics yet; after `ANALYZE` it took 2.5 ms. The pipeline now runs `audit.analyze_project_tables()` after promotion.
- **Slow numeric parsing:** field completeness took 520 ms on real data. Two fixes: a strict regex replaces `pg_input_is_valid()` (7× faster) and the unpivot view converts each value once. The stricter parser also **rejects** formats PostgreSQL itself accepts (`1_000`, hexadecimal `0x1A` = 26) that should never appear in a price file; new fixture F25 covers this.
- FastAPI 0.165 stores included routers lazily, so `len(app.routes)` under-counts; the OpenAPI spec lists all 25 paths.
- Known warning: Starlette recommends `httpx2` for its TestClient (deprecation warning only, tests unaffected).
