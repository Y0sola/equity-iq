-- =============================================================================
-- 08_financial_analysis.sql
-- Purpose : Financial analytics over VALIDATED data (core schema) as read-only views.
-- Phase   : 4 — Financial analytics
-- Idempotent: yes (CREATE OR REPLACE VIEW)
--
-- Every view is the single definition of its metric. The data quality checks in 06
-- (anomalies) and the API/dashboard read these same views, so a "daily return" means
-- exactly one thing everywhere. Methodology and caveats: docs/financial_methodology.md
--
-- Conventions
--   * Price basis for returns, moving averages, volatility and normalisation:
--     ADJUSTED close (dividend-adjusted by the provider; verified in Phase 2).
--     Reported close is used only where stated (reported price return, highs/lows).
--   * Returns in PERCENT: (current / previous - 1) * 100.
--   * A "daily" (one-session) return is only computed when the previous record is the
--     immediately preceding XNYS trading session. Returns across gaps are reported
--     separately as multi-session returns and never mixed into daily statistics.
--   * Minimum observations are enforced; below the minimum the result is NULL (N/A).
--   * Only data inside the analysis window is used: first to last COMMON date (the
--     dates on which every validated company has a price).
--
-- Views
--   ref.v_trading_sessions             session numbering per exchange
--   analytics.v_daily_returns          one row per price record with gap-aware returns
--   analytics.v_analysis_window        first/last common comparison date
--   analytics.v_moving_averages        20 / 50 session SMAs with observation counts
--   analytics.v_volume_analysis        trailing average volume, ratio, unusual flag
--   analytics.v_volume_summary         per-security volume statistics
--   analytics.v_security_performance   period performance, highs/lows, drawdown, ranks
--   analytics.v_volatility             daily and annualised volatility
--   analytics.v_normalised_performance base-100 series per security
--   analytics.v_sector_normalised      equal-weight sector index (base 100)
--   analytics.v_sector_performance     sector returns, volatility, volume
--   analytics.v_corporate_action_impact  price behaviour around dividends/splits
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Trading session numbers: session 1, 2, 3 ... in calendar order. Two records are
-- consecutive sessions exactly when their session numbers differ by 1.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ref.v_trading_sessions AS
SELECT exchange,
       calendar_date,
       is_early_close,
       row_number() OVER (PARTITION BY exchange ORDER BY calendar_date) AS session_no
  FROM ref.trading_calendar
 WHERE is_trading_day;


-- -----------------------------------------------------------------------------
-- DAILY RETURNS
-- Business purpose: the building block of performance, volatility and anomaly checks.
-- Approach: LAG() over each company's records ordered by date gives the previous
--   record; session numbers tell whether it was the previous trading session.
-- Output: one row per validated price record.
-- Assumptions: adjusted close basis; first record of each company has no return.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_daily_returns AS
WITH base AS (
    SELECT p.price_id, p.raw_record_id, p.company_id, c.ticker, c.sector, p.trade_date, s.session_no,
           p.open_price, p.high_price, p.low_price, p.close_price, p.adjusted_close, p.volume,
           LAG(p.trade_date)     OVER w AS prev_trade_date,
           LAG(s.session_no)     OVER w AS prev_session_no,
           LAG(p.close_price)    OVER w AS prev_close_price,
           LAG(p.adjusted_close) OVER w AS prev_adjusted_close
      FROM core.stock_prices p
      JOIN core.companies c        ON c.company_id = p.company_id
      JOIN ref.v_trading_sessions s ON s.exchange = 'XNYS' AND s.calendar_date = p.trade_date
    WINDOW w AS (PARTITION BY p.company_id ORDER BY p.trade_date)
)
SELECT b.*,
       b.session_no - b.prev_session_no AS sessions_elapsed,
       CASE WHEN b.prev_session_no IS NULL                THEN 'FIRST_OBSERVATION'
            WHEN b.session_no - b.prev_session_no = 1     THEN 'ONE_SESSION'
            ELSE 'MULTI_SESSION' END AS return_type,
       -- one-session return on adjusted close (the "daily return")
       CASE WHEN b.session_no - b.prev_session_no = 1
            THEN (b.adjusted_close / nullif(b.prev_adjusted_close, 0) - 1) * 100 END AS daily_return_pct,
       -- same, on reported close (moves on ex-dividend dates by about -dividend/price)
       CASE WHEN b.session_no - b.prev_session_no = 1
            THEN (b.close_price / nullif(b.prev_close_price, 0) - 1) * 100 END AS daily_price_return_pct,
       -- return across a gap: kept, but labelled and never treated as a daily return
       CASE WHEN b.session_no - b.prev_session_no > 1
            THEN (b.adjusted_close / nullif(b.prev_adjusted_close, 0) - 1) * 100 END AS multi_session_return_pct
  FROM base b;

