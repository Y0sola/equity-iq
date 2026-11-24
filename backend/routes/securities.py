"""Securities page: searchable table and per-security detail."""
from __future__ import annotations

from datetime import date
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query

from backend.database import fetch_all, fetch_one
from backend.routes.common import Limit, Sector, Ticker, check_date_range, page, require_tracked_ticker

router = APIRouter(prefix="/api/securities", tags=["securities"])
QualityStatus = Literal["PASSED", "REVIEW", "DEFECTS", "NOT VALIDATED"]


@router.get("")
def list_securities(
    search: Annotated[str | None, Query(min_length=1, max_length=50)] = None,
    sector: Sector | None = None,
    quality_status: QualityStatus | None = None,
) -> dict:
    # strpos() does a plain substring match, so % and _ in the search text are not wildcards.
    items = fetch_all(
        """SELECT * FROM analytics.v_security_overview
            WHERE (%(search)s::text IS NULL
                   OR strpos(lower(ticker || ' ' || coalesce(company_name, '')), lower(%(search)s)) > 0)
              AND (%(sector)s::text IS NULL OR sector = %(sector)s)
              AND (%(status)s::text IS NULL OR quality_status = %(status)s)
            ORDER BY ticker""",
        {"search": search, "sector": sector, "status": quality_status}, max_rows=100)
    return page(items)


@router.get("/{ticker}")
def security_detail(ticker: Ticker) -> dict:
    require_tracked_ticker(ticker)
    return {
        "overview": fetch_one("SELECT * FROM analytics.v_security_overview WHERE ticker = %(t)s", {"t": ticker}),
        "company": fetch_one(
            """SELECT ticker, company_name, sector, provider_sector, industry, exchange, currency, source,
                      created_at, updated_at, raw_reference_id
                 FROM core.companies WHERE ticker = %(t)s""", {"t": ticker}),
        "performance": fetch_one("SELECT * FROM analytics.v_security_performance WHERE ticker = %(t)s", {"t": ticker}),
        "volatility": fetch_one("SELECT * FROM analytics.v_volatility WHERE ticker = %(t)s", {"t": ticker}),
        "volume": fetch_one("SELECT * FROM analytics.v_volume_summary WHERE ticker = %(t)s", {"t": ticker}),
    }


@router.get("/{ticker}/prices")
def security_prices(ticker: Ticker, date_from: date | None = None, date_to: date | None = None) -> dict:
    require_tracked_ticker(ticker)
    check_date_range(date_from, date_to)
    items = fetch_all(
        """SELECT * FROM analytics.v_price_chart
            WHERE ticker = %(t)s
              AND (%(f)s::date IS NULL OR trade_date >= %(f)s)
              AND (%(to)s::date IS NULL OR trade_date <= %(to)s)
            ORDER BY trade_date""", {"t": ticker, "f": date_from, "to": date_to}, max_rows=1000)
    return page(items, price_basis="sma_20/sma_50 on adjusted close; OHLC as reported (rounded to cents)")


@router.get("/{ticker}/corporate-actions")
def security_actions(ticker: Ticker) -> dict:
    require_tracked_ticker(ticker)
    return page(fetch_all(
        "SELECT * FROM analytics.v_corporate_action_impact WHERE ticker = %(t)s ORDER BY action_date",
        {"t": ticker}, max_rows=500))


@router.get("/{ticker}/issues")
def security_issues(ticker: Ticker, limit: Limit = 200) -> dict:
    require_tracked_ticker(ticker)
    items = fetch_all(
        """SELECT issue_id, trade_date, rule_id, rule_name, issue_class, severity, status, affected_field,
                  observed_value, detected_at
             FROM analytics.v_dq_issues WHERE ticker = %(t)s
            ORDER BY trade_date DESC NULLS LAST, rule_id LIMIT %(limit)s""", {"t": ticker, "limit": limit})
    return page(items, limit)
