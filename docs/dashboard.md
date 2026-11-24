# EquityIQ — Dashboard (Phase 6)

React 19 + TypeScript 5.9 + Tailwind CSS 4 + Recharts 3, built with Vite 7 (`frontend/`). The dashboard is a **presentation layer only**: every figure comes from the read-only API, which reads SQL views. No metric is calculated or hard-coded in the browser (the only client-side arithmetic is rebasing the start/end of an already-normalised series for the optional table view, and selecting a 3M/6M range of rows to chart).

## Run it

```bash
# one process: API + built dashboard on http://127.0.0.1:8000
cd frontend && npm install && npm run build && cd ..
.venv/bin/uvicorn backend.main:app

# development (hot reload): API on 8000 (or set EQUITYIQ_API_PORT), Vite on 5173 proxies /api
.venv/bin/uvicorn backend.main:app --reload
cd frontend && npm run dev
```

FastAPI serves `frontend/dist` only if it exists, after all API routes, GET only; unknown `/api/*` paths still return a JSON 404.

## Pages

| Page | Priority | Contents | API endpoints |
|---|---|---|---|
| Overview | P1 | 8 KPI cards (securities, market vs validated records, record pass rate, open defects vs anomalies, quarantine, last ingestion); normalised performance (sector indices or a sector's securities) with optional table; sector bar chart + table; best/worst performers; recent issues | `/api/overview`, `/api/sectors/index`, `/api/performance/normalised` |
| Data Quality | P1 (showcase) | Tabs: dimension scores (numerator/denominator/definition), records vs issues, issue summary, field completeness, batch outcomes · filterable, paged issue register with detail drawer (rule, why it matters, handling, affected records and their outcomes) · rule catalogue · quarantine · synthetic tests (labelled) | `/api/quality/*` |
| SQL Library | P1 | Queries grouped by category; objective, expected output, assumptions, concepts; syntax-highlighted SQL with copy; definitions of the views used; Run → actual output with row count and timing | `/api/library/*` |
| Securities | P2 | Search, sector and quality-status filters; latest close, day and period return, volume, volatility, quality status; detail page with KPI tiles, adjusted close + SMA20/50 chart (Snapshot/6M/3M), separate volume chart (unusual days highlighted), corporate actions, issues | `/api/securities*` |
| Corporate Actions | P2 | Interpretation guide; filters (ticker, type, dates); amount, yield, reported vs adjusted ex-date return, move within ±2 sessions | `/api/corporate-actions` |
| Ingestion & Lineage | P2 | Six-stage flow with live counts; batch history (status, timing, received/accepted/rejected/flagged, checksum); record lineage lookup (published value vs raw provider text, batch, snapshot, request settings, issues) | `/api/ingestion/batches`, `/api/lineage/*` |

Every page has loading, empty and error states (with retry). The header on every page shows the provenance: "Historical snapshot", the as-of window, the source and the snapshot label, all from the API.

## Design decisions

| Decision | Reason |
|---|---|
| Left sidebar, neutral canvas, navy text, one blue accent, Inter with tabular numbers | Brief §10 visual direction; numbers align in tables |
| Status = colour **+ icon + text** (✓ Passed, ▲ Warning, ✖ Critical, ◆ Review anomaly) | Never colour alone (accessibility, brief) |
| Confirmed defects and reviewable anomalies have distinct badges everywhere | Core message of the quality framework |
| Categorical palette validated with the dataviz palette checker (light mode): all hard gates pass; 3 slots < 3:1 contrast → every chart has a legend and a table view | Colour-vision-deficiency safety; "relief rule" |
| Colour follows the entity (each sector has a fixed colour across charts) | Filtering never repaints series |
| Never a dual axis: price and volume are separate stacked charts | One-axis rule |
| SMA lines start only once 20/50 observations exist (API returns NULL) | Mirrors the SQL minimum-sample rule |
| Issue/ticker inputs validated client-side (upper-case pattern) and server-side | Fast feedback; server remains the authority |
| Pages lazy-loaded; React and Recharts in separate chunks | SQL Library page needs ~7 KB of page code; chart library (470 KB) only on chart pages |
| No dark mode | Not required by the brief; noted as a possible enhancement (palette has validated dark steps) |

## Verification (2026-11-24)

Checked in the built-in browser against the real main database through the API:
- **All 6 pages render with real data and no console errors.**
- Values cross-checked with the database: KPIs (5,020 validated records, 100.00 % pass rate, 0 defects, 79 anomalies, 0 quarantined), sector returns (Energy +44.40 % … Consumer Discretionary −11.40 %), best/worst performers (COP +55.31 %, NKE −43.69 %), NVDA 2026-11-23 +31.48 % issue, dimension scores 5,020/5,020, field completeness, batch outcomes, 72 corporate actions, lineage for NVDA 2026-11-23.
- Interactions: ticker filter (lower-case input upper-cased and filtered), issue drawer (Esc/close), SQL Library Run (10 rows, 20.5 ms), quarantine empty state, synthetic tab banner (77/77), securities list → detail charts, lineage Trace.
- `npm run build`: TypeScript typecheck clean, production build ok, no chunk-size warning after code-splitting.
- Production serving: `/`, `/securities/NVDA`, `/library/daily_returns` → HTML; assets → JS/CSS; `/api/health` → JSON; `/api/nope` → JSON 404; `POST /` → 405. API tests 67/67 after adding static serving.

Issues found and fixed during verification:
- The issue drawer labelled a published-but-flagged record "Passed"; now shows the real outcome ("Promoted · flagged", "Quarantined", "Redundant copy", "Held for review").
- Sector bar axis ended on an uneven tick (40 %, 50 %); domain now rounds to multiples of 20.
- An existing process already listened on port 8000; the dev proxy port is configurable (`EQUITYIQ_API_PORT`) instead of stopping it.
- Single 805 KB bundle warning → route-level code-splitting.

Not done: automated frontend unit/E2E tests (verification was manual in the browser plus TypeScript and the API test suite).

## Screenshots (Phase 7)

`scripts/capture_screenshots.sh [base_url]` captures the README screenshots with headless Chrome (throwaway profile, 1440 px wide) from a running instance. Reviewing the first set found three presentation issues, all fixed before the final capture:
- date axes repeated month labels (ticks were evenly spaced, not monthly) → one tick per month;
- the Data Quality "batch outcomes" table listed `SKIPPED` rerun batches with 0 records → only loaded batches are shown there (reruns remain visible in Ingestion & Lineage as audit history);
- the six-step data-flow diagram wrapped onto two lines at desktop width → narrower step boxes.

| Page | File |
|---|---|
| Overview | `docs/screenshots/overview.png` |
| Data Quality (scores) | `docs/screenshots/data-quality.png` |
| Issue detail | `docs/screenshots/issue-detail.png` |
| SQL Library | `docs/screenshots/sql-library.png` |
| Security detail (NVDA) | `docs/screenshots/security-detail.png` |
| Ingestion & Lineage | `docs/screenshots/ingestion-lineage.png` |
