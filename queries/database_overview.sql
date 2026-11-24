-- title: Database overview — tables, rows and constraints
-- category: Database
-- objective: Show how the database is layered (ref, staging, core, audit) and how many rows and integrity constraints each table has.
-- concepts: CTE, UNION ALL, LEFT JOIN, GROUP BY, system catalogs (pg_constraint), CASE
-- expected_output: One row per table with schema, row count and counts of primary/foreign/unique/check constraints.
-- assumptions: Row counts are exact (count(*)), not planner estimates.
WITH row_counts AS (
    SELECT 'ref' AS schema_name, 'security_universe' AS table_name, count(*) AS row_count FROM ref.security_universe
    UNION ALL SELECT 'ref', 'trading_calendar', count(*) FROM ref.trading_calendar
    UNION ALL SELECT 'ref', 'sector_mapping', count(*) FROM ref.sector_mapping
    UNION ALL SELECT 'staging', 'raw_company_reference', count(*) FROM staging.raw_company_reference
    UNION ALL SELECT 'staging', 'raw_stock_prices', count(*) FROM staging.raw_stock_prices
    UNION ALL SELECT 'staging', 'raw_corporate_actions', count(*) FROM staging.raw_corporate_actions
    UNION ALL SELECT 'core', 'companies', count(*) FROM core.companies
    UNION ALL SELECT 'core', 'stock_prices', count(*) FROM core.stock_prices
    UNION ALL SELECT 'core', 'corporate_actions', count(*) FROM core.corporate_actions
    UNION ALL SELECT 'audit', 'ingestion_logs', count(*) FROM audit.ingestion_logs
    UNION ALL SELECT 'audit', 'data_quality_rules', count(*) FROM audit.data_quality_rules
    UNION ALL SELECT 'audit', 'data_quality_issues', count(*) FROM audit.data_quality_issues
    UNION ALL SELECT 'audit', 'rule_failures', count(*) FROM audit.rule_failures
),
constraint_counts AS (
    SELECT n.nspname AS schema_name, t.relname AS table_name,
           count(*) FILTER (WHERE c.contype = 'p') AS primary_keys,
           count(*) FILTER (WHERE c.contype = 'f') AS foreign_keys,
           count(*) FILTER (WHERE c.contype = 'u') AS unique_constraints,
           count(*) FILTER (WHERE c.contype = 'c') AS check_constraints
      FROM pg_constraint c
      JOIN pg_class t     ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname IN ('ref', 'staging', 'core', 'audit')
     GROUP BY n.nspname, t.relname
)
SELECT r.schema_name,
       r.table_name,
       CASE r.schema_name WHEN 'ref' THEN 'Reference / scope' WHEN 'staging' THEN 'Raw (untrusted)'
                          WHEN 'core' THEN 'Validated' ELSE 'Audit / governance' END AS layer,
       r.row_count,
       coalesce(k.primary_keys, 0)       AS primary_keys,
       coalesce(k.foreign_keys, 0)       AS foreign_keys,
       coalesce(k.unique_constraints, 0) AS unique_constraints,
       coalesce(k.check_constraints, 0)  AS check_constraints
  FROM row_counts r
  LEFT JOIN constraint_counts k USING (schema_name, table_name)
 ORDER BY CASE r.schema_name WHEN 'ref' THEN 1 WHEN 'staging' THEN 2 WHEN 'core' THEN 3 ELSE 4 END, r.table_name
 LIMIT 50;
