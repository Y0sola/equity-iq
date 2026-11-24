"""Step 1 of ingestion: download a source snapshot to local files.

Usage:
    .venv/bin/python -m backend.ingestion.fetch_snapshot [--tickers AAPL MSFT]

What it does
  * Reads the ticker list from ref.security_universe (the database is the single
    source of truth for scope).
  * For each ticker, requests daily history (with dividends/splits) and company
    metadata from Yahoo Finance via yfinance, with explicit adjustment settings.
  * Builds the XNYS trading calendar for the window with exchange_calendars.
  * Saves the provider data UNCHANGED as JSON under data/raw/<snapshot_label>/ and
    writes manifest.json with retrieval timestamps, settings, per-ticker status
    and SHA-256 checksums.

What it deliberately does NOT do
  * No validation, cleaning, gap filling or deduplication — that is SQL's job.
  * No substitution: a ticker that fails or returns no rows is recorded as such
    in the manifest. Data is never invented.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import exchange_calendars as xc
import pandas as pd
import yfinance as yf

from backend.database import get_connection
from backend.ingestion import config

# Surface provider errors as exceptions instead of silently returning empty frames.
yf.config.debug.hide_exceptions = False


def _json_value(v):
    """Convert numpy/pandas scalars to JSON-safe Python values; NaN becomes null (missing)."""
    if v is None:
        return None
    if isinstance(v, (pd.Timestamp, datetime)):
        return v.isoformat()
    if hasattr(v, "item"):  # numpy scalar
        v = v.item()
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    return v


def _write_json(path: Path, payload: dict) -> str:
    """Write deterministic JSON (sorted keys) and return its SHA-256."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(payload, indent=1, sort_keys=True, default=str).encode("utf-8")
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def _dataset_checksum(file_hashes: dict[str, str]) -> str | None:
    """One checksum per dataset: hash of the sorted (file, file-hash) list."""
    if not file_hashes:
        return None
    joined = "\n".join(f"{name}:{h}" for name, h in sorted(file_hashes.items()))
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def _with_retries(label: str, func):
    """Call func(); on failure retry with exponential backoff. Returns (result, error, attempts)."""
    last_error = None
    for attempt in range(1, config.MAX_ATTEMPTS + 1):
        try:
            return func(), None, attempt
        except Exception as exc:  # provider/network errors vary by library version
            last_error = f"{type(exc).__name__}: {exc}"
            wait = config.BACKOFF_BASE_SECONDS * 2 ** (attempt - 1)
            print(f"    {label}: attempt {attempt} failed ({last_error[:120]}); retrying in {wait}s")
            if attempt < config.MAX_ATTEMPTS:
                time.sleep(wait)
    return None, last_error, config.MAX_ATTEMPTS


def load_universe() -> list[str]:
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT ticker FROM ref.security_universe WHERE is_active ORDER BY ticker"
        ).fetchall()
    return [r[0] for r in rows]


def fetch_prices(ticker: str) -> dict:
    """Daily OHLCV + actions for the fixed window. yfinance's `end` is exclusive, so add a day."""
    t = yf.Ticker(ticker)
    df = t.history(
        start=config.SNAPSHOT_START.isoformat(),
        end=(config.SNAPSHOT_END + timedelta(days=1)).isoformat(),
        **config.YF_HISTORY_KWARGS,
    )
    # Build rows column by column. (df.iterrows() would upcast the integer Volume column
    # to float because the row mixes types, changing "65585800" into "65585800.0".)
    columns = {col: [_json_value(v) for v in df[col].tolist()] for col in df.columns}
    rows = []
    for i, ts in enumerate(df.index):
        row = {"Date": ts.isoformat()}  # keep the provider's timestamp incl. timezone
        row.update({col: values[i] for col, values in columns.items()})
        rows.append(row)
    metadata = {k: _json_value(v) for k, v in (t.get_history_metadata() or {}).items()
                if not isinstance(v, (dict, list))}  # drop bulky nested trading-period tables
    return {"ticker": ticker, "columns": list(df.columns), "rows": rows, "history_metadata": metadata}


def fetch_reference(ticker: str) -> dict:
    info = yf.Ticker(ticker).get_info()
    if not info:
        raise ValueError("empty info response")
    return {"ticker": ticker, "info": {k: _json_value(v) if not isinstance(v, (dict, list)) else v
                                       for k, v in info.items()}}


