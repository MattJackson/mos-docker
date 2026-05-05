#!/bin/bash
# Compare a phase's current capture against its golden screenshot.
# Run from ~/Developer/mos-docker/ on the laptop.
#
# Usage:
#   scripts/compare-regression.sh <phase>     # 0..4
#
# Exit codes:
#   0  match (PASS)
#   1  drift above threshold (FAIL — investigate)
#   2  no gold yet for this phase (bootstrap mode — promote current → gold)
set -euo pipefail

PHASE="${1:-}"
if [ -z "$PHASE" ]; then
    echo "usage: $0 <phase>  (0..4)" >&2
    exit 2
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_DIR="$REPO_DIR/baselines"
CURRENT="$BASELINE_DIR/phase-${PHASE}-current.png"
GOLD="$BASELINE_DIR/phase-${PHASE}-gold.png"
DIFF="$BASELINE_DIR/phase-${PHASE}-diff.png"

# Phase 4's gold is BLACK (apple-gfx-pci with no opcode handlers).
if [ "$PHASE" = "4" ]; then
    GOLD="$BASELINE_DIR/phase-4-gold-black.png"
fi

if [ ! -f "$CURRENT" ]; then
    echo "ERROR: current capture missing: $CURRENT" >&2
    echo "  Run scripts/capture-screenshot.sh ${PHASE} first." >&2
    exit 2
fi

if [ ! -f "$GOLD" ]; then
    echo "BOOTSTRAP: no gold yet for phase ${PHASE}."
    echo "  If the current capture is correct, promote it:"
    echo "    cp ${CURRENT} ${GOLD}"
    echo "    git add ${GOLD}"
    echo "    git commit -m 'phase ${PHASE} gold: <description>'"
    exit 2
fi

# ImageMagick perceptual diff. AE = absolute pixel diff count.
# Threshold: 5% of total pixels (1920x1080 ≈ 100k pixels).
if ! command -v compare >/dev/null 2>&1; then
    echo "ERROR: ImageMagick 'compare' not found. brew install imagemagick" >&2
    exit 2
fi

DIFF_COUNT=$(compare -metric AE "$GOLD" "$CURRENT" "$DIFF" 2>&1 || true)
TOTAL_PIXELS=$((1920 * 1080))
THRESHOLD=$((TOTAL_PIXELS * 5 / 100))

echo "phase ${PHASE}: ${DIFF_COUNT} pixels differ (threshold: ${THRESHOLD})"

if [ "$DIFF_COUNT" -le "$THRESHOLD" ] 2>/dev/null; then
    echo "✓ PASS (within threshold)"
    rm -f "$DIFF"
    exit 0
else
    echo "✗ FAIL — drift above threshold"
    echo "  Visual diff:    $DIFF"
    echo "  Gold:           $GOLD"
    echo "  Current:        $CURRENT"
    exit 1
fi