COMMENT ON VIEW analytics.v_daily_returns IS
  'Gap-aware returns per validated price record (adjusted close, percent). daily_return_pct only for consecutive sessions.';


-- -----------------------------------------------------------------------------
-- ANALYSIS WINDOW: first and last dates on which EVERY validated company has a price.
-- Demonstrates GROUP BY + HAVING with a scalar subquery.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_analysis_window AS
WITH common_dates AS (
    SELECT trade_date
      FROM core.stock_prices
     GROUP BY trade_date
    HAVING count(DISTINCT company_id) = (SELECT count(*) FROM core.companies)
)
SELECT min(trade_date) AS base_date,
       max(trade_date) AS end_date,
       count(*)        AS common_dates,
       (SELECT count(*) FROM core.companies) AS companies
  FROM common_dates;


-- -----------------------------------------------------------------------------
-- MOVING AVERAGES (simple, on adjusted close)
-- Window frame ROWS BETWEEN 19 PRECEDING AND CURRENT ROW = the last 20 records.
-- The SMA is NULL until the full number of observations is available.
-- sessions_spanned > observations means the window includes a data gap.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_moving_averages AS
SELECT company_id, ticker, sector, trade_date, adjusted_close,
       count(*)                       OVER w20 AS obs_20,
       session_no - first_value(session_no) OVER w20 + 1 AS sessions_spanned_20,
       CASE WHEN count(*) OVER w20 = 20 THEN avg(adjusted_close) OVER w20 END AS sma_20,
       count(*)                       OVER w50 AS obs_50,
       session_no - first_value(session_no) OVER w50 + 1 AS sessions_spanned_50,
       CASE WHEN count(*) OVER w50 = 50 THEN avg(adjusted_close) OVER w50 END AS sma_50
  FROM analytics.v_daily_returns
WINDOW w20 AS (PARTITION BY company_id ORDER BY trade_date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW),
       w50 AS (PARTITION BY company_id ORDER BY trade_date ROWS BETWEEN 49 PRECEDING AND CURRENT ROW);


-- -----------------------------------------------------------------------------
-- VOLUME ANALYSIS
-- Trailing average of the 20 PREVIOUS records (current day excluded: no look-ahead).
-- "Unusual" uses the same threshold as data quality rule DQ-ANO-002 (read from the
-- rule catalogue), so the dashboard and the quality framework agree by construction.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_volume_analysis AS
WITH v AS (
    SELECT company_id, ticker, sector, trade_date, raw_record_id, volume,
           avg(volume) OVER w AS avg_prev_20_volume,
           count(*)    OVER w AS n_prev_volume
      FROM analytics.v_daily_returns
    WINDOW w AS (PARTITION BY company_id ORDER BY trade_date ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING)
)
SELECT v.*,
       CASE WHEN v.n_prev_volume = 20 THEN v.volume / nullif(v.avg_prev_20_volume, 0) END AS volume_ratio,
       coalesce(v.n_prev_volume = 20 AND v.avg_prev_20_volume > 0
                AND v.volume > audit.rule_threshold('DQ-ANO-002') * v.avg_prev_20_volume, false) AS is_unusual_volume
  FROM v;

