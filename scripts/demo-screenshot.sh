#!/bin/sh
# Capture a screenshot of one Switchboard screen running against a demo HOME.
#   scripts/demo-screenshot.sh <demo-home> <main:section|popover> <out.png>
# The demo HOME must already contain Switchboard state (see docs/development.md). The app only
# reads and writes inside that HOME, so the real user setup is never touched.
set -eu
DEMO_HOME=$1
SHOW=$2
OUT=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/.build/debug/SwitchboardApp"

pkill -f "$APP" 2>/dev/null || true
HOME="$DEMO_HOME" SWITCHBOARD_DEMO_SHOW="$SHOW" "$APP" >/dev/null 2>&1 &
PID=$!
sleep 4

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
