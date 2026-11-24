"""Market analytics: rankings, volatility, sectors."""
from __future__ import annotations

from fastapi import APIRouter

from backend.database import fetch_all
from backend.routes.common import Sector, page

router = APIRouter(prefix="/api", tags=["analytics"])


@router.get("/performance/ranking")
def ranking() -> dict:
    return page(fetch_all("SELECT * FROM analytics.v_security_performance ORDER BY rank_overall"),
                note="adjusted_return_pct is adjusted-price performance, not a precisely calculated total return")


@router.get("/volatility")
def volatility() -> dict:
    return page(fetch_all("SELECT * FROM analytics.v_volatility ORDER BY rank_most_volatile"),
                method="sample sd of one-session adjusted returns; annualised x sqrt(252); NULL if < 20 returns")


@router.get("/sectors")
def sectors() -> dict:
    return page(fetch_all("SELECT * FROM analytics.v_sector_performance ORDER BY rank_return"),
                note="equal-weight of the selected companies; not official sector indices")


@router.get("/sectors/index")
def sector_index(sector: Sector | None = None) -> dict:
    rows = fetch_all(
        """SELECT sector, trade_date, index_value FROM analytics.v_sector_normalised
            WHERE (%(s)s::text IS NULL OR sector = %(s)s) ORDER BY sector, trade_date""",
        {"s": sector}, max_rows=5 * 400)
    series: dict[str, dict] = {}
    for r in rows:
        series.setdefault(r["sector"], {"sector": r["sector"], "points": []})["points"].append(
            {"date": r["trade_date"], "value": r["index_value"]})
    return {"base": 100, "series": list(series.values())}
