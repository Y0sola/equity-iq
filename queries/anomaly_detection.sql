-- title: Reviewable anomalies — large moves, volume spikes and extreme returns
-- category: Data quality
-- objective: List unusual records that were published but flagged for analyst review, with the evidence that triggered each flag.
-- concepts: JOIN view to view, CASE ordering, string predicates, ORDER BY multiple keys
-- expected_output: One row per anomaly issue: ticker, date, rule, observed evidence, status and severity.
-- assumptions: Anomalies are REVIEWABLE (not confirmed errors) and are never auto-discarded. Thresholds come from the rule catalogue.
SELECT i.ticker, i.trade_date, i.rule_id, i.rule_name, i.observed_value, i.severity, i.status,
       i.detection_count
  FROM analytics.v_dq_issues i
 WHERE i.issue_class = 'REVIEWABLE_ANOMALY'
 ORDER BY CASE i.rule_id WHEN 'DQ-ANO-001' THEN 1 WHEN 'DQ-ANO-003' THEN 2 ELSE 3 END,
          i.trade_date DESC, i.ticker
 LIMIT 100;
