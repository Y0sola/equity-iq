-- =============================================================================
-- 13_security_grants.sql
-- Purpose : Least-privilege grants for the read-only analytical role used by the API.
-- Phase   : 5 — Backend
-- Run     : by scripts/db_init.sh, which passes the role name as psql variable :reader.
--           Runs LAST so it covers every object created by earlier files.
-- Idempotent: yes (GRANT / REVOKE are repeatable)
--
-- LEAST PRIVILEGE
--   The reader can SELECT and nothing else: no INSERT/UPDATE/DELETE/TRUNCATE, no DDL,
--   and no EXECUTE on the functions and procedures that write (validation, promotion,
--   issue workflow). Together with the role defaults set in db_init.sh
--   (default_transaction_read_only = on, statement_timeout = 5s) this is three
--   independent layers: privileges, session defaults, and the API's allowlist.
--
-- Note: views run with their OWNER's table privileges, but functions called inside a
-- view run with the CALLER's EXECUTE privilege, so the few read-only helper functions
-- used by views are granted explicitly below.
-- =============================================================================

\set ON_ERROR_STOP 1

GRANT USAGE ON SCHEMA ref, staging, core, audit, analytics TO :"reader";
GRANT SELECT ON ALL TABLES IN SCHEMA ref, staging, core, audit, analytics TO :"reader";  -- tables and views

-- Remove the default "anyone may execute" grant from pipeline functions and procedures.
REVOKE EXECUTE ON ALL FUNCTIONS  IN SCHEMA audit FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA audit FROM PUBLIC;

-- Read-only helpers referenced by views.
GRANT EXECUTE ON FUNCTION audit.rule_threshold(text)                 TO :"reader";
GRANT EXECUTE ON FUNCTION audit.show_value(text)                     TO :"reader";
GRANT EXECUTE ON FUNCTION audit.make_issue_key(text, text, text, text) TO :"reader";
-- staging.* and core.* helpers are pure (IMMUTABLE) conversion functions; they keep the
-- default PUBLIC execute so the typed staging views work for the reader.
