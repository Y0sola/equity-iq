"""Shared request validation for the read-only API.

All user input reaches SQL only as bound parameters. Validation here additionally
bounds sizes and rejects malformed values early with HTTP 422/404.
"""
from __future__ import annotations

from datetime import date
from typing import Annotated, Literal

from fastapi import HTTPException, Path, Query

from backend.database import fetch_one

TICKER_REGEX = r"^[A-Z][A-Z.\-]{0,9}$"

Ticker = Annotated[str, Path(pattern=TICKER_REGEX, description="Upper-case ticker, e.g. AAPL")]
OptionalTicker = Annotated[str | None, Query(pattern=TICKER_REGEX)]
Limit = Annotated[int, Query(ge=1, le=500, description="Maximum rows (1-500)")]
Offset = Annotated[int, Query(ge=0, le=100_000)]
Severity = Literal["CRITICAL", "WARNING", "INFO"]
IssueStatus = Literal["OPEN", "UNDER_REVIEW", "RESOLVED", "DISMISSED"]
IssueClass = Literal["CONFIRMED_DEFECT", "REVIEWABLE_ANOMALY"]
Category = Literal["COMPLETENESS", "UNIQUENESS", "VALIDITY", "CONSISTENCY", "TIMELINESS", "ANOMALY"]
Sector = Literal["Information Technology", "Financials", "Healthcare", "Energy", "Consumer Discretionary"]


def check_date_range(date_from: date | None, date_to: date | None) -> None:
    if date_from and date_to and date_from > date_to:
        raise HTTPException(status_code=422, detail="date_from must be on or before date_to")


def require_tracked_ticker(ticker: str) -> None:
    """404 unless the ticker is in the tracked universe."""
    if not fetch_one("SELECT 1 AS ok FROM ref.security_universe WHERE ticker = %(t)s", {"t": ticker}):
        raise HTTPException(status_code=404, detail=f"Ticker {ticker} is not tracked")


def page(items: list, limit: int | None = None, offset: int = 0, **extra) -> dict:
    return {"count": len(items), "limit": limit, "offset": offset, **extra, "items": items}