def build_calendar() -> dict:
    """Every calendar day in the window with session / holiday / early-close flags."""
    cal = xc.get_calendar(config.CALENDAR_CODE,
                          start=(config.SNAPSHOT_START - timedelta(days=31)).isoformat(),
                          end=(config.SNAPSHOT_END + timedelta(days=31)).isoformat())
    start, end = config.SNAPSHOT_START.isoformat(), config.SNAPSHOT_END.isoformat()
    names = cal.regular_holidays.holidays(start, end, return_name=True)
    holiday_names = {d.date().isoformat(): n for d, n in names.items()}
    adhoc = {pd.Timestamp(d).date().isoformat() for d in cal.adhoc_holidays}
    sessions = {d.date().isoformat() for d in cal.sessions_in_range(start, end)}
    early = {d.date().isoformat() for d in cal.early_closes}

    days = []
    for d in pd.date_range(start, end, freq="D"):
        iso = d.date().isoformat()
        is_session = iso in sessions
        holiday = None
        if not is_session and d.day_of_week < 5:  # weekday closure
            holiday = holiday_names.get(iso) or ("Ad hoc closure" if iso in adhoc else "Unnamed closure")
        days.append({"date": iso, "is_trading_day": is_session,
                     "is_early_close": is_session and iso in early, "holiday_name": holiday})
    return {"exchange": config.CALENDAR_CODE, "library": f"exchange_calendars {xc.__version__}", "days": days}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tickers", nargs="*", help="subset of the universe (default: all active)")
    args = parser.parse_args()

    universe = load_universe()
    tickers = args.tickers or universe
    unknown = sorted(set(tickers) - set(universe))
    if unknown:
        raise SystemExit(f"Not in ref.security_universe: {unknown}")

    started = datetime.now(timezone.utc)
    label = (f"yahoo_{config.SNAPSHOT_START:%Y%m%d}_{config.SNAPSHOT_END:%Y%m%d}"
             f"_retrieved_{started:%Y%m%dT%H%M%SZ}")
    out = config.RAW_DATA_DIR / label
    print(f"Snapshot {label}: {len(tickers)} tickers, window {config.SNAPSHOT_START}..{config.SNAPSHOT_END}")

    hashes = {"PRICES": {}, "COMPANY_REFERENCE": {}, "TRADING_CALENDAR": {}}
    ticker_status = {}

    for i, ticker in enumerate(tickers, 1):
        print(f"[{i:2}/{len(tickers)}] {ticker}")
        status = {}
        prices, err, attempts = _with_retries(f"{ticker} prices", lambda: fetch_prices(ticker))
        if prices is None:
            status["prices"] = {"status": "FAILED", "error": err, "attempts": attempts}
        elif not prices["rows"]:
            status["prices"] = {"status": "NO_DATA", "attempts": attempts}
        else:
            name = f"prices/{ticker}.json"
            hashes["PRICES"][name] = _write_json(out / name, prices)
            status["prices"] = {"status": "OK", "rows": len(prices["rows"]), "attempts": attempts,
                                "retrieved_at": datetime.now(timezone.utc).isoformat()}

        ref, err, attempts = _with_retries(f"{ticker} reference", lambda: fetch_reference(ticker))
        if ref is None:
            status["reference"] = {"status": "FAILED", "error": err, "attempts": attempts}
        else:
            name = f"reference/{ticker}.json"
            hashes["COMPANY_REFERENCE"][name] = _write_json(out / name, ref)
            status["reference"] = {"status": "OK", "attempts": attempts,
                                   "retrieved_at": datetime.now(timezone.utc).isoformat()}
        ticker_status[ticker] = status
        print(f"    prices={status['prices']['status']}"
              f"{' (' + str(status['prices'].get('rows')) + ' rows)' if 'rows' in status['prices'] else ''}"
              f"  reference={status['reference']['status']}")
        time.sleep(config.PAUSE_BETWEEN_TICKERS_SECONDS)

    hashes["TRADING_CALENDAR"]["calendar/XNYS.json"] = _write_json(out / "calendar/XNYS.json", build_calendar())

    manifest = {
        "snapshot_label": label,
        "source": config.SOURCE_NAME,
        "snapshot_start_date": config.SNAPSHOT_START.isoformat(),
        "snapshot_end_date": config.SNAPSHOT_END.isoformat(),
        "retrieval_started_at": started.isoformat(),
        "retrieval_finished_at": datetime.now(timezone.utc).isoformat(),
        "libraries": {"yfinance": yf.__version__, "pandas": pd.__version__, "exchange_calendars": xc.__version__},
        "request_parameters": {**config.YF_HISTORY_KWARGS,
                               "start": config.SNAPSHOT_START.isoformat(),
                               "end_exclusive": (config.SNAPSHOT_END + timedelta(days=1)).isoformat()},
        "tickers_requested": tickers,
        "ticker_status": ticker_status,
        "datasets": {ds: {"files": h, "checksum": _dataset_checksum(h)} for ds, h in hashes.items()},
    }
    _write_json(out / "manifest.json", manifest)

    ok = sum(1 for s in ticker_status.values() if s["prices"]["status"] == "OK")
    rows = sum(s["prices"].get("rows", 0) for s in ticker_status.values())
    print(f"\nDone: prices OK for {ok}/{len(tickers)} tickers, {rows} price rows. Saved to {out}")


if __name__ == "__main__":
    main()
