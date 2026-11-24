"""Corporate Actions page."""
from __future__ import annotations

from datetime import date
from typing import Literal

from fastapi import APIRouter

from backend.database import fetch_all
from backend.routes.common import Limit, OptionalTicker, check_date_range, page

router = APIRouter(prefix="/api/corporate-actions", tags=["corporate actions"])


@router.get("")
def corporate_actions(
    ticker: OptionalTicker = None,
    action_type: Literal["DIVIDEND", "STOCK_SPLIT"] | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    limit: Limit = 200,
) -> dict:
    check_date_range(date_from, date_to)
    items = fetch_all(
        """SELECT a.*, c.company_name
             FROM analytics.v_corporate_action_impact a
             JOIN core.companies c USING (ticker)
            WHERE (%(t)s::text IS NULL OR a.ticker = %(t)s)
              AND (%(type)s::text IS NULL OR a.action_type = %(type)s)
              AND (%(f)s::date IS NULL OR a.action_date >= %(f)s)
              AND (%(to)s::date IS NULL OR a.action_date <= %(to)s)
            ORDER BY a.action_date DESC, a.ticker
            LIMIT %(limit)s""",
        {"t": ticker, "type": action_type, "f": date_from, "to": date_to, "limit": limit}, max_rows=500)
    return page(items, limit,
                interpretation=("Ex-date basis. On an ex-dividend date the reported close typically falls by about "
                                "the dividend while the adjusted series removes that effect. Descriptive only."))
