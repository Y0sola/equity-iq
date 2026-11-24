# EquityIQ — Project Case Study

*Equity market data management and data quality, built SQL-first.*

## Problem

Analysts depend on market data they did not produce. Vendor files contain gaps, duplicates, malformed values, impossible prices, silent revisions, and genuine extreme moves that look like errors. The work of a data management function is to turn that into data people can trust, and to be able to prove, for any published number, that it is complete, valid, consistent, unique and traceable to its source.

EquityIQ builds that function end to end for 20 US equities across five sectors, using a fixed 12-month historical snapshot (2025-11-24 → 2026-11-23) from Yahoo Finance.

## Approach

| Stage | What was built | Key idea |
|---|---|---|
| Model | PostgreSQL with five schemas: `ref`, `staging`, `core`, `audit`, `analytics` | Trust levels are physical: raw data cannot be confused with validated data |
| Acquire | Python fetches untouched provider data into checksummed snapshot folders, then loads staging as text | Keep everything the source sent, so defects are measured, not lost |
| Validate | 37 SQL rules write record-level failures and an issue register | Separate "how many records are bad" from "how many problems exist" |
| Promote | A single outcome view decides quarantine / redundant / held / accepted | One definition drives promotion, batch counts and metrics |
| Analyse | Financial analytics as SQL views (returns, moving averages, volatility, sectors, corporate actions) | Gap-aware returns; minimum samples; no look-ahead |
| Serve | Read-only API (25 GET endpoints) and a dashboard that computes nothing itself | Least privilege; allowlisted queries; every number traceable to SQL |

## Key technical decisions

1. **Permissive staging, strict core.** Staging stores text plus the original JSON, so `"abc"` or `2026-13-45` is kept and reported; `core` has NOT NULL, CHECK, UNIQUE and foreign-key constraints as a final safety net.
2. **Confirmed defects vs reviewable anomalies.** Provably wrong data is quarantined; unusual but possibly genuine data is published and flagged. A CHECK constraint makes it impossible to configure an anomaly rule to discard data.
3. **Idempotency by design.** Snapshot checksums with a partial unique index prevent double loads; stable issue keys (`rule|ticker|date|field`) make re-validation update issues instead of duplicating them; production prices are insert-only, and conflicting re-deliveries are held for review.
4. **Verify the provider, don't assume it.** SQL showed that the adjusted/close ratio changed on exactly the 72 ex-dividend dates, by the expected factor, so adjusted close is the return basis. It also showed that all 20,080 reported prices are float32 representations of whole cents, so rounding to cents is lossless.
5. **One definition per metric.** Daily returns and unusual volume are defined once as views and used by both the analytics and the anomaly checks.
6. **Three layers of read-only.** SELECT-only grants, read-only sessions with a 5-second timeout, and an API that accepts no SQL text.

## Validation

| Evidence | Result |
|---|---|
| Synthetic fixtures (isolated test DB) with expected outcomes written first | 45 fixtures; 79/79 data quality tests; all 37 rules exercised |
| Schema constraint tests | 56/56 |
| Analytics edge cases (gaps, holidays, minimum samples, hand formulas) | 27/27 |
| Independent pandas recomputation from raw files | 8/8 metrics agree (≤ 2.1 × 10⁻⁶ percentage points) |
| API tests (security, validation, errors) | 67/67 |
| Clean-clone reproduction following the README with a fresh download | all suites pass after two fixes found by the reproduction |

## Results (real data)

- 5,020 / 5,020 expected daily records received and validated (100.00 % session coverage); 72 dividends; 0 splits.
- 0 confirmed defects, 0 quarantined records.
- 79 reviewable anomalies on 58 records, published and flagged, including NVDA +31.48 % on 2026-11-23 (hand-checked; cause not determinable from a single source, so it stays a review item rather than an error).
- Adjusted-price performance ranged from +55.31 % (COP) to −43.69 % (NKE); Energy was the strongest equal-weight sector (+44.40 %), Consumer Discretionary the weakest (−11.40 %).

## Lessons learned

- **Testing finds what reasoning misses.** Writing fixtures exposed that anomaly checks did not re-evaluate a neighbouring day when a late record closed a gap. Re-downloading the data exposed float32 noise in the provider's adjusted prices, which had turned into 904 false "revisions". Reproducing from a clean clone exposed a test that only worked with one role name.
- **Library defaults are decisions.** The data library's default (`auto_adjust=True`) would have silently replaced reported closes with adjusted ones; PostgreSQL's numeric parser accepts `0x1A` as 26. Both are now explicit.
- **Performance is part of correctness.** A quality view took 3.3 s on freshly loaded data because planner statistics were missing; `ANALYZE` after each load made it 2.5 ms.
- **Report what is true, including the boring result.** A clean first snapshot (0 defects) is reported as such; the synthetic fixtures, not the real data, are the evidence that the rules work.

## Limitations and next steps

Single data provider (no cross-source confirmation of anomalies); reference data is current rather than point-in-time; equal-weight sector figures are not official indices. Planned: continuous integration for the SQL and API suites, automated frontend tests, a hosted demo, and a second data source for cross-validation.
