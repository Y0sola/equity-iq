-- title: Validity and consistency rule results
-- category: Data quality
-- objective: Show, for every validity and consistency rule, how many records failed and how many issues are still unresolved.
-- concepts: SELECT from a view, WHERE ... IN, ORDER BY with CASE, records vs issues distinction
-- expected_output: One row per rule with severity, handling, failing records, total and unresolved issues.
-- assumptions: failing_records counts distinct raw records; issues counts distinct problems (they can differ).
SELECT rule_id, rule_name, rule_category, severity, issue_class, handling,
       failing_records, issues_total, issues_unresolved, expected_condition
  FROM analytics.v_dq_rule_results
 WHERE rule_category IN ('VALIDITY', 'CONSISTENCY')
 ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END, rule_id
 LIMIT 50;
