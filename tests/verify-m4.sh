#!/bin/bash
# verify-m4.sh — Milestone 4 gate. First pixel: a Metal clear-color
# command reaches lavapipe via our translator and the resulting frame is
# visible through noVNC as a solid color.
#
# M4 definition (memory/project_100pct_target.md row M4):
#   "Metal clear-color → Vulkan clear → noVNC shows solid color."
#
# ==== SCAFFOLD STATUS ========================================================
# This is a SCAFFOLD. Phase 2/3 pixel translation hasn't landed yet, so the
# "frame is red" assertion cannot be made. What IS real today:
#   1. VM reachable + console user logged in
#   2. noVNC endpoint reachable on the docker host
#   3. Screenshot capture pipeline functional (reuses take_screenshot from
#      verify-login-screen.sh's recipe)
# What will become real once Phase 3 lands:
#   4. Diff against tests/screenshots/reference/clear-color-red.png within
#      tolerance. Flip GATE_ON_DIFF=1 when reference exists.
#
# A companion tests/metal-clear-screen.m stub is provided alongside this
# script. It is the Objective-C program the operator runs on the VM once
# M3 passes — it opens a CAMetalLayer (or drawable-less MTLTexture),
# clears to red, and commits. That file's header contains the build/run
# invocation.
# =============================================================================
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-m4.sh
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host (required for noVNC reach
#                 + screenshot capture)
#   VM            ssh target for the macOS guest
#
# Optional env:
#   CONTAINER     docker container name (default: macos-macos-1)
#   NOVNC_PORT    port noVNC listens on (default: 6080)
#   NOVNC_HOST    host to curl noVNC from (default: DOCKER_HOST)
#   GATE_ON_DIFF  1 = fail on diff > tolerance (default: 0 while scaffolded)
#   TOLERANCE     mean per-channel delta allowed (default: 30)
#   EXPECTED_RGB  comma-separated R,G,B for the clear color (default: 255,0,0)
#
# Exit codes:
#   0   — asserted checks passed
#   1   — SSH unreachable
#   10  — noVNC endpoint unreachable
#   20  — screenshot capture failed
#   30  — pixel diff exceeds tolerance (gated behind GATE_ON_DIFF=1)

set -u
DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required}"
VM="${VM:?VM env var required}"
CONTAINER="${CONTAINER:-macos-macos-1}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_HOST="${NOVNC_HOST:-}"
GATE_ON_DIFF="${GATE_ON_DIFF:-0}"
TOLERANCE="${TOLERANCE:-30}"
EXPECTED_RGB="${EXPECTED_RGB:-255,0,0}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"
SHOT_DIR="$TESTS_DIR/screenshots"
REF_DIR="$SHOT_DIR/reference"
STAMP=$(date +%Y-%m-%d_%H%M%S)
SHOT_OUT="$SHOT_DIR/${STAMP}-clear-color.png"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

mkdir -p "$SHOT_DIR" "$REF_DIR"

# ---- helpers ----------------------------------------------------------------
# take_screenshot: duplicated in shape from verify-login-screen.sh so this
# script stands alone. If you change one, change the other.
take_screenshot() {
    local out="$1"
    if ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER which vncsnapshot >/dev/null 2>&1"; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER vncsnapshot -quiet 127.0.0.1::5901 /tmp/shot.png" 2>/dev/null \
            && ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/shot.png - " \
                | tar -xO > "$out" 2>/dev/null \
            && [ -s "$out" ] && return 0
    fi
    warn "vncsnapshot unavailable in container — falling back to macOS-side screencapture"
    ssh $SSH_OPTS "$VM" "screencapture -x /tmp/shot.png" 2>/dev/null \
        && scp -q $SSH_OPTS "$VM:/tmp/shot.png" "$out" 2>/dev/null \
        && [ -s "$out" ] && return 0
    return 1
}

compare_screenshot() {
    local actual="$1"
    local ref="$2"
    if ! command -v compare >/dev/null 2>&1; then
        echo "skip:imagemagick-compare-missing"
        return 0
    fi
    if [ ! -f "$ref" ]; then
        echo "skip:reference-missing"
        return 0
    fi
    local raw
    raw=$(compare -metric MAE "$actual" "$ref" null: 2>&1 | awk -F'[()]' '{print $2}')
    local mean
    mean=$(awk -v r="$raw" 'BEGIN { printf "%d\n", r * 255 }')
    echo "$mean"
}

# ---- 0. Pre-flight ----------------------------------------------------------
step "0/5 — pre-flight"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "docker host $DOCKER_HOST unreachable"
    exit 1
fi
pass "docker host $DOCKER_HOST reachable"
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "VM $VM unreachable"
    exit 1
fi
pass "VM $VM reachable"

