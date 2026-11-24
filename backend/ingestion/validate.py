"""Step 3 of the pipeline: run SQL validation, quarantine and promotion.

Usage:
    .venv/bin/python -m backend.ingestion.validate [--test-db]

All logic lives in SQL (database/06 and 07). This script only calls the
`audit.process_pending_batches()` procedure and prints its progress messages.
Autocommit is required because the procedure commits after each batch.
"""
from __future__ import annotations

import argparse
import time

from backend.database import get_connection


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--test-db", action="store_true", help="run against equityiq_test")
    args = parser.parse_args()

    with get_connection(test=args.test_db) as conn:
        conn.autocommit = True
        conn.add_notice_handler(lambda diag: print(f"  {diag.message_primary}"))
        started = time.perf_counter()
        conn.execute("CALL audit.process_pending_batches()")
        print(f"Validation finished in {time.perf_counter() - started:.2f} s")


if __name__ == "__main__":
    main()