CREATE OR REPLACE VIEW analytics.v_volume_summary AS
SELECT v.ticker, v.sector,
       count(*)                                              AS trading_days,
       round(avg(v.volume))                                  AS avg_daily_volume,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY v.volume) AS median_daily_volume,
       max(v.volume)                                         AS max_daily_volume,
       count(*) FILTER (WHERE v.is_unusual_volume)           AS unusual_volume_days
  FROM analytics.v_volume_analysis v
  CROSS JOIN analytics.v_analysis_window w
 WHERE v.trade_date BETWEEN w.base_date AND w.end_date
 GROUP BY v.ticker, v.sector;


-- -----------------------------------------------------------------------------
-- SECURITY PERFORMANCE over the analysis window
--   adjusted_return_pct : adjusted close end / base - 1 (includes the dividend effect
--                         as embedded in the provider's adjustment)
--   price_return_pct    : reported close end / base - 1 (excludes dividends)
--   dividends_per_share : sum of validated dividends with ex-date in (base, end]
--   approx_total_return_pct : price return + dividends / base close. A simple
--                         approximation without reinvestment, NOT a precise total return.
--   max_drawdown_pct    : worst fall from a running peak of adjusted close
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_security_performance AS
WITH w AS (SELECT * FROM analytics.v_analysis_window),
inside AS (
    SELECT d.*,
           max(d.adjusted_close) OVER (PARTITION BY d.company_id ORDER BY d.trade_date
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_peak,
           row_number() OVER (PARTITION BY d.company_id ORDER BY d.close_price DESC, d.trade_date) AS rn_high,
           row_number() OVER (PARTITION BY d.company_id ORDER BY d.close_price ASC,  d.trade_date) AS rn_low
      FROM analytics.v_daily_returns d, w
     WHERE d.trade_date BETWEEN w.base_date AND w.end_date
),
per_company AS (
    SELECT i.company_id, i.ticker, i.sector,
           max(i.adjusted_close) FILTER (WHERE i.trade_date = w.base_date) AS base_adjusted_close,
           max(i.adjusted_close) FILTER (WHERE i.trade_date = w.end_date)  AS end_adjusted_close,
           max(i.close_price)    FILTER (WHERE i.trade_date = w.base_date) AS base_close,
           max(i.close_price)    FILTER (WHERE i.trade_date = w.end_date)  AS end_close,
           max(i.close_price)    FILTER (WHERE i.rn_high = 1)              AS highest_close,
           max(i.trade_date)     FILTER (WHERE i.rn_high = 1)              AS highest_close_date,
           max(i.close_price)    FILTER (WHERE i.rn_low = 1)               AS lowest_close,
           max(i.trade_date)     FILTER (WHERE i.rn_low = 1)               AS lowest_close_date,
           max(i.high_price)                                               AS period_high,
           min(i.low_price)                                                AS period_low,
           min((i.adjusted_close / i.running_peak - 1) * 100)              AS max_drawdown_pct,
           count(*)                                                        AS records
      FROM inside i, w
     GROUP BY i.company_id, i.ticker, i.sector
)
SELECT p.*,
       w.base_date, w.end_date,
       (p.end_adjusted_close / nullif(p.base_adjusted_close, 0) - 1) * 100 AS adjusted_return_pct,
       (p.end_close / nullif(p.base_close, 0) - 1) * 100                   AS price_return_pct,
       coalesce(dv.dividends_per_share, 0)                                 AS dividends_per_share,
       ((p.end_close - p.base_close + coalesce(dv.dividends_per_share, 0)) / nullif(p.base_close, 0)) * 100
                                                                           AS approx_total_return_pct,
       RANK() OVER (ORDER BY p.end_adjusted_close / nullif(p.base_adjusted_close, 0) DESC)  AS rank_overall,
       RANK() OVER (PARTITION BY p.sector
                    ORDER BY p.end_adjusted_close / nullif(p.base_adjusted_close, 0) DESC)  AS rank_in_sector
  FROM per_company p
 CROSS JOIN analytics.v_analysis_window w
  LEFT JOIN (SELECT a.company_id, sum(a.dividend_amount) AS dividends_per_share
               FROM core.corporate_actions a, analytics.v_analysis_window w2
              WHERE a.action_type = 'DIVIDEND' AND a.action_date > w2.base_date AND a.action_date <= w2.end_date
              GROUP BY a.company_id) dv ON dv.company_id = p.company_id;

COMMENT ON VIEW analytics.v_security_performance IS
  'Performance over the common analysis window. adjusted_return_pct is adjusted-price performance, not a precisely calculated total return.';


-- -----------------------------------------------------------------------------
-- VOLATILITY
-- Daily volatility = sample standard deviation (stddev_samp, n-1) of ONE-SESSION
-- adjusted returns inside the window. Annualised = daily x sqrt(252::numeric), assuming ~252
-- sessions per year and independent returns. Requires >= 20 returns, else NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_volatility AS
WITH r AS (
    SELECT d.company_id, d.ticker, d.sector, d.daily_return_pct, d.return_type
      FROM analytics.v_daily_returns d, analytics.v_analysis_window w
     WHERE d.trade_date > w.base_date AND d.trade_date <= w.end_date
)
SELECT company_id, ticker, sector,
       count(daily_return_pct)                                   AS daily_returns_used,
       count(*) FILTER (WHERE return_type = 'MULTI_SESSION')     AS multi_session_returns_excluded,
       avg(daily_return_pct)                                     AS mean_daily_return_pct,
       CASE WHEN count(daily_return_pct) >= 20 THEN stddev_samp(daily_return_pct) END              AS daily_volatility_pct,
       CASE WHEN count(daily_return_pct) >= 20 THEN stddev_samp(daily_return_pct) * sqrt(252::numeric) END  AS annualised_volatility_pct,
       min(daily_return_pct)                                     AS worst_daily_return_pct,
       max(daily_return_pct)                                     AS best_daily_return_pct,
       RANK() OVER (ORDER BY CASE WHEN count(daily_return_pct) >= 20 THEN stddev_samp(daily_return_pct) END DESC NULLS LAST)
                                                                 AS rank_most_volatile
  FROM r
 GROUP BY company_id, ticker, sector;


-- -----------------------------------------------------------------------------
-- NORMALISED PERFORMANCE (base 100 on the first common comparison date)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_normalised_performance AS
SELECT d.company_id, d.ticker, d.sector, d.trade_date, d.adjusted_close,
       100 * d.adjusted_close / nullif(b.adjusted_close, 0) AS normalised_value
  FROM analytics.v_daily_returns d
 CROSS JOIN analytics.v_analysis_window w
  JOIN core.stock_prices b ON b.company_id = d.company_id AND b.trade_date = w.base_date
 WHERE d.trade_date BETWEEN w.base_date AND w.end_date;


-- -----------------------------------------------------------------------------
-- SECTOR INDEX: equal-weight, buy-and-hold average of constituents' normalised values.
-- Only dates where EVERY constituent has a value are included, so the index never
-- silently drops a member. This is an index of the selected companies, NOT an
-- official sector index.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_sector_normalised AS
WITH members AS (SELECT sector, count(*) AS constituents FROM core.companies GROUP BY sector),
daily AS (
    SELECT n.sector, n.trade_date, avg(n.normalised_value) AS index_value, count(*) AS constituents_present
      FROM analytics.v_normalised_performance n
     GROUP BY n.sector, n.trade_date
)
SELECT d.sector, d.trade_date, d.index_value, d.constituents_present, m.constituents,
       (d.index_value / LAG(d.index_value) OVER (PARTITION BY d.sector ORDER BY d.trade_date) - 1) * 100
           AS index_daily_return_pct
  FROM daily d JOIN members m USING (sector)
 WHERE d.constituents_present = m.constituents;


-- -----------------------------------------------------------------------------
-- SECTOR PERFORMANCE
--   equal_weight_return_pct  : average of constituents' adjusted returns (= index end - 100)
--   sector_volatility_pct    : annualised sample sd of the sector index's daily returns
--                              (diversification makes it lower than the constituents' average)
--   avg_constituent_volatility_pct : simple average of constituents' annualised volatility
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_sector_performance AS
WITH perf AS (
    SELECT sector,
           count(*)                         AS constituents,
           avg(adjusted_return_pct)         AS equal_weight_return_pct,
           avg(price_return_pct)            AS equal_weight_price_return_pct,
           max(adjusted_return_pct)         AS best_constituent_return_pct,
           min(adjusted_return_pct)         AS worst_constituent_return_pct,
           (array_agg(ticker ORDER BY adjusted_return_pct DESC))[1] AS best_constituent,
           (array_agg(ticker ORDER BY adjusted_return_pct ASC))[1]  AS worst_constituent
      FROM analytics.v_security_performance
     GROUP BY sector
),
vol AS (
    SELECT sector,
           count(index_daily_return_pct) AS index_returns_used,
           CASE WHEN count(index_daily_return_pct) >= 20
                THEN stddev_samp(index_daily_return_pct) * sqrt(252::numeric) END AS sector_volatility_pct
      FROM analytics.v_sector_normalised
     GROUP BY sector
),
cvol AS (
    SELECT sector, avg(annualised_volatility_pct) AS avg_constituent_volatility_pct
      FROM analytics.v_volatility GROUP BY sector
),
volu AS (
    SELECT sector, avg(avg_daily_volume) AS avg_constituent_daily_volume, sum(avg_daily_volume) AS total_avg_daily_volume
      FROM analytics.v_volume_summary GROUP BY sector
)
SELECT p.*, v.index_returns_used, v.sector_volatility_pct, c.avg_constituent_volatility_pct,
       round(u.avg_constituent_daily_volume) AS avg_constituent_daily_volume,
       round(u.total_avg_daily_volume)       AS total_avg_daily_volume,
       RANK() OVER (ORDER BY p.equal_weight_return_pct DESC) AS rank_return
  FROM perf p
  LEFT JOIN vol  v USING (sector)
  LEFT JOIN cvol c USING (sector)
  LEFT JOIN volu u USING (sector);


-- -----------------------------------------------------------------------------
-- CORPORATE ACTION IMPACT
-- For each validated action: the reported and adjusted one-session return on the
-- ex-date, the dividend as a % of the previous close, and the largest adjusted move
-- within +/-2 sessions. Descriptive only: no causal claims.
-- On an ex-dividend date the reported close typically falls by about the dividend,
-- while the adjusted series removes that effect, so
--   reported_return - adjusted_return ~= -dividend_yield.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_corporate_action_impact AS
SELECT a.action_id, c.ticker, c.sector, a.action_date, a.action_type, a.dividend_amount, a.split_ratio,
       d.prev_trade_date, d.prev_close_price, d.close_price AS ex_date_close,
       d.daily_price_return_pct AS reported_return_pct,
       d.daily_return_pct       AS adjusted_return_pct,
       d.daily_price_return_pct - d.daily_return_pct AS reported_minus_adjusted_pct,
       CASE WHEN a.action_type = 'DIVIDEND'
            THEN a.dividend_amount / nullif(d.prev_close_price, 0) * 100 END AS dividend_yield_on_prev_close_pct,
       (SELECT max(abs(n.daily_return_pct)) FROM analytics.v_daily_returns n
         WHERE n.company_id = a.company_id AND n.session_no BETWEEN d.session_no - 2 AND d.session_no + 2)
                                AS max_abs_adjusted_move_pm2_pct,
       coalesce((SELECT max(abs(n.daily_return_pct)) FROM analytics.v_daily_returns n
                  WHERE n.company_id = a.company_id AND n.session_no BETWEEN d.session_no - 2 AND d.session_no + 2)
                > audit.rule_threshold('DQ-ANO-001'), false) AS significant_move_nearby
  FROM core.corporate_actions a
  JOIN core.companies c ON c.company_id = a.company_id
  LEFT JOIN analytics.v_daily_returns d ON d.company_id = a.company_id AND d.trade_date = a.action_date;
