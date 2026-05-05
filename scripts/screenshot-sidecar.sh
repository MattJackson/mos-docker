#!/bin/bash
# Inside-container screenshot sidecar.
# Waits BOOT_WAIT_SECS, captures NOVNC_URL via headless Chromium under
# xvfb, writes OUTPUT_PATH. Used by compose.screenshot.yml.
set -euo pipefail

PHASE="${PHASE:-0}"
NOVNC_URL="${NOVNC_URL:-http://127.0.0.1:6080/vnc.html?autoconnect=1}"
OUTPUT_PATH="${OUTPUT_PATH:-/data/run/phase-${PHASE}-current.png}"
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-75}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

echo "[screenshot] phase=${PHASE} url=${NOVNC_URL} wait=${BOOT_WAIT_SECS}s"
sleep "$BOOT_WAIT_SECS"

XVFB_PID=""
cleanup() {
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
XVFB_PID=$!
sleep 1
export DISPLAY=:99

echo "[screenshot] capturing to ${OUTPUT_PATH}"
chromium-browser \
    --headless \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --window-size=1920,1080 \
    --hide-scrollbars \
    --virtual-time-budget=10000 \
    --screenshot="$OUTPUT_PATH" \
    "$NOVNC_URL"

if [ -f "$OUTPUT_PATH" ]; then
    echo "[screenshot] ✓ wrote $(stat -c%s "$OUTPUT_PATH") bytes to ${OUTPUT_PATH}"
    ls -la "$OUTPUT_PATH"
else
    echo "[screenshot] ✗ chromium produced no output" >&2
    exit 1
fi
