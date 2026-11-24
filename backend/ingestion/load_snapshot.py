"""Step 2 of ingestion: load a local source snapshot into the staging tables.

Usage:
    .venv/bin/python -m backend.ingestion.load_snapshot [--snapshot LABEL] [--test-db]

For each dataset (TRADING_CALENDAR, COMPANY_REFERENCE, PRICES, CORPORATE_ACTIONS):
  1. If a batch with the same dataset type and source checksum already loaded
     successfully, log a SKIPPED batch and insert nothing (rerun protection; the
     database also enforces this with a partial unique index).
  2. Otherwise create a RUNNING batch in audit.ingestion_logs (committed first, so
     even a crash leaves an audit trail).
  3. Insert all rows in ONE transaction. Values are stored as text exactly as
     received; the full source row is kept in raw_payload (jsonb).
  4. Mark the batch SUCCEEDED, or PARTIAL if some tickers were missing from the
     snapshot, or FAILED (with the error) if the transaction rolled back.

records_accepted / records_rejected / records_flagged stay 0 for staging batches:
they are filled in by the Phase 3 SQL validation and promotion step.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from psycopg.types.json import Jsonb

from backend.database import get_connection
from backend.ingestion import config


def _text(v):
    """Store a provider value as text exactly as received; JSON null stays NULL."""
    return None if v is None else str(v)


def latest_snapshot() -> Path:
    candidates = sorted(p for p in config.RAW_DATA_DIR.glob("yahoo_*") if (p / "manifest.json").exists())
    if not candidates:
        raise SystemExit("No snapshot found in data/raw. Run fetch_snapshot first.")
    return candidates[-1]


def _read(path: Path) -> dict:
    return json.loads(path.read_text())


# --- row builders: one tuple per staging row ---------------------------------

def price_rows(snapshot: Path, files: dict) -> list[tuple]:
    rows = []
    for name in sorted(files):
        doc = _read(snapshot / name)
        currency = doc["history_metadata"].get("currency")
        for n, r in enumerate(doc["rows"], 1):
            rows.append((n, doc["ticker"], r["Date"][:10], _text(r.get("Open")), _text(r.get("High")),
                         _text(r.get("Low")), _text(r.get("Close")), _text(r.get("Adj Close")),
                         _text(r.get("Volume")), _text(currency), config.SOURCE_NAME, Jsonb(r)))
    return rows


def action_rows(snapshot: Path, files: dict) -> list[tuple]:
    """Dividends and splits are columns of the price history; a non-zero value is an event."""
    rows = []
    for name in sorted(files):
        doc = _read(snapshot / name)
        for n, r in enumerate(doc["rows"], 1):
            for column, action_type in (("Dividends", "DIVIDEND"), ("Stock Splits", "STOCK_SPLIT")):
                value = r.get(column)
                if value not in (None, 0, 0.0):
                    payload = {"Date": r["Date"], "source_column": column, "value": value}
                    rows.append((n, doc["ticker"], r["Date"][:10], action_type,
                                 _text(value) if action_type == "DIVIDEND" else None,
                                 _text(value) if action_type == "STOCK_SPLIT" else None,
                                 config.SOURCE_NAME, Jsonb(payload)))
    return rows


def reference_rows(snapshot: Path, files: dict) -> list[tuple]:
    rows = []
    for n, name in enumerate(sorted(files), 1):
        doc = _read(snapshot / name)
        info = doc["info"]
        rows.append((n, doc["ticker"], _text(info.get("longName")), _text(info.get("sector")),
                     _text(info.get("industry")), _text(info.get("exchange")), _text(info.get("currency")),
                     config.SOURCE_NAME, Jsonb(info)))
    return rows


INSERT_SQL = {
    "PRICES": """INSERT INTO staging.raw_stock_prices
        (ingestion_batch_id, source_row_number, ticker, trade_date, open_price, high_price, low_price,
         close_price, adjusted_close, volume, currency, source, raw_payload)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
    "CORPORATE_ACTIONS": """INSERT INTO staging.raw_corporate_actions
        (ingestion_batch_id, source_row_number, ticker, action_date, action_type, dividend_amount,
         split_ratio, source, raw_payload)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
    "COMPANY_REFERENCE": """INSERT INTO staging.raw_company_reference
        (ingestion_batch_id, source_row_number, ticker, company_name, sector, industry, exchange,
         currency, source, raw_payload)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
}


def load_calendar(cur, snapshot: Path, files: dict) -> tuple[int, int, str | None]:
    """Calendar is reference data: upsert straight into ref.trading_calendar.
    Existing days are never silently overwritten: identical days are left alone,
    and days whose values differ are counted and reported."""
    doc = _read(snapshot / next(iter(files)))
    days = doc["days"]
    cur.execute("CREATE TEMP TABLE tmp_calendar (LIKE ref.trading_calendar INCLUDING DEFAULTS) ON COMMIT DROP")
    cur.executemany(
        """INSERT INTO tmp_calendar (exchange, calendar_date, is_trading_day, is_early_close, holiday_name, source)
           VALUES (%s, %s, %s, %s, %s, %s)""",
        [(doc["exchange"], d["date"], d["is_trading_day"], d["is_early_close"], d["holiday_name"], doc["library"])
         for d in days])
    cur.execute("""
        SELECT count(*) FROM tmp_calendar t JOIN ref.trading_calendar c USING (exchange, calendar_date)
         WHERE (t.is_trading_day, t.is_early_close, t.holiday_name)
               IS DISTINCT FROM (c.is_trading_day, c.is_early_close, c.holiday_name)""")
    conflicts = cur.fetchone()[0]
    cur.execute("""INSERT INTO ref.trading_calendar (exchange, calendar_date, is_trading_day, is_early_close, holiday_name, source)
                   SELECT exchange, calendar_date, is_trading_day, is_early_close, holiday_name, source FROM tmp_calendar
                   ON CONFLICT (exchange, calendar_date) DO NOTHING""")
    inserted = cur.rowcount
    msg = f"{conflicts} existing calendar day(s) differ from this snapshot and were NOT overwritten" if conflicts else None
    return len(days), inserted, msg


