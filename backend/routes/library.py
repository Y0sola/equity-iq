"""SQL Query Library: list, inspect and run ALLOWLISTED read-only queries.

There is deliberately no endpoint that accepts SQL text. A query can only be run by
its id, which must exist in the registry built from queries/*.sql.
"""
from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Path

from backend.database import fetch_one, run_timed
from backend.query_library import executable_sql, registry

router = APIRouter(prefix="/api/library", tags=["sql library"])
QueryId = Annotated[str, Path(pattern=r"^[a-z0-9_]{1,64}$")]
MAX_LIBRARY_ROWS = 500


def _get(query_id: str):
    q = registry().get(query_id)
    if q is None:
        raise HTTPException(status_code=404, detail=f"Unknown query '{query_id}'")
    return q


@router.get("")
def list_queries() -> dict:
    items = [q.summary() for q in registry().values()]
    categories = sorted({q["category"] for q in items})
    return {"count": len(items), "categories": categories, "items": items}


@router.get("/{query_id}")
def query_detail(query_id: QueryId) -> dict:
    q = _get(query_id)
    # Show the definitions of the views the query reads, so the full logic is visible.
    # The view name comes from the vetted registry and is passed as a bound parameter.
    views = []
    for name in q.views_used:
        row = fetch_one("SELECT pg_get_viewdef(to_regclass(%(n)s), true) AS definition", {"n": name})
        if row and row["definition"]:
            views.append({"view": name, "definition": row["definition"].strip()})
    return {**q.detail(), "view_definitions": views}


@router.get("/{query_id}/run")
def run_query(query_id: QueryId) -> dict:
    q = _get(query_id)
    result = run_timed(executable_sql(q), max_rows=MAX_LIBRARY_ROWS)
    return {"query_id": q.query_id, "title": q.title, **result}
