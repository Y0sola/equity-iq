# EquityIQ — Financial Methodology (Phase 4)

All analytics are SQL views in `database/08_financial_analysis.sql`, computed over **validated** data (`core`). Figures quoted below are actual outputs from the main database for snapshot `yahoo_20251124_20261123_retrieved_20261124T132237Z`. This is descriptive analysis of historical data, not investment advice or a forecast.

## Common conventions

| Item | Convention |
|---|---|
| Price basis | **Adjusted close** for returns, moving averages, volatility, normalisation and drawdown. Reported close for price return, highest/lowest close and ex-date behaviour. Adjustment convention verified in Phase 2: multiplicative dividend adjustment; no splits occurred in the window. |
| Return formula | `(current / previous − 1) × 100`, in percent |
| Daily return | Only when the previous record is the **immediately preceding XNYS session** (session numbers differ by 1). Otherwise the row is `MULTI_SESSION` and its return is reported separately in `multi_session_return_pct`, never as a daily return. First record: `FIRST_OBSERVATION`, no return. |
| Analysis window | First to last **common** date: dates on which every validated company has a price (`analytics.v_analysis_window`). Real data: **2025-11-24 to 2026-11-23**, 251 common dates, 20 companies. |
| Minimum samples | SMA20 needs 20 records, SMA50 50, volatility 20 one-session returns, volume baseline 20 prior records. Below the minimum: NULL (N/A), never a partial value. |
| No look-ahead | Baselines use only earlier records (`ROWS BETWEEN n PRECEDING AND 1 PRECEDING`). |
| Real-data gaps | None: 5,000 of 5,000 possible returns are one-session (20 first observations). Gap handling is exercised with synthetic fixtures. |

## Metrics

### Daily returns — `analytics.v_daily_returns`
`LAG()` over each company's records (`PARTITION BY company_id ORDER BY trade_date`) supplies the previous date, session number, close and adjusted close.
- `daily_return_pct`: adjusted, one-session only.
- `daily_price_return_pct`: reported close, one-session only (falls by about the dividend on ex-dates).
- `multi_session_return_pct`: adjusted, only across gaps.

**Hand check (real data, AAPL):** library query `queries/daily_returns.sql` prints the previous and current adjusted close next to the view's return and a manual `(adj / prev − 1) × 100` column. Synthetic test R2 compares them to 10 decimal places.

### Moving averages — `analytics.v_moving_averages`
Simple averages of adjusted close over the last 20 / 50 records (`ROWS BETWEEN 19|49 PRECEDING AND CURRENT ROW`). `obs_n` is the number of records in the window; `sessions_spanned_n` is the number of trading sessions the window covers. If spanned > observations, the window contains a data gap (test M3).

### Performance — `analytics.v_security_performance`
| Column | Definition | Caveat |
|---|---|---|
| `adjusted_return_pct` | adjusted close end / base − 1 | **Adjusted-price performance**: includes the dividend effect as embedded by the provider, i.e. roughly dividends reinvested at the ex-date. Not a precisely calculated total return (no tax or timing of payment, provider methodology). |
| `price_return_pct` | reported close end / base − 1 | Excludes dividends. |
| `dividends_per_share` | sum of validated dividends with ex-date in (base, end] | Ex-date basis. |
| `approx_total_return_pct` | (end close − base close + dividends) / base close | Simple approximation **without reinvestment**. |
| `highest_close`, `lowest_close` (+ dates) | extreme **reported** closes in the window | `ROW_NUMBER()` picks the earliest date on ties. |
| `period_high`, `period_low` | max intraday high / min intraday low | |
| `max_drawdown_pct` | min over time of (adjusted close / running peak − 1) | Running peak = `max() OVER (… ROWS UNBOUNDED PRECEDING)`. |
| `rank_overall`, `rank_in_sector` | `RANK()` by adjusted return | Ties share a rank. |

### Volatility — `analytics.v_volatility`
- Daily volatility = **sample** standard deviation (`stddev_samp`, n − 1) of one-session adjusted returns in the window.
- Annualised = daily × √252.
- Assumptions: about 252 trading sessions per year; returns independent and identically distributed (the √252 scaling relies on this, and real returns only approximately satisfy it); mean not subtracted beyond the sample sd.
- Multi-session returns are counted in `multi_session_returns_excluded` and not used.

### Normalised performance — `analytics.v_normalised_performance`
`100 × adjusted close / adjusted close on the base date`. Every series starts at 100 on 2025-11-24; the end value minus 100 equals `adjusted_return_pct` (test N2).

### Sector analysis — `v_sector_normalised`, `v_sector_performance`
- **Sector index:** equal-weight, buy-and-hold average of the constituents' normalised values. Only dates where *all* constituents have a value are included. This is an index of the four selected companies, **not an official sector index**.
- `equal_weight_return_pct` = average of constituents' adjusted returns = index end value − 100 (test S1).
- `sector_volatility_pct` = annualised sample sd of the sector index's daily returns (≥ 20 required). It is lower than `avg_constituent_volatility_pct` because the constituents do not move perfectly together (diversification).
- Volume: average of constituents' average daily volume, and their sum.

### Volume — `v_volume_analysis`, `v_volume_summary`
Trailing average of the previous 20 records; `volume_ratio = volume / trailing average`; unusual if ratio > 3, using the same threshold as quality rule DQ-ANO-002 (read from the rule catalogue, so the dashboard and the quality framework cannot disagree; test U1). Median via `percentile_cont(0.5) WITHIN GROUP (ORDER BY volume)`.

