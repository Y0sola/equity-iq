"""Ingestion & Data Lineage page."""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, HTTPException

from backend.database import fetch_all, fetch_one
from backend.routes.common import Ticker, page

router = APIRouter(prefix="/api", tags=["ingestion & lineage"])


@router.get("/ingestion/batches")
def batches() -> dict:
    return page(fetch_all("SELECT * FROM analytics.v_ingestion_history ORDER BY ingestion_batch_id DESC",
                          max_rows=200))


@router.get("/lineage/flow")
def lineage_flow() -> dict:
    """Record counts at each stage: source -> raw staging -> validation -> validated/quarantine -> analytics."""
    counts = fetch_one(
        """SELECT (SELECT count(*) FROM audit.ingestion_logs WHERE status IN ('SUCCEEDED','PARTIAL')) AS batches_loaded,
                  (SELECT count(*) FROM staging.raw_stock_prices)        AS raw_prices,
                  (SELECT count(*) FROM staging.raw_corporate_actions)   AS raw_corporate_actions,
                  (SELECT count(*) FROM staging.raw_company_reference)   AS raw_company_reference,
                  (SELECT count(*) FROM audit.data_quality_rules WHERE is_active) AS active_rules,
                  (SELECT count(*) FROM audit.rule_failures)             AS rule_failures,
                  (SELECT count(*) FROM audit.data_quality_issues)       AS issues,
                  (SELECT count(*) FROM core.stock_prices)               AS validated_prices,
                  (SELECT count(*) FROM core.corporate_actions)          AS validated_corporate_actions,
                  (SELECT count(*) FROM core.companies)                  AS validated_companies,
                  (SELECT count(*) FROM analytics.v_quarantined_records) AS quarantined_records,
                  (SELECT count(*) FROM pg_views WHERE schemaname = 'analytics') AS analytics_views""")
    stages = [
        {"stage": "Source", "detail": "Yahoo Finance via yfinance; XNYS calendar"},
        {"stage": "Raw staging", "detail": "text columns + raw payload, permissive"},
        {"stage": "SQL validation", "detail": "rule catalogue -> failures and issues"},
        {"stage": "Validated / quarantine", "detail": "core.* promoted; critical failures quarantined"},
        {"stage": "SQL analytics", "detail": "analytics.* views"},
        {"stage": "Dashboard", "detail": "read-only API, allowlisted queries"},
    ]
    return {"stages": stages, "counts": counts}


@router.get("/lineage/{ticker}/{trade_date}")
def price_lineage(ticker: Ticker, trade_date: date) -> dict:
    row = fetch_one("SELECT * FROM analytics.v_price_lineage WHERE ticker = %(t)s AND trade_date = %(d)s",
                    {"t": ticker, "d": trade_date})
    if row is None:
        raise HTTPException(status_code=404, detail=f"No validated price for {ticker} on {trade_date}")
    return row
