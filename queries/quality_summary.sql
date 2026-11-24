-- title: Data quality summary — dimension scores with definitions
-- category: Reporting
-- objective: Report each quality dimension as numerator / denominator with its definition, for the latest validated price batch.
-- concepts: view over CTEs and UNION ALL, NULLIF for zero denominators, explicit metric definitions
-- expected_output: Seven rows (completeness x2, uniqueness, validity, consistency, timeliness, overall).
-- assumptions: Reviewable anomalies are excluded from scores; dimensions are not averaged into one number because their scopes differ.
SELECT dimension, scope, numerator, denominator, score_pct, definition
  FROM analytics.v_dq_dimension_scores
 LIMIT 10;