def run_dataset(conn, dataset: str, snapshot: Path, manifest: dict, files: dict, checksum: str | None) -> None:
    common = dict(batch_type=dataset, source=manifest["source"],
                  params=Jsonb({k: manifest[k] for k in ("request_parameters", "libraries",
                                "retrieval_started_at", "retrieval_finished_at", "tickers_requested")}),
                  start=manifest["snapshot_start_date"], end=manifest["snapshot_end_date"],
                  label=manifest["snapshot_label"], checksum=checksum)

    if checksum is None:
        print(f"  {dataset:<18} no files in snapshot — nothing to load")
        return

    already = conn.execute(
        """SELECT ingestion_batch_id FROM audit.ingestion_logs
            WHERE batch_type = %s AND source_checksum = %s AND status IN ('SUCCEEDED', 'PARTIAL')""",
        (dataset, checksum)).fetchone()
    if already:
        conn.execute(
            """INSERT INTO audit.ingestion_logs (batch_type, source, retrieval_parameters, snapshot_start_date,
                   snapshot_end_date, snapshot_label, source_checksum, status, end_timestamp, error_message)
               VALUES (%(batch_type)s, %(source)s, %(params)s, %(start)s, %(end)s, %(label)s, %(checksum)s,
                       'SKIPPED', now(), %(msg)s)""",
            {**common, "msg": f"Identical snapshot already loaded in batch {already[0]}"})
        conn.commit()
        print(f"  {dataset:<18} SKIPPED (identical snapshot already loaded in batch {already[0]})")
        return

    batch_id = conn.execute(
        """INSERT INTO audit.ingestion_logs (batch_type, source, retrieval_parameters, snapshot_start_date,
               snapshot_end_date, snapshot_label, source_checksum)
           VALUES (%(batch_type)s, %(source)s, %(params)s, %(start)s, %(end)s, %(label)s, %(checksum)s)
           RETURNING ingestion_batch_id""", common).fetchone()[0]
    conn.commit()  # the RUNNING batch is visible even if the load below fails

    try:
        with conn.transaction():
            cur = conn.cursor()
            note = None
            accepted = 0
            if dataset == "TRADING_CALENDAR":
                received, accepted, note = load_calendar(cur, snapshot, files)
            else:
                builder = {"PRICES": price_rows, "CORPORATE_ACTIONS": action_rows,
                           "COMPANY_REFERENCE": reference_rows}[dataset]
                rows = builder(snapshot, files)
                # Every placeholder is a bound parameter; the batch id is prepended to each row.
                cur.executemany(INSERT_SQL[dataset], [(batch_id, *r) for r in rows])
                received = len(rows)

            key = "reference" if dataset == "COMPANY_REFERENCE" else "prices"
            missing = sorted(t for t, s in manifest["ticker_status"].items() if s[key]["status"] != "OK")
            if dataset != "TRADING_CALENDAR" and missing:
                note = f"Tickers missing from snapshot ({key}): {', '.join(missing)}"
            status = "PARTIAL" if note else "SUCCEEDED"
            cur.execute(
                """UPDATE audit.ingestion_logs
                      SET records_received = %s, records_accepted = %s, status = %s,
                          error_message = %s, end_timestamp = clock_timestamp()
                    WHERE ingestion_batch_id = %s""",
                (received, accepted, status, note, batch_id))
        print(f"  {dataset:<18} batch {batch_id}: {status}, {received} records received"
              + (f" — {note}" if note else ""))
    except Exception as exc:
        conn.rollback()
        conn.execute(
            """UPDATE audit.ingestion_logs SET status = 'FAILED', end_timestamp = clock_timestamp(),
                   error_message = %s WHERE ingestion_batch_id = %s""",
            (f"{type(exc).__name__}: {exc}"[:2000], batch_id))
        conn.commit()
        print(f"  {dataset:<18} batch {batch_id}: FAILED — {exc}")
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--snapshot", help="snapshot folder name under data/raw (default: latest)")
    parser.add_argument("--test-db", action="store_true", help="load into equityiq_test instead of equityiq")
    args = parser.parse_args()

    snapshot = config.RAW_DATA_DIR / args.snapshot if args.snapshot else latest_snapshot()
    manifest = _read(snapshot / "manifest.json")
    datasets = manifest["datasets"]
    # Corporate actions are extracted from the price files, so they share the price checksum.
    datasets["CORPORATE_ACTIONS"] = datasets["PRICES"]

    with get_connection(test=args.test_db) as conn:
        print(f"Loading snapshot {snapshot.name} into database '{conn.info.dbname}'")
        for ds in ("TRADING_CALENDAR", "COMPANY_REFERENCE", "PRICES", "CORPORATE_ACTIONS"):
            run_dataset(conn, ds, snapshot, manifest, datasets[ds]["files"], datasets[ds]["checksum"])


if __name__ == "__main__":
    main()
