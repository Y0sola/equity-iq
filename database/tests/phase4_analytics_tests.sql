-- =============================================================================
-- phase4_analytics_tests.sql
-- Purpose : Verify the financial analytics views against independent, hand-checkable
--           calculations and analytical edge cases, using the SYNTHETIC fixtures.
-- Run     : scripts/run_analytics_tests.sh  (test database only)
--
-- The fixtures contain the edge cases analytics must survive: a missing session
-- (JPM 2026-01-13), quarantined records creating gaps, a holiday (MLK 2026-01-19),
-- weekends, a +15% level shift (XOM), a volume spike (JNJ 02-10), a dividend (JNJ
-- 02-23) and a company excluded entirely (MCD, reference data quarantined).
-- Everything runs in one transaction that is rolled back.
-- =============================================================================

\set ON_ERROR_STOP 1
\pset footer off

DO $$ BEGIN
    IF current_database() NOT LIKE '%test%' THEN
        RAISE EXCEPTION 'Refusing to run analytics tests in database "%"', current_database();
    END IF;
END $$;

BEGIN;

CREATE TEMP TABLE results (test_no serial, test_name text, expected text, actual text, passed boolean) ON COMMIT DROP;
CREATE FUNCTION pg_temp.check(p_name text, p_expected text, p_actual text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO results (test_name, expected, actual, passed)
    VALUES (p_name, p_expected, p_actual, p_expected IS NOT DISTINCT FROM p_actual);
$$;
-- Value of a column for one company/date, read straight from core (independent of the views).
CREATE FUNCTION pg_temp.adj(p_ticker text, p_date date) RETURNS numeric LANGUAGE sql AS $$
    SELECT p.adjusted_close FROM core.stock_prices p JOIN core.companies c USING (company_id)
     WHERE c.ticker = p_ticker AND p.trade_date = p_date;
$$;
CREATE FUNCTION pg_temp.close(p_ticker text, p_date date) RETURNS numeric LANGUAGE sql AS $$
    SELECT p.close_price FROM core.stock_prices p JOIN core.companies c USING (company_id)
     WHERE c.ticker = p_ticker AND p.trade_date = p_date;
$$;

\o /dev/null

-- ---------------------------------------------------------------- daily returns
SELECT pg_temp.check('R1 first observation of each company has no return',
    '5 first observations, 0 with a return',
    (SELECT count(*) || ' first observations, ' || count(daily_return_pct) || ' with a return'
       FROM analytics.v_daily_returns WHERE return_type = 'FIRST_OBSERVATION'));

SELECT pg_temp.check('R2 daily return = (adj / previous adj - 1) x 100, AAPL 2026-01-05 (hand formula)',
    round((pg_temp.adj('AAPL', '2026-01-05') / pg_temp.adj('AAPL', '2026-01-02') - 1) * 100, 10)::text,
    (SELECT round(daily_return_pct, 10)::text FROM analytics.v_daily_returns WHERE ticker = 'AAPL' AND trade_date = '2026-01-05'));

SELECT pg_temp.check('R3 weekend is not a gap: AAPL Mon 2026-01-12 follows Fri 01-09 as ONE_SESSION',
    'ONE_SESSION 1 2026-01-09',
    (SELECT return_type || ' ' || sessions_elapsed || ' ' || prev_trade_date FROM analytics.v_daily_returns
      WHERE ticker = 'AAPL' AND trade_date = '2026-01-12'));

SELECT pg_temp.check('R4 holiday is not a gap: AAPL Tue 2026-01-20 follows Fri 01-16 (MLK Mon closed)',
    'ONE_SESSION 1 2026-01-16',
    (SELECT return_type || ' ' || sessions_elapsed || ' ' || prev_trade_date FROM analytics.v_daily_returns
      WHERE ticker = 'AAPL' AND trade_date = '2026-01-20'));

SELECT pg_temp.check('R5 gap: JPM 2026-01-14 vs 01-09 is MULTI_SESSION (3 sessions), no daily return',
    'MULTI_SESSION 3 null',
    (SELECT return_type || ' ' || sessions_elapsed || ' ' || coalesce(daily_return_pct::text, 'null')
       FROM analytics.v_daily_returns WHERE ticker = 'JPM' AND trade_date = '2026-01-14'));

SELECT pg_temp.check('R6 multi-session return kept separately and correct (JPM 01-09 -> 01-14)',
    round((pg_temp.adj('JPM', '2026-01-14') / pg_temp.adj('JPM', '2026-01-09') - 1) * 100, 10)::text,
    (SELECT round(multi_session_return_pct, 10)::text FROM analytics.v_daily_returns
      WHERE ticker = 'JPM' AND trade_date = '2026-01-14'));

-- ---------------------------------------------------------------- moving averages
SELECT pg_temp.check('M1 SMA20 is NULL for the first 19 AAPL records',
    '19 rows, 0 non-null',
    (SELECT count(*) || ' rows, ' || count(sma_20) || ' non-null'
       FROM (SELECT sma_20 FROM analytics.v_moving_averages WHERE ticker = 'AAPL' ORDER BY trade_date LIMIT 19) x));

SELECT pg_temp.check('M2 SMA20 on the 20th AAPL record = plain average of the first 20 adjusted closes',
    (SELECT round(avg(adjusted_close), 10)::text FROM
        (SELECT p.adjusted_close FROM core.stock_prices p JOIN core.companies c USING (company_id)
          WHERE c.ticker = 'AAPL' ORDER BY p.trade_date LIMIT 20) x),
    (SELECT round(sma_20, 10)::text FROM
        (SELECT sma_20, row_number() OVER (ORDER BY trade_date) rn FROM analytics.v_moving_averages WHERE ticker = 'AAPL') y
      WHERE rn = 20));

SELECT pg_temp.check('M3 SMA window over a gap is visible: JPM 2026-01-14 spans more sessions than observations',
    'true',
    (SELECT (sessions_spanned_20 > obs_20)::text FROM analytics.v_moving_averages WHERE ticker = 'JPM' AND trade_date = '2026-01-14'));

SELECT pg_temp.check('M4 SMA50 is NULL until 50 observations (count of non-null = records - 49 for AAPL)',
    (SELECT (count(*) - 49)::text FROM analytics.v_moving_averages WHERE ticker = 'AAPL'),
    (SELECT count(sma_50)::text FROM analytics.v_moving_averages WHERE ticker = 'AAPL'));

-- ---------------------------------------------------------------- volatility
SELECT pg_temp.check('V1 daily volatility = sqrt(sum((x - mean)^2) / (n - 1)) for AAPL (independent formula)',
    (SELECT round(sqrt(sum((x - m) ^ 2) / (count(*) - 1)), 8)::text
       FROM (SELECT d.daily_return_pct AS x, avg(d.daily_return_pct) OVER () AS m
               FROM analytics.v_daily_returns d, analytics.v_analysis_window w
              WHERE d.ticker = 'AAPL' AND d.daily_return_pct IS NOT NULL
                AND d.trade_date > w.base_date AND d.trade_date <= w.end_date) s),
    (SELECT round(daily_volatility_pct, 8)::text FROM analytics.v_volatility WHERE ticker = 'AAPL'));

SELECT pg_temp.check('V2 annualised = daily x sqrt(252)',
    (SELECT round(daily_volatility_pct * sqrt(252::numeric), 8)::text FROM analytics.v_volatility WHERE ticker = 'MSFT'),
    (SELECT round(annualised_volatility_pct, 8)::text FROM analytics.v_volatility WHERE ticker = 'MSFT'));

SELECT pg_temp.check('V3 multi-session returns are excluded from volatility (JPM has gaps)',
    'true',
    (SELECT (multi_session_returns_excluded > 0)::text FROM analytics.v_volatility WHERE ticker = 'JPM'));

-- ---------------------------------------------------------------- performance & normalisation
SELECT pg_temp.check('P1 analysis window = first/last common date of the 5 validated companies',
    '2025-11-24 2026-02-26 5',
    (SELECT base_date || ' ' || end_date || ' ' || companies FROM analytics.v_analysis_window));
    -- end is 02-26, not 02-27: XOM's 02-27 record is missing (fixture F23), so 02-27 is not common.

SELECT pg_temp.check('P2 adjusted return XOM = end / base - 1 (includes the seeded +15% shift)',
    round((pg_temp.adj('XOM', '2026-02-26') / pg_temp.adj('XOM', '2025-11-24') - 1) * 100, 8)::text,
    (SELECT round(adjusted_return_pct, 8)::text FROM analytics.v_security_performance WHERE ticker = 'XOM'));

SELECT pg_temp.check('P3 approx total return JNJ = (end close - base close + dividends) / base close',
    round((pg_temp.close('JNJ', '2026-02-26') - pg_temp.close('JNJ', '2025-11-24') + 1.30) / pg_temp.close('JNJ', '2025-11-24') * 100, 8)::text,
    (SELECT round(approx_total_return_pct, 8)::text FROM analytics.v_security_performance WHERE ticker = 'JNJ'));

SELECT pg_temp.check('P4 company with quarantined reference data (MCD) is absent from analytics',
    '0', (SELECT count(*)::text FROM analytics.v_security_performance WHERE ticker = 'MCD'));

SELECT pg_temp.check('P5 ranks are 1..5 with no gaps', '1,2,3,4,5',
    (SELECT string_agg(rank_overall::text, ',' ORDER BY rank_overall) FROM analytics.v_security_performance));

SELECT pg_temp.check('N1 normalised value = 100 on the base date for every company', '5 at 100',
    (SELECT count(*) || ' at 100' FROM analytics.v_normalised_performance n, analytics.v_analysis_window w
      WHERE n.trade_date = w.base_date AND n.normalised_value = 100));

SELECT pg_temp.check('N2 normalised end value - 100 = adjusted return (XOM)',
    (SELECT round(adjusted_return_pct, 8)::text FROM analytics.v_security_performance WHERE ticker = 'XOM'),
    (SELECT round(normalised_value - 100, 8)::text FROM analytics.v_normalised_performance n, analytics.v_analysis_window w
      WHERE n.ticker = 'XOM' AND n.trade_date = w.end_date));

SELECT pg_temp.check('S1 sector index end value - 100 = equal-weight sector return (Energy: XOM only)',
    (SELECT round(equal_weight_return_pct, 8)::text FROM analytics.v_sector_performance WHERE sector = 'Energy'),
    (SELECT round(index_value - 100, 8)::text FROM analytics.v_sector_normalised s, analytics.v_analysis_window w
      WHERE s.sector = 'Energy' AND s.trade_date = w.end_date));

-- ---------------------------------------------------------------- volume & corporate actions
SELECT pg_temp.check('U1 unusual-volume flags agree with quality rule DQ-ANO-002 issues',
    (SELECT string_agg(ticker || ' ' || trade_date, ', ' ORDER BY ticker, trade_date) FROM audit.data_quality_issues WHERE rule_id = 'DQ-ANO-002'),
    (SELECT string_agg(ticker || ' ' || trade_date, ', ' ORDER BY ticker, trade_date) FROM analytics.v_volume_analysis WHERE is_unusual_volume));

SELECT pg_temp.check('U2 volume ratio JNJ 2026-02-10 = volume / average of previous 20 records',
    (SELECT round(v.volume / (SELECT avg(x.volume) FROM (SELECT p.volume FROM core.stock_prices p JOIN core.companies c USING (company_id)
                                                          WHERE c.ticker = 'JNJ' AND p.trade_date < '2026-02-10'
                                                          ORDER BY p.trade_date DESC LIMIT 20) x), 8)::text
       FROM core.stock_prices v JOIN core.companies c USING (company_id) WHERE c.ticker = 'JNJ' AND v.trade_date = '2026-02-10'),
    (SELECT round(volume_ratio, 8)::text FROM analytics.v_volume_analysis WHERE ticker = 'JNJ' AND trade_date = '2026-02-10'));

SELECT pg_temp.check('C1 dividend yield JNJ 2026-02-23 = 1.30 / previous close x 100',
    round(1.30 / pg_temp.close('JNJ', '2026-02-20') * 100, 8)::text,
    (SELECT round(dividend_yield_on_prev_close_pct, 8)::text FROM analytics.v_corporate_action_impact
      WHERE ticker = 'JNJ' AND action_date = '2026-02-23'));

SELECT pg_temp.check('C2 only validated actions appear (JNJ div, AAPL split, JPM div)', '3',
    (SELECT count(*)::text FROM analytics.v_corporate_action_impact));

-- ---------------------------------------------------------------- minimum sample sizes (temporary data change, rolled back)
SAVEPOINT before_trim;
DELETE FROM core.stock_prices p USING core.companies c
 WHERE c.company_id = p.company_id AND c.ticker = 'JNJ'
   AND p.trade_date > (SELECT min(trade_date) + 20 FROM core.stock_prices WHERE company_id = c.company_id);
-- Capture results in psql variables first: ROLLBACK TO SAVEPOINT would also undo
-- rows written to the results table after the savepoint.
SELECT coalesce((SELECT daily_volatility_pct::text FROM analytics.v_volatility WHERE ticker = 'JNJ'), 'null') AS z1_vol,
       (SELECT daily_returns_used FROM analytics.v_volatility WHERE ticker = 'JNJ')                        AS z1_n,
       (SELECT count(sma_50) FROM analytics.v_moving_averages WHERE ticker = 'JNJ')::text                   AS z2_sma50 \gset
ROLLBACK TO SAVEPOINT before_trim;
SELECT pg_temp.check('Z1 volatility is NULL (N/A) with fewer than 20 daily returns (n=' || :'z1_n' || ')', 'null', :'z1_vol');
SELECT pg_temp.check('Z2 SMA50 never available with fewer than 50 records', '0', :'z2_sma50');

\o
\echo '=== Phase 4 analytics tests (synthetic fixtures) ==='
SELECT test_no AS "#", test_name, left(expected, 40) AS expected, left(actual, 40) AS actual,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
  FROM results ORDER BY test_no;
SELECT count(*) AS total_tests, count(*) FILTER (WHERE passed) AS passed, count(*) FILTER (WHERE NOT passed) AS failed FROM results;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM results WHERE NOT passed) THEN
        RAISE EXCEPTION 'Analytics tests FAILED: % failing', (SELECT count(*) FROM results WHERE NOT passed);
    END IF;
END $$;
ROLLBACK;
