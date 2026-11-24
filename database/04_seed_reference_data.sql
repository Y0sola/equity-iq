-- =============================================================================
-- 04_seed_reference_data.sql
-- Purpose : Seed the tracked security universe defined in the project brief.
-- Phase   : 1 — Database architecture
-- Idempotent: yes (UPSERT via INSERT ... ON CONFLICT)
--
-- This is the ONLY data seeded by hand, because it is the project's scope
-- definition, not market data. Company names, industries, exchanges, currencies,
-- prices and corporate actions are all retrieved from the source in Phase 2.
--
-- UPSERT EXPLAINED
--   INSERT ... ON CONFLICT (ticker) DO UPDATE means: insert the row, but if a row
--   with this ticker already exists, update it instead of failing. Running this
--   file twice therefore leaves exactly 20 rows, never 40.
-- =============================================================================

INSERT INTO ref.security_universe (ticker, assigned_sector, notes)
VALUES
    ('AAPL', 'Information Technology', 'Project scope (brief section 3)'),
    ('MSFT', 'Information Technology', 'Project scope (brief section 3)'),
    ('NVDA', 'Information Technology', 'Project scope (brief section 3)'),
    ('AVGO', 'Information Technology', 'Project scope (brief section 3)'),
    ('JPM',  'Financials',             'Project scope (brief section 3)'),
    ('BAC',  'Financials',             'Project scope (brief section 3)'),
    ('GS',   'Financials',             'Project scope (brief section 3)'),
    ('MS',   'Financials',             'Project scope (brief section 3)'),
    ('JNJ',  'Healthcare',             'Project scope (brief section 3)'),
    ('PFE',  'Healthcare',             'Project scope (brief section 3)'),
    ('UNH',  'Healthcare',             'Project scope (brief section 3)'),
    ('MRK',  'Healthcare',             'Project scope (brief section 3)'),
    ('XOM',  'Energy',                 'Project scope (brief section 3)'),
    ('CVX',  'Energy',                 'Project scope (brief section 3)'),
    ('COP',  'Energy',                 'Project scope (brief section 3)'),
    ('EOG',  'Energy',                 'Project scope (brief section 3)'),
    ('AMZN', 'Consumer Discretionary', 'Project scope (brief section 3)'),
    ('TSLA', 'Consumer Discretionary', 'Project scope (brief section 3)'),
    ('NKE',  'Consumer Discretionary', 'Project scope (brief section 3)'),
    ('MCD',  'Consumer Discretionary', 'Project scope (brief section 3)')
ON CONFLICT (ticker) DO UPDATE
    SET assigned_sector = EXCLUDED.assigned_sector,
        notes           = EXCLUDED.notes;


-- Yahoo Finance sector labels -> project sector names. Only labels relevant to the
-- universe are mapped; an unmapped label is itself reported by rule DQ-CNS-005.
INSERT INTO ref.sector_mapping (source, provider_sector, mapped_sector)
VALUES
    ('yahoo_finance', 'Technology',         'Information Technology'),
    ('yahoo_finance', 'Financial Services', 'Financials'),
    ('yahoo_finance', 'Healthcare',         'Healthcare'),
    ('yahoo_finance', 'Energy',             'Energy'),
    ('yahoo_finance', 'Consumer Cyclical',  'Consumer Discretionary')
ON CONFLICT (source, provider_sector) DO UPDATE
    SET mapped_sector = EXCLUDED.mapped_sector;
