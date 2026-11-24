-- =============================================================================
-- 00_reset_schemas.sql
-- Purpose : DESTRUCTIVE. Drop every EquityIQ schema and all objects inside it.
-- Only run through `scripts/db_init.sh --reset`, never automatically.
-- Market data can be re-downloaded by the ingestion pipeline, but audit history
-- (ingestion logs, issue workflow notes) in the dropped database is lost.
-- =============================================================================

DROP SCHEMA IF EXISTS qa        CASCADE;   -- test database only (synthetic fixtures)
DROP SCHEMA IF EXISTS analytics CASCADE;
DROP SCHEMA IF EXISTS audit     CASCADE;
DROP SCHEMA IF EXISTS core      CASCADE;
DROP SCHEMA IF EXISTS staging   CASCADE;
DROP SCHEMA IF EXISTS ref       CASCADE;
