"""Overview page: headline figures, performance, sectors and recent issues."""
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Query

from backend.database import fetch_all, fetch_one
from backend.routes.common import TICKER_REGEX, Sector

router = APIRouter(tags=["overview"])


@router.get("/api/overview")
def overview() -> dict:
    kpis = fetch_one("SELECT * FROM analytics.v_overview_kpis")
    if kpis is None:
        raise HTTPException(status_code=404, detail="No validated snapshot available")
    return {
        "kpis": kpis,
        "best_performers": fetch_all(
            """SELECT ticker, sector, adjusted_return_pct, price_return_pct, rank_overall
                 FROM analytics.v_security_performance ORDER BY rank_overall LIMIT 5"""),
        "worst_performers": fetch_all(
            """SELECT ticker, sector, adjusted_return_pct, price_return_pct, rank_overall
                 FROM analytics.v_security_performance ORDER BY rank_overall DESC LIMIT 5"""),
        "sector_performance": fetch_all(
            """SELECT sector, constituents, equal_weight_return_pct, sector_volatility_pct, rank_return
                 FROM analytics.v_sector_performance ORDER BY rank_return"""),
        "recent_issues": fetch_all(
            """SELECT issue_id, ticker, trade_date, rule_id, rule_name, issue_class, severity, status,
                      observed_value, detected_at
                 FROM analytics.v_dq_issues
                ORDER BY detected_at DESC,
                         CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                         trade_date DESC NULLS LAST, issue_id
                LIMIT 8"""),
    }


@router.get("/api/performance/normalised")
def normalised(
    tickers: Annotated[str | None, Query(max_length=220, description="Comma-separated tickers")] = None,
    sector: Sector | None = None,
) -> dict:
    """Base-100 series per security, grouped for charting (max 20 series)."""
    import re
    ticker_list = None
    if tickers:
        ticker_list = [t.strip() for t in tickers.split(",") if t.strip()]
        if len(ticker_list) > 20 or any(not re.match(TICKER_REGEX, t) for t in ticker_list):
            raise HTTPException(status_code=422, detail="tickers must be up to 20 valid upper-case tickers")
    rows = fetch_all(
        """SELECT ticker, sector, trade_date, normalised_value
             FROM analytics.v_normalised_performance
            WHERE (%(tickers)s::text[] IS NULL OR ticker = ANY (%(tickers)s::text[]))
              AND (%(sector)s::text IS NULL OR sector = %(sector)s)
            ORDER BY ticker, trade_date""",
        {"tickers": ticker_list, "sector": sector}, max_rows=20 * 400)
    series: dict[str, dict] = {}
    for r in rows:
        s = series.setdefault(r["ticker"], {"ticker": r["ticker"], "sector": r["sector"], "points": []})
        s["points"].append({"date": r["trade_date"], "value": r["normalised_value"]})
    window = fetch_one("SELECT base_date, end_date FROM analytics.v_analysis_window")
    return {"base": 100, "price_basis": "adjusted close", **(window or {}), "series": list(series.values())}
