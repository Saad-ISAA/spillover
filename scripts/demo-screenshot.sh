#!/bin/sh
# Capture a screenshot of one Spillover screen running against a demo HOME.
#   scripts/demo-screenshot.sh <demo-home> <main:section|popover> <out.png> [light|dark]
# The demo HOME must already contain Spillover state (scripts/seed-demo.swift fills one). The
# app only reads and writes inside that HOME, so the real user setup is never touched.
set -eu
DEMO_HOME=$1
SHOW=$2
OUT=$3
APPEARANCE=${4:-light}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/.build/debug/SpilloverApp"

pkill -f "$APP" 2>/dev/null || true
REAL_CLAUDE=""
[ -x "$DEMO_HOME/bin/claude" ] && REAL_CLAUDE="$DEMO_HOME/bin/claude"
HOME="$DEMO_HOME" SPILLOVER_REAL_CLAUDE="$REAL_CLAUDE" SPILLOVER_DEMO_SHOW="$SHOW" \
    SPILLOVER_DEMO_APPEARANCE="$APPEARANCE" "$APP" >/dev/null 2>&1 &
PID=$!
sleep 6

WID=$(swift -e "
import CoreGraphics
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in list where (w[\"kCGWindowOwnerPID\"] as? Int32) == $PID && (w[\"kCGWindowLayer\"] as? Int) == 0 {
    print(w[\"kCGWindowNumber\"]!); break
}")
if [ -z "$WID" ]; then
    echo "no window found" >&2
    kill "$PID"
    exit 1
fi
screencapture -x -o -l"$WID" "$OUT"
kill "$PID"
echo "$OUT"
