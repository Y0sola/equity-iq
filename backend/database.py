"""Database access.

Two kinds of connection:
  * get_connection(): the OWNER role, used only by the ingestion/validation pipeline.
  * the API pool: the READ-ONLY role (equityiq_reader). Every API query goes through
    fetch_all()/fetch_one(), which always run in a read-only transaction and always
    use bound parameters (%(name)s placeholders), never string formatting.

Credentials come from .env; nothing is hard-coded.
"""
from __future__ import annotations

import os
import time
from decimal import Decimal
from pathlib import Path
from typing import Any

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row

PROJECT_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(PROJECT_ROOT / ".env")


def _dbname(test: bool) -> str:
    return os.environ["EQUITYIQ_TEST_DB_NAME" if test else "EQUITYIQ_DB_NAME"]


def get_connection(test: bool = False) -> psycopg.Connection:
    """Owner connection for the pipeline (main database, or test database if test=True)."""
    return psycopg.connect(
        host=os.environ["EQUITYIQ_DB_HOST"],
        port=os.environ["EQUITYIQ_DB_PORT"],
        dbname=_dbname(test),
        user=os.environ["EQUITYIQ_DB_USER"],
        password=os.environ["EQUITYIQ_DB_PASSWORD"],
        application_name="equityiq-pipeline",
    )


# --------------------------------------------------------------------------- API (read-only)

_pool = None  # created lazily so importing this module never opens a connection


def api_database_is_test() -> bool:
    """EQUITYIQ_API_DATABASE=test points the API at the isolated test database (used by API tests)."""
    return os.environ.get("EQUITYIQ_API_DATABASE", "main") == "test"


def get_reader_pool():
    global _pool
    if _pool is None:
        from psycopg_pool import ConnectionPool

        def configure(conn: psycopg.Connection) -> None:
            conn.read_only = True     # every transaction on this connection is READ ONLY
            conn.autocommit = False

        conninfo = psycopg.conninfo.make_conninfo(
            host=os.environ["EQUITYIQ_DB_HOST"],
            port=os.environ["EQUITYIQ_DB_PORT"],
            dbname=_dbname(api_database_is_test()),
            user=os.environ["EQUITYIQ_READER_USER"],
            password=os.environ["EQUITYIQ_READER_PASSWORD"],
            application_name="equityiq-api",
        )
        _pool = ConnectionPool(conninfo, min_size=1, max_size=5, timeout=5, configure=configure, open=True)
    return _pool


def close_reader_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


def _json_ready(row: dict[str, Any]) -> dict[str, Any]:
    """PostgreSQL numeric arrives as Decimal (exact). JSON clients need numbers, and the
    serializer would otherwise emit Decimals as strings, so convert at the API boundary.
    The database keeps the exact values; display precision is ample (values <= 6 dp)."""
    return {k: float(v) if isinstance(v, Decimal) else v for k, v in row.items()}


def fetch_all(sql: str, params: dict[str, Any] | None = None, max_rows: int = 1000) -> list[dict[str, Any]]:
    """Run a predefined read-only query with bound parameters; never return more than max_rows."""
    with get_reader_pool().connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params or {})
        return [_json_ready(r) for r in cur.fetchmany(max_rows)]


def fetch_one(sql: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
    rows = fetch_all(sql, params, max_rows=1)
    return rows[0] if rows else None


def run_timed(sql: str, params: dict[str, Any] | None = None, max_rows: int = 500) -> dict[str, Any]:
    """Run a library query and report columns, rows, truncation and elapsed time."""
    started = time.perf_counter()
    with get_reader_pool().connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params or {})
        rows = cur.fetchmany(max_rows + 1)
        columns = [c.name for c in cur.description] if cur.description else []
    elapsed_ms = (time.perf_counter() - started) * 1000
    return {
        "columns": columns,
        "rows": [_json_ready(r) for r in rows[:max_rows]],
        "row_count": min(len(rows), max_rows),
        "truncated": len(rows) > max_rows,
        "elapsed_ms": round(elapsed_ms, 1),
    }
