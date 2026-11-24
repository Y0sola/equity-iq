"""Independent cross-check of the SQL analytics views (verification only).

Recomputes key metrics with pandas DIRECTLY from the raw snapshot files in
data/raw/ (bypassing staging, validation and SQL entirely) and compares them with
the analytics views in the main database. Agreement between two independent
implementations is evidence that the SQL is correct.

Usage:  .venv/bin/python scripts/crosscheck_analytics.py

Business logic is NOT implemented here for use anywhere else; SQL remains the
system of record. Differences up to ~1e-4 percentage points are expected because
the database stores adjusted close rounded to 6 decimals while pandas uses the
provider's raw floats.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.database import get_connection  # noqa: E402

TOLERANCE_PCT_POINTS = 1e-3


def load_raw_prices() -> pd.DataFrame:
    snapshot = sorted(p for p in Path("data/raw").glob("yahoo_*") if (p / "manifest.json").exists())[-1]
    frames = []
    for f in sorted((snapshot / "prices").glob("*.json")):
        doc = json.loads(f.read_text())
        df = pd.DataFrame(doc["rows"])
        df["ticker"] = doc["ticker"]
        df["date"] = df["Date"].str[:10]
        frames.append(df[["ticker", "date", "Close", "Adj Close", "Volume"]])
    print(f"Snapshot: {snapshot.name}")
    return pd.concat(frames).sort_values(["ticker", "date"])


def pandas_metrics(prices: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for ticker, g in prices.groupby("ticker"):
        adj = g["Adj Close"].to_numpy()
        rets = pd.Series(adj).pct_change().dropna() * 100           # one-session returns, % (no gaps: 251/251)
        peak = np.maximum.accumulate(adj)
        rows.append({
            "ticker": ticker,
            "adjusted_return_pct": (adj[-1] / adj[0] - 1) * 100,
            "price_return_pct": (round(g["Close"].iloc[-1], 2) / round(g["Close"].iloc[0], 2) - 1) * 100,
            "daily_volatility_pct": rets.std(ddof=1),                # sample sd, n-1
            "annualised_volatility_pct": rets.std(ddof=1) * np.sqrt(252),
            "sma_20_last": adj[-20:].mean(),
            "sma_50_last": adj[-50:].mean(),
            "max_drawdown_pct": ((adj / peak - 1) * 100).min(),
            "avg_daily_volume": g["Volume"].mean(),
        })
    return pd.DataFrame(rows).set_index("ticker")


def sql_metrics() -> pd.DataFrame:
    query = """
        SELECT p.ticker, p.adjusted_return_pct, p.price_return_pct, v.daily_volatility_pct,
               v.annualised_volatility_pct, m.sma_20 AS sma_20_last, m.sma_50 AS sma_50_last,
               p.max_drawdown_pct, s.avg_daily_volume
          FROM analytics.v_security_performance p
          JOIN analytics.v_volatility v USING (ticker)
          JOIN analytics.v_volume_summary s USING (ticker)
          JOIN analytics.v_moving_averages m ON m.ticker = p.ticker AND m.trade_date = p.end_date"""
    with get_connection() as conn:
        cur = conn.execute(query)
        cols = [c.name for c in cur.description]
        df = pd.DataFrame(cur.fetchall(), columns=cols).set_index("ticker")
    return df.astype(float)


def main() -> None:
    expected = pandas_metrics(load_raw_prices())
    actual = sql_metrics()
    print(f"Tickers compared: {len(actual)} (pandas {len(expected)})\n")

    # Relative tolerance for price-level metrics (SMA, volume); absolute (pct points) for % metrics.
    pct_cols = ["adjusted_return_pct", "price_return_pct", "daily_volatility_pct",
                "annualised_volatility_pct", "max_drawdown_pct"]
    level_cols = ["sma_20_last", "sma_50_last", "avg_daily_volume"]

    summary, failures = [], 0
    for col in pct_cols + level_cols:
        diff = (actual[col] - expected.loc[actual.index, col]).abs()
        if col in level_cols:
            diff = diff / expected.loc[actual.index, col].abs() * 100      # relative difference, %
        worst = diff.idxmax()
        ok = diff.max() <= TOLERANCE_PCT_POINTS
        failures += 0 if ok else 1
        summary.append((col, "abs pct-pts" if col in pct_cols else "relative %", diff.max(), worst, "PASS" if ok else "FAIL"))

    print(f"{'metric':<28}{'diff type':<14}{'max diff':>14}  {'worst ticker':<13}result")
    for col, kind, d, worst, res in summary:
        print(f"{col:<28}{kind:<14}{d:>14.2e}  {worst:<13}{res}")

    sample = actual.loc[["AAPL", "NVDA", "COP"], ["adjusted_return_pct", "annualised_volatility_pct"]].round(4)
    sample.columns = ["sql_adj_return", "sql_ann_vol"]
    sample["pandas_adj_return"] = expected.loc[sample.index, "adjusted_return_pct"].round(4)
    sample["pandas_ann_vol"] = expected.loc[sample.index, "annualised_volatility_pct"].round(4)
    print("\nSample:\n" + sample.to_string())
    print(f"\n{len(summary) - failures}/{len(summary)} metrics within tolerance ({TOLERANCE_PCT_POINTS})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
