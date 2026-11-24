# EquityIQ — Data Acquisition (Phase 2)

All figures below come from the actual load of snapshot
`yahoo_20251124_20261123_retrieved_20261124T132237Z` (retrieved 2026-11-24 13:22 UTC),
measured by `scripts/run_ingestion_checks.sh`.

## Snapshot definition

| Item | Value |
|---|---|
| Source | Yahoo Finance via `yfinance` 1.8.0 (subject to Yahoo's terms of use) |
| Securities | 20 (from `ref.security_universe`), 5 sectors × 4 |
| Window | **2025-11-24 to 2026-11-23 inclusive** (fixed; last completed NYSE session before the build date) |
| Trading calendar | `exchange_calendars` 4.13.3, calendar `XNYS` |
| Expected sessions | 251 per security → 5,020 expected price records |
| Request settings | `interval=1d`, `auto_adjust=False`, `back_adjust=False`, `repair=False`, `actions=True` |

Why fixed: a "last 12 months from today" window would change every day, make results unreproducible, and make the data look stale whenever the project is viewed later. Timeliness is measured against the snapshot cutoff, not today's date.

## Pipeline

```
fetch_snapshot  ──► data/raw/<snapshot_label>/          (git-ignored; not redistributed)
                      manifest.json   timestamps, settings, per-ticker status, SHA-256 checksums
                      prices/<TICKER>.json      provider rows, unchanged, incl. Dividends/Stock Splits
                      reference/<TICKER>.json   provider company metadata (full `info` payload)
                      calendar/XNYS.json        every calendar day with session/holiday flags
load_snapshot   ──► audit.ingestion_logs  (one batch per dataset)
                    staging.raw_stock_prices / raw_corporate_actions / raw_company_reference
                    ref.trading_calendar
```

```bash
.venv/bin/python -m backend.ingestion.fetch_snapshot     # download (≈1 min)
.venv/bin/python -m backend.ingestion.load_snapshot      # load latest snapshot
scripts/run_ingestion_checks.sh                          # reconciliation report
```

Python performs no validation or cleaning. Values are written to staging as text exactly as received, and each row keeps its full source record in `raw_payload` (jsonb).

## Rerun behaviour

| Scenario | Result | Enforced by |
|---|---|---|
| Load the same snapshot again | Each dataset logged as `SKIPPED`, 0 rows inserted | Loader check **and** partial unique index `ux_ingestion_snapshot_loaded_once (batch_type, source_checksum)` |
| Fetch again later (new snapshot, possibly revised provider data) | Loaded as new batches; earlier batches kept for audit | Production dedupe/upsert and conflict detection in Phase 3 |
| Load fails mid-way | Transaction rolled back, batch marked `FAILED` with the error | Batch row committed *before* the data transaction |
| Ticker unavailable at fetch time | Recorded in manifest; batch marked `PARTIAL`; no data invented | Loader |

Verified: the same snapshot was loaded twice → batches 1–4 `SUCCEEDED`, batches 5–8 `SKIPPED`, row counts unchanged.

## Actual results

| Measure | Result |
|---|---|
| Price records received | **5,020** of 5,020 expected (100.00% session coverage, every ticker 251/251) |
| Date range | 2025-11-24 to 2026-11-23 |
| Rows on weekends/holidays or outside window | 0 |
| Duplicate ticker+date within batch | 0 |
| Unparseable dates / prices / volumes | 0 / 0 / 0 |
| Rows with any null price or volume | 0 |
| Zero-volume rows | 0 |
| Typed columns vs preserved payload mismatches | 0 of 5,020 |
| Corporate actions | 72 dividends across 18 tickers; **0 stock splits** in window. AMZN and TSLA paid no dividends. |
| Company reference rows | 20 of 20 |
| Calendar | 365 days: 249 full sessions, 2 early closes (2025-11-28, 2025-12-24), 10 holiday closures, 104 weekend days |
| Fetch / load runtime | 54 s fetch (20 tickers, 1.5 s pause each) / 0.4 s load |

A clean first snapshot is a real result, not a guarantee: the data quality framework (Phase 3) still runs every rule, and the synthetic fixtures prove the rules catch the defects this snapshot happens not to contain.

## Price adjustment conventions — verified, not assumed

**Hypothesis:** with `auto_adjust=False`, Yahoo's `Close` is the reported close (not dividend-adjusted) and `Adj Close` is dividend-adjusted with a multiplicative factor applied to earlier dates.

**Test (SQL, check 11):** compute `ratio = adjusted_close / close_price` per day. If the hypothesis holds, the ratio is exactly 1 on the last day, constant between ex-dates, and steps up on each ex-dividend date by `1 / (1 − dividend / previous close)`.

**Result:**
- 72 ratio steps found, **all 72 on ex-dividend dates**, 0 steps without a dividend, 0 dividends without a step.
- Ratio = 1 on 2026-11-23 for all 20 tickers.
- Step size equals the dividend-implied factor to 6 decimal places (e.g. AAPL 2026-02-09: dividend 0.26, previous close 278.12, observed 1.000936, implied 1.000936).

**Conclusion:** `Close` is not dividend-adjusted; `Adj Close` uses the standard multiplicative dividend adjustment. Returns will use `adjusted_close` (price return including dividend effect), and reported prices stay available separately.

**Splits:** no split occurred in the window, so split handling **could not be verified empirically from this snapshot**. Yahoo documents `Close` as split-adjusted; we treat that as unverified provider documentation. Split validation rules are exercised with synthetic fixtures in Phase 3.

## Provider precision finding

Raw prices arrive with up to 15 decimals (e.g. `1025.56005859375`). Cause: Yahoo stores prices as 32-bit floats (~7 significant digits); `1025.56005859375` is exactly float32(1025.56).

Tested on every value: **20,080 of 20,080** open/high/low/close values (100%) equal the float32 representation of a whole-cent price.

**Phase 3 rule:** promote reported OHLC rounded to 2 decimals. This recovers the quoted price exactly, and it is documented and reversible because staging keeps the original text. `adjusted_close` is a derived value, not a quoted price; it is stored at `numeric(19,6)` with the caveat that only ~7 significant digits are meaningful.

## Limitations

- **Single provider.** No second source to cross-check prices; consistency rules are internal only.
- **Reference data is current, not point-in-time.** `info` (sector, industry, name) reflects 2026-11-24, not each historical date.
- **Survivorship.** The universe was chosen at build time; it is not an index membership history.
- **Dividend dates are ex-dates** as reported by Yahoo; amounts are per share in USD and not independently verified.
- **Yahoo terms.** Raw downloads are kept locally and git-ignored; the repository ships the download scripts instead.
- **Calendar.** NYSE (XNYS) is applied to Nasdaq-listed securities; both follow the same US equity holiday schedule in this window.
- **Exchange codes** are Yahoo's (`NMS` = Nasdaq Global Select, `NYQ` = NYSE), not ISO MIC codes.

## Reproducibility check (Phase 7)

The public repository was cloned into an empty directory and the README's setup steps were followed literally with new role and database names (`repro_owner`, `repro_reader`, `equityiq_repro`, `equityiq_repro_test`), a new virtual environment and a **fresh download** (retrieved 2026-11-24 16:07 UTC, 2 h 45 min after the original snapshot).

| Step | Result | Time |
|---|---|---|
| `db_init.sh` (main + test) | roles, databases and all SQL objects created | ~3 s |
| `pip install -r requirements.txt` | pinned versions installed | 22 s (package cache available) |
| `fetch_snapshot` | 20/20 tickers, 5,020 rows | 78 s |
| `load_snapshot` + `validate` | 5,020 prices, 72 dividends, 20 companies promoted; 0 confirmed defects; 79 anomaly issues | ~2 s |
| `npm ci` + `npm run build` | clean install from lockfile, production build | 8 s |
| All test suites (schema, quality, analytics, API, cross-check, library, reconciliation) | all passed after the fixes below | ~15 s |

**Same data twice?** Comparing the two downloads field by field (40,160 fields):

| Field group | Result |
|---|---|
| Trading calendar | identical (same checksum) |
| Open, high, low, close, volume, dividends, splits (35,140 fields) | identical |
| Adjusted close | **904 values differ**, all by 1–2 float32 steps (max relative difference 2.4 × 10⁻⁷), only for dividend-paying tickers; AMZN and TSLA unchanged |
| Company reference | differs (Yahoo's profile payload includes live fields such as current price) |

Interpretation: the provider recomputes the adjusted series on each request in 32-bit floating point; reported prices are stable. This finding changed the quality framework: rule DQ-CNS-006 now compares adjusted close with a relative tolerance of 1 × 10⁻⁶ instead of exact 6-decimal equality, which had held all 904 noise differences as "revisions" (see [data_quality_framework.md](data_quality_framework.md)).

Two problems found by the reproduction and fixed:
1. DQ-CNS-006 false revisions (above): 904 → 0 after the fix, with a genuine 1 % revision still flagged (new synthetic tests).
2. An API test hard-coded the role name `equityiq_reader` and failed for any other configured name; it now compares with the names in `.env`. (Also: `load_snapshot` printed a hard-coded database name; it now prints the database it is actually connected to.)
