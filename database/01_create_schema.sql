-- =============================================================================
-- 01_create_schema.sql
-- Purpose : Create the database schemas (namespaces) that separate each layer of
--           the data pipeline.
-- Phase   : 1 — Database architecture
-- Idempotent: yes (IF NOT EXISTS)
--
-- WHY SCHEMAS?
--   A schema is a folder inside a database. Putting raw data, validated data and
--   audit records in different folders makes the data's "state" obvious from its
--   name: staging.raw_stock_prices is untrusted, core.stock_prices is validated.
--   It also lets us grant a read-only reporting role access to `core` and
--   `analytics` without exposing staging tables.
--
--   ref       – Reference data that defines the project scope (tracked securities,
--               exchange trading calendar).
--   staging   – Permissive landing tables. Everything the source sends is kept,
--               including defects, so SQL rules can detect and report them.
--   core      – Validated production records. Strict constraints act as the final
--               safety net after SQL validation.
--   audit     – Ingestion batches, the data quality rule catalogue and the issues
--               those rules find.
--   analytics – Read-only views for reporting (populated in Phases 3–4).
--
-- Synthetic test fixtures do NOT live in this database. They are loaded into a
-- separate database (equityiq_test) built from these same scripts, so real and
-- synthetic data can never be mixed.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS analytics;

COMMENT ON SCHEMA ref       IS 'Reference data defining project scope: tracked security universe and exchange trading calendar.';
COMMENT ON SCHEMA staging   IS 'Permissive raw landing tables. Source values preserved as text so defects can be detected, not lost.';
COMMENT ON SCHEMA core      IS 'Validated production records with strict keys and check constraints.';
COMMENT ON SCHEMA audit     IS 'Ingestion batch logs, data quality rule catalogue and detected issues.';
COMMENT ON SCHEMA analytics IS 'Read-only analytical and data quality reporting views.';
