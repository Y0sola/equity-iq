"""EquityIQ read-only API.

Run:   .venv/bin/uvicorn backend.main:app --reload
Docs:  http://127.0.0.1:8000/docs

Security model (see docs/api.md):
  * connects as the read-only role equityiq_reader (SELECT-only grants, read-only
    sessions, 5 s statement timeout);
  * every endpoint runs predefined SQL with bound parameters; inputs are validated
    and result sizes are capped;
  * no endpoint accepts SQL text; the SQL Library runs allowlisted files only;
  * database errors are returned as generic messages (no SQL or stack traces).
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from psycopg_pool import PoolTimeout

from backend.database import PROJECT_ROOT, api_database_is_test, close_reader_pool, fetch_one
from backend.query_library import registry
from backend.routes import analytics, corporate_actions, ingestion, library, overview, quality, securities

log = logging.getLogger("equityiq.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    registry()                     # validate the query library at start-up (fails fast if a file is unsafe)
    yield
    close_reader_pool()


app = FastAPI(
    title="EquityIQ API",
    version="1.0.0",
    description="Read-only access to validated equity data, data quality results and SQL analytics. "
                "Historical snapshot; not live data; not investment advice.",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("EQUITYIQ_CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173").split(","),
    allow_methods=["GET"],          # read-only API
    allow_headers=["*"],
)


# ------------------------------------------------------------------ error handling
@app.exception_handler(psycopg.errors.QueryCanceled)
async def query_timeout(request: Request, exc: Exception):
    log.warning("query timeout on %s", request.url.path)
    return JSONResponse(status_code=504, content={"error": "query_timeout",
                                                  "detail": "The query exceeded the time limit."})


@app.exception_handler(PoolTimeout)
@app.exception_handler(psycopg.OperationalError)
async def database_unavailable(request: Request, exc: Exception):
    log.error("database unavailable on %s: %s", request.url.path, type(exc).__name__)
    return JSONResponse(status_code=503, content={"error": "database_unavailable",
                                                  "detail": "The database is not reachable. Try again later."})


@app.exception_handler(psycopg.Error)
async def database_error(request: Request, exc: Exception):
    log.exception("database error on %s", request.url.path)
    return JSONResponse(status_code=500, content={"error": "query_failed",
                                                  "detail": "The request could not be completed."})


# ------------------------------------------------------------------ routes
@app.get("/api/health", tags=["system"])
def health() -> dict:
    row = fetch_one("""SELECT current_user AS role, current_database() AS database,
                              current_setting('transaction_read_only') AS read_only,
                              current_setting('statement_timeout') AS statement_timeout""")
    return {"status": "ok", "test_database": api_database_is_test(), **row,
            "library_queries": len(registry())}


for module in (overview, quality, securities, analytics, corporate_actions, ingestion, library):
    app.include_router(module.router)


# ------------------------------------------------------------------ dashboard (built frontend)
# If the React dashboard has been built (cd frontend && npm run build), serve it from the
# same process: one command runs the whole app. Registered AFTER the API routes, GET only,
# and never answers for /api/* paths (unknown API paths still return a JSON 404).
DIST = PROJECT_ROOT / "frontend" / "dist"
if (DIST / "index.html").exists():
    app.mount("/assets", StaticFiles(directory=DIST / "assets"), name="assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    def dashboard(full_path: str) -> FileResponse:
        if full_path.startswith("api/") or full_path == "api":
            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(DIST / "index.html")   # client-side routing handles the page