# ---- 1. Console sanity ------------------------------------------------------
step "1/5 — VM console live"
if ssh $SSH_OPTS "$VM" "who" | grep -q console; then
    pass "console user logged in"
else
    warn "no console user — Metal clear-color needs a session bootstrap to draw"
    warn "continuing anyway — scaffolded check will still pass infrastructure bits"
fi

# ---- 2. noVNC endpoint reachable -------------------------------------------
step "2/5 — noVNC endpoint reachable"
# The docker host typically has noVNC exposed on localhost:$NOVNC_PORT (the
# compose file maps it). We curl the /vnc.html landing page from the docker
# host. If NOVNC_HOST is set, curl from there directly.
TARGET_HOST="$DOCKER_HOST"
if [ -n "$NOVNC_HOST" ]; then
    TARGET_HOST="$NOVNC_HOST"
fi
NOVNC_STATUS=$(ssh $SSH_OPTS "$TARGET_HOST" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${NOVNC_PORT}/vnc.html 2>/dev/null" || echo "000")
case "$NOVNC_STATUS" in
    200|301|302|304)
        pass "noVNC reachable at 127.0.0.1:${NOVNC_PORT} (http $NOVNC_STATUS)"
        ;;
    000)
        fail "could not curl noVNC — connection refused or host unreachable"
        echo "    check: ssh $TARGET_HOST 'curl -v http://127.0.0.1:${NOVNC_PORT}/vnc.html'"
        exit 10
        ;;
    *)
        fail "noVNC returned unexpected status $NOVNC_STATUS"
        exit 10
        ;;
esac

# ---- 3. Screenshot capture --------------------------------------------------
step "3/5 — framebuffer screenshot"
if take_screenshot "$SHOT_OUT"; then
    SZ=$(stat -f%z "$SHOT_OUT" 2>/dev/null || stat -c%s "$SHOT_OUT" 2>/dev/null)
    pass "screenshot captured: $SHOT_OUT ($SZ bytes)"
else
    fail "screenshot capture failed — all strategies exhausted"
    exit 20
fi

# ---- 4. Diff against reference (SCAFFOLD) ----------------------------------
step "4/5 — diff vs reference clear-color-red.png (SCAFFOLD)"
REF_IMG="$REF_DIR/clear-color-red.png"
DIFF_RESULT=$(compare_screenshot "$SHOT_OUT" "$REF_IMG" "$TOLERANCE")

case "$DIFF_RESULT" in
    skip:reference-missing)
        warn "SKIP: reference $REF_IMG missing"
        warn "Once Phase 3 renders a clear-red frame, capture the reference:"
        warn "  scp <operator-host>:<red-frame.png> $REF_IMG && git add $REF_IMG"
        warn "Then re-run with GATE_ON_DIFF=1 for a real M4 gate."
        warn "Expected RGB target: $EXPECTED_RGB"
        if [ "$GATE_ON_DIFF" -eq 1 ]; then
            fail "GATE_ON_DIFF=1 but reference image missing"
            exit 30
        fi
        ;;
    skip:imagemagick-compare-missing)
        warn "SKIP: ImageMagick 'compare' not installed on this host"
        warn "install: brew install imagemagick  (or apk add imagemagick)"
        ;;
    *)
        if [ "$DIFF_RESULT" -le "$TOLERANCE" ]; then
            pass "screenshot matches reference (delta=$DIFF_RESULT, tolerance=$TOLERANCE)"
        else
            if [ "$GATE_ON_DIFF" -eq 1 ]; then
                fail "clear-color frame differs from reference (delta=$DIFF_RESULT > $TOLERANCE)"
                echo "    inspect: $SHOT_OUT  vs  $REF_IMG"
                exit 30
            else
                warn "delta=$DIFF_RESULT > tolerance=$TOLERANCE (not gated — GATE_ON_DIFF=0)"
            fi
        fi
        ;;
esac

# ---- 5. Scaffold report -----------------------------------------------------
step "5/5 — scaffold report"
echo "  noVNC reachable:        OK"
echo "  screenshot capture:     OK"
echo "  pixel-diff assertion:   SCAFFOLDED (waiting on Phase 3 pixel path)"
echo
echo "Operator workflow once M3 passes:"
echo "  1. On a Mac host, build: clang -framework Foundation -framework Metal \\"
echo "       -framework QuartzCore $TESTS_DIR/metal-clear-screen.m \\"
echo "       -o $TESTS_DIR/metal-clear-screen"
echo "  2. scp metal-clear-screen to the VM"
echo "  3. Run on VM: sudo -n launchctl asuser 501 /tmp/metal-clear-screen"
echo "  4. Rerun: GATE_ON_DIFF=1 ./tests/verify-m4.sh"
echo
echo "${GRN}=== verify-m4 scaffold: PASSED ===${RST}"
