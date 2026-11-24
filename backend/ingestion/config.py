"""Fixed ingestion settings for the EquityIQ historical snapshot.

The snapshot window is deliberately fixed, not "the last 12 months from today",
so results are reproducible and a later run date never makes the data look stale.
"""
from __future__ import annotations

from datetime import date

from backend.database import PROJECT_ROOT

# 12 months ending on the last completed NYSE session before the build date (2026-11-24).
# Verified with exchange_calendars XNYS: 251 trading sessions in this inclusive range.
SNAPSHOT_START = date(2025, 11, 24)
SNAPSHOT_END = date(2026, 11, 23)  # inclusive

SOURCE_NAME = "yahoo_finance"
CALENDAR_CODE = "XNYS"  # NYSE calendar; Nasdaq follows the same US equity holiday schedule

# Price adjustment settings — set explicitly, never left to library defaults
# (yfinance's default auto_adjust=True would overwrite Close with the adjusted price).
YF_HISTORY_KWARGS = {
    "interval": "1d",
    "auto_adjust": False,  # keep reported Close and provider Adj Close as separate fields
    "back_adjust": False,  # do not back-adjust OHLC
    "repair": False,       # do not let the library silently "fix" prices; defects must stay visible
    "actions": True,       # include Dividends and Stock Splits columns
}

RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw"

# Politeness / rate-limit handling for the provider.
PAUSE_BETWEEN_TICKERS_SECONDS = 1.5
MAX_ATTEMPTS = 5
BACKOFF_BASE_SECONDS = 5
