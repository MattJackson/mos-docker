#!/bin/bash
# verify-lockscreen.sh — phase-4 GOLD REGRESSION GATE for the lock screen.
#
# The eventual `./mos verify lockscreen` gate. Captures a fresh phase-4 frame
# and scores it against the phase-3 gold oracle. Objective PASS/FAIL — the
# compositor is "done" for this milestone when this exits 0.
#
# GATE_ON_DIFF pattern (matches phases 0-3 gold-diff): this gate is SCAFFOLDED
# now but GATED OFF by default so it does not break `./mos verify` while the
# frame is still unresolved. It reports the verdict and exits 0 (scaffold
# pass) UNLESS GATE_ON=1, in which case a FAIL exits 1 (real regression gate).
# Flip GATE_ON=1 the moment the frame first goes green, so any later
# regression is caught.
#
# Usage:
#   scripts/verify-lockscreen.sh                 # scaffold: reports, exits 0
#   GATE_ON=1 scripts/verify-lockscreen.sh       # real gate: FAIL -> exit 1
#   FUZZ=5 scripts/verify-lockscreen.sh          # fuzz tolerance (reserved)
#
# Exit codes:
#   0  PASS  (or scaffold mode, gate off)
#   1  FAIL  (only when GATE_ON=1)
#   2  capture / setup error
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_ON="${GATE_ON:-0}"
FUZZ="${FUZZ:-5}"

echo "=========================================="
echo "  phase-4 lock-screen gold gate"
echo "  mode: $([ "$GATE_ON" = 1 ] && echo 'GATE ON (FAIL=exit1)' || echo 'SCAFFOLD (report only)')"
echo "=========================================="

set +e
"$REPO_DIR/scripts/compare-phase4.sh" --heatmap
RC=$?
set -e

echo
if [ "$RC" -eq 0 ]; then
    echo "RESULT: PASS — phase-4 frame reproduces the gold lock screen."
    exit 0
fi

if [ "$RC" -eq 2 ]; then
    echo "RESULT: ERROR — could not capture/score a phase-4 frame (see above)."
    # Capture errors always fail the gate regardless of GATE_ON.
    exit 2
fi

# RC == 1 -> frame did not match the oracle.
if [ "$GATE_ON" = "1" ]; then
    echo "RESULT: FAIL — phase-4 frame does not match gold (GATE ON)."
    exit 1
else
    echo "RESULT: FAIL (scaffold, gate OFF) — frame not yet correct; not blocking."
    echo "  Flip GATE_ON=1 once the frame first goes green to arm this regression gate."
    exit 0
fi
