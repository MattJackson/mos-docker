#!/bin/bash
# Laptop-side: pull a phase's screenshot capture from classe → laptop.
# Runs from ~/Developer/mos-docker/ on the laptop. Assumes the screenshot
# overlay was loaded (compose.screenshot.yml) and the sidecar has written
# /data/run/phase-${PHASE}-current.png on classe.
#
# Usage:
#   scripts/capture-screenshot.sh <phase>     # 0..4
#
# Output: writes ~/Developer/mos-docker/baselines/phase-${PHASE}-current.png
set -euo pipefail

PHASE="${1:-}"
if [ -z "$PHASE" ]; then
    echo "usage: $0 <phase>  (0..4)" >&2
    exit 2
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_DIR="$REPO_DIR/baselines"
mkdir -p "$BASELINE_DIR"

LAPTOP_PNG="$BASELINE_DIR/phase-${PHASE}-current.png"
HOST_PNG="/home/matthew/mos-docker/run/phase-${PHASE}-current.png"

echo "=== capture-screenshot.sh phase=${PHASE} ==="

if ! ssh docker "test -f ${HOST_PNG}"; then
    echo "ERROR: ${HOST_PNG} does not exist on classe." >&2
    echo "  Ensure compose.screenshot.yml is loaded and BOOT_WAIT_SECS has elapsed." >&2
    echo "  Sidecar: docker logs mos-docker-screenshot-${PHASE}" >&2
    exit 1
fi

scp -q "docker:${HOST_PNG}" "$LAPTOP_PNG"
ls -la "$LAPTOP_PNG"
echo "✓ captured phase ${PHASE} → ${LAPTOP_PNG}"
echo
echo "Next: scripts/compare-regression.sh ${PHASE}"
