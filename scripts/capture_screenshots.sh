#!/usr/bin/env bash
# Capture README screenshots of the running dashboard with headless Chrome.
#   scripts/capture_screenshots.sh [base_url]     (default http://127.0.0.1:8000)
# Uses a throwaway Chrome profile; pages load their data from the live read-only API.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${1:-http://127.0.0.1:8000}"
OUT="$ROOT_DIR/docs/screenshots"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
mkdir -p "$OUT"

shot() {   # name path height
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" --window-size="1440,$3" --force-device-scale-factor=1 \
    --virtual-time-budget=10000 --screenshot="$OUT/$1.png" "$BASE$2" >/dev/null 2>&1
  echo "captured $1.png  ($BASE$2)"
}

shot overview          "/"                                1180
shot data-quality      "/quality"                         1060
shot issue-detail      "/quality?tab=issues&issue=11"      900
shot sql-library       "/library/daily_returns"           1100
shot security-detail   "/securities/NVDA"                 1240
shot ingestion-lineage "/ingestion"                        900