### Corporate actions — `v_corporate_action_impact`
For each validated dividend or split: previous close, ex-date close, reported vs adjusted one-session return, dividend as % of previous close, and the largest absolute adjusted move within ±2 sessions (`significant_move_nearby` if above the 10% DQ-ANO-001 threshold). **Descriptive only: no causal claims.**
On ex-dividend dates, `reported_return − adjusted_return ≈ −dividend_yield`, which demonstrates what the adjustment does (e.g. AVGO 2025-12-22: −0.192 vs a yield of 0.191%).

## Verification

| Check | Method | Result |
|---|---|---|
| Synthetic edge cases | `scripts/run_analytics_tests.sh`: 27 tests on fixtures with gaps, holidays, weekends, a level shift, a volume spike, a dividend and an excluded company; hand formulas recomputed in SQL from `core` | **27/27 passed** |
| Independent implementation | `scripts/crosscheck_analytics.py`: pandas recomputes 8 metrics directly from the raw snapshot JSON (bypassing staging, validation and SQL) | **8/8 metrics agree** for all 20 securities; max difference 2.1 × 10⁻⁶ percentage points (adjusted return), explained by 6-dp storage of adjusted close |
| Query library | `scripts/run_query_library.sh`: all 16 queries in a read-only transaction | 16/16 executed; each < 0.2 s |
| Regression | Phase 3 quality tests after anomaly checks were switched to these views | 76/76 passed; real-data anomaly issues unchanged (79) |

## Real-data results (2025-11-24 → 2026-11-23)

**Securities (adjusted-price performance):**
- Best: COP +55.31 %, CVX +42.70 %, EOG +40.69 %, MRK +38.89 %, XOM +38.88 %.
- Worst: NKE −43.69 %, AVGO −16.42 %, NVDA −9.37 %, TSLA −7.74 %, MCD −7.02 %.
- Deepest drawdown: NKE −50.15 %; NVDA −47.53 %.
- Most volatile (annualised): NVDA 51.97 %, AVGO 49.23 %, TSLA 47.13 %. Least: MCD 20.74 %, PFE 20.89 %, JNJ 21.38 %.

**Sectors (equal-weight, 4 selected companies each):**

| Sector | Equal-weight return | Best / worst constituent | Sector index vol | Avg constituent vol |
|---|---|---|---|---|
| Energy | +44.40 % | COP / XOM | 26.98 % | 28.70 % |
| Healthcare | +24.24 % | MRK / UNH | 18.67 % | 27.25 % |
| Financials | +4.40 % | MS / BAC | 24.72 % | 27.46 % |
| Information Technology | +1.48 % | AAPL / AVGO | 25.88 % | 40.07 % |
| Consumer Discretionary | −11.40 % | AMZN / NKE | 22.28 % | 34.88 % |

**Corporate actions:** 72 dividends; 0 splits; no dividend ex-date had an adjusted move above 10% within ±2 sessions.

These are measured outcomes of the stated formulas over a fixed, single-provider snapshot. They explain nothing about *why* prices moved.

## Limitations
- Single provider; adjusted prices follow Yahoo's methodology.
- Equal-weight sector figures cover four hand-picked companies each, with survivorship (universe chosen at build time).
- √252 annualisation assumes independent returns; real returns cluster in volatility.
- Highest and lowest close use reported prices, which on dates before a dividend are not comparable one-for-one with later prices; performance uses adjusted prices for that reason.
- No splits in the window, so split-period behaviour is only demonstrated with synthetic data.

## SQL concepts demonstrated (where to find them)

| Concept | Example location |
|---|---|
| SELECT, WHERE, ORDER BY | every view and `queries/*.sql` |
| INNER / LEFT JOIN | `queries/completeness.sql` (anti-join), `v_security_performance` (dividends LEFT JOIN) |
| CROSS JOIN | `queries/completeness.sql`, `v_normalised_performance` |
| GROUP BY, aggregates, FILTER | `v_volatility`, `v_security_performance`, `queries/consistency_checks.sql` |
| HAVING | `v_analysis_window`, `queries/duplicate_detection.sql` |
| CASE | `v_daily_returns` (return type), `queries/moving_averages.sql` |
| CTEs (WITH) | `v_security_performance`, `v_sector_performance` |
| Subqueries (scalar, correlated) | `v_analysis_window`, `v_corporate_action_impact`, `queries/volume_analysis.sql` |
| LAG | `v_daily_returns` |
| ROW_NUMBER | `v_security_performance` (highs/lows), `queries/normalised_performance.sql`, duplicate copies in `06` |
| RANK | `v_security_performance`, `v_volatility`, `v_sector_performance` |
| PARTITION BY | `v_daily_returns`, `rank_in_sector` |
| Window frames | `v_moving_averages`, `v_volume_analysis`, running peak in `v_security_performance` |
| Views | `analytics.*` |
| Keys and constraints | `02_create_tables.sql` |
| Indexes (incl. partial and unique) | `03_create_indexes.sql` |
| Transactions | `load_snapshot.py`, `process_pending_batches()` (COMMIT per batch), all test files (ROLLBACK, SAVEPOINT) |
| UPSERT | `04_seed_reference_data.sql`, `record_violations()`, `promote_reference_batch()` |
| Percentile (ordered-set aggregate) | `v_volume_summary` |
