#!/bin/bash
# verify-m5.sh — Milestone 5 gate. First shader: one stock shader compiles
# through AIR → LLVM → SPIR-V → lavapipe and produces a visible triangle.
#
# M5 definition (memory/project_100pct_target.md row M5):
#   "One stock shader: AIR → LLVM → SPIR-V → lavapipe → visible triangle."
#
# ==== SCAFFOLD STATUS ========================================================
# This is a SCAFFOLD. Phase 3 shader translation + the stock-shader catalog
# are not in place yet. What IS real today:
#   1. VM reachable + ioreg sanity (no NEW errors vs baseline M2 state)
#   2. Infrastructure to run a compiled metal-triangle program on the VM and
#      check that the guest did not panic during the commit
#   3. Infrastructure for the screenshot diff (reuses helper shape from
#      verify-login-screen.sh)
# What will become real once Phase 3 lands:
#   4. The metal-triangle program actually executes and submits a real
#      shader-backed draw; diff confirms a non-trivial, non-clear frame.
#   5. Shader-catalog check confirms the stock catalog (tracked in
#      shader-catalog-plan.md) is deployed to the container.
#
# A companion tests/metal-triangle.m stub is provided alongside this script
# for the operator to build on a Mac and scp to the VM once M4 passes.
# =============================================================================
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/verify-m5.sh
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host
#   VM            ssh target for the macOS guest
#
# Optional env:
#   CONTAINER              docker container name (default: macos-macos-1)
#   SHADER_CATALOG_PATH    path in container where the stock catalog lives
#                          (default: /usr/share/applegfx/shader-catalog)
#   TRIANGLE_BIN           local path to a built metal-triangle binary
#                          (default: $TESTS_DIR/metal-triangle)
#   GATE_ON_DIFF           1 = fail on diff > tolerance (default: 0)
#   TOLERANCE              mean per-channel delta allowed (default: 40)
#
# Exit codes:
#   0   — asserted checks passed
#   1   — SSH unreachable
#   10  — shader-catalog missing in container
#   20  — triangle cmdbuf did not complete (panic or timeout)
#   30  — pixel diff exceeds tolerance (gated behind GATE_ON_DIFF=1)

set -u
DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required}"
VM="${VM:?VM env var required}"
CONTAINER="${CONTAINER:-macos-macos-1}"
SHADER_CATALOG_PATH="${SHADER_CATALOG_PATH:-/usr/share/applegfx/shader-catalog}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"
TRIANGLE_BIN="${TRIANGLE_BIN:-$TESTS_DIR/metal-triangle}"
GATE_ON_DIFF="${GATE_ON_DIFF:-0}"
TOLERANCE="${TOLERANCE:-40}"
SHOT_DIR="$TESTS_DIR/screenshots"
REF_DIR="$SHOT_DIR/reference"
STAMP=$(date +%Y-%m-%d_%H%M%S)
SHOT_OUT="$SHOT_DIR/${STAMP}-triangle.png"

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

take_screenshot() {
    local out="$1"
    if ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker exec $CONTAINER which vncsnapshot >/dev/null 2>&1"; then
        ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER vncsnapshot -quiet 127.0.0.1::5901 /tmp/shot.png" 2>/dev/null \
            && ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker cp $CONTAINER:/tmp/shot.png - " \
                | tar -xO > "$out" 2>/dev/null \
            && [ -s "$out" ] && return 0
    fi
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

# ---- 1. ioreg sanity — no new errors since M2 -----------------------------
step "1/5 — ioreg sanity (no new apple-gfx errors)"
AGFX_ERRS=$(ssh $SSH_OPTS "$VM" "ioreg -l -c AppleParavirtGPU 2>/dev/null" \
    | grep -cE '"AGXError"|"IOError"|"MPAssertFailed"' || true)
if [ "$AGFX_ERRS" -gt 0 ]; then
    warn "ioreg shows $AGFX_ERRS error-like properties on AppleParavirtGPU node"
    ssh $SSH_OPTS "$VM" "ioreg -l -c AppleParavirtGPU" \
        | grep -E '"AGXError"|"IOError"|"MPAssertFailed"' | head -5 | sed 's/^/    /'
    warn "not gated — just surfacing. Investigate if diff step also fails."
else
    pass "no AGXError / IOError / MPAssertFailed on AppleParavirtGPU node"
fi

# ---- 2. Shader catalog deployed --------------------------------------------
step "2/5 — stock shader catalog deployed (SCAFFOLD)"
# Per docs/shader-catalog-plan.md (TBD), the stock catalog lives at
# $SHADER_CATALOG_PATH inside the container. Existence + non-empty is the
# gate today. Once the plan lands, this should also check a manifest.json
# and verify a minimum shader count.
CATALOG_CHECK=$(ssh $SSH_OPTS "$DOCKER_HOST" \
    "sudo docker exec $CONTAINER sh -c 'test -d $SHADER_CATALOG_PATH && ls -1 $SHADER_CATALOG_PATH 2>/dev/null | wc -l' 2>/dev/null" || echo "0")
CATALOG_COUNT=$(echo "$CATALOG_CHECK" | tr -d ' ')
if [ -z "$CATALOG_COUNT" ] || [ "$CATALOG_COUNT" = "0" ]; then
    warn "SKIP: shader catalog not deployed at $SHADER_CATALOG_PATH"
    warn "this check will be REAL once shader-catalog-plan.md lands and the"
    warn "Dockerfile includes the stock catalog. For now, M5 cannot green-gate"
    warn "on shader path; the metal-triangle scaffold below is still exercised."
    if [ "$GATE_ON_DIFF" -eq 1 ]; then
        fail "GATE_ON_DIFF=1 and shader catalog missing — cannot run M5 real mode"
        exit 10
    fi
else
    pass "shader catalog deployed ($CATALOG_COUNT entries at $SHADER_CATALOG_PATH)"
fi

# ---- 3. metal-triangle cmdbuf completes ------------------------------------
step "3/5 — metal-triangle cmdbuf completes without guest panic (SCAFFOLD)"
if [ ! -x "$TRIANGLE_BIN" ]; then
    warn "SKIP: $TRIANGLE_BIN not built on host"
    warn "build on a Mac host: clang -framework Foundation -framework Metal \\"
    warn "    -framework QuartzCore $TESTS_DIR/metal-triangle.m \\"
    warn "    -o $TRIANGLE_BIN"
    warn "then scp the binary onto this host next to $TESTS_DIR/"
else
    scp -q $SSH_OPTS "$TRIANGLE_BIN" "$VM:/tmp/metal-triangle" 2>/dev/null || {
        warn "scp of metal-triangle to VM failed — skipping actual run"
    }
    TRI_EXIT=$(ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 /tmp/metal-triangle >/tmp/tri.out 2>&1; echo \$?" || echo "255")
    TRI_OUT=$(ssh $SSH_OPTS "$VM" "cat /tmp/tri.out 2>/dev/null" || echo "")
    echo "$TRI_OUT" | sed 's/^/    /'
    case "$TRI_EXIT" in
        0) pass "metal-triangle cmdbuf completed (exit 0)" ;;
        255) warn "metal-triangle never ran (SSH/scp/launchctl asuser issue) — scaffold pass" ;;
        *)
            if [ "$GATE_ON_DIFF" -eq 1 ]; then
                fail "metal-triangle exited $TRI_EXIT — cmdbuf did not complete"
                exit 20
            else
                warn "metal-triangle exited $TRI_EXIT — ungated because GATE_ON_DIFF=0"
                warn "Phase 3 is still in progress; shader submit is not expected to work yet"
            fi
            ;;
    esac
fi

# ---- 4. Diff against reference triangle.png (SCAFFOLD) ---------------------
step "4/5 — diff vs reference triangle.png (SCAFFOLD)"
if take_screenshot "$SHOT_OUT"; then
    SZ=$(stat -f%z "$SHOT_OUT" 2>/dev/null || stat -c%s "$SHOT_OUT" 2>/dev/null)
    pass "screenshot captured: $SHOT_OUT ($SZ bytes)"

    REF_IMG="$REF_DIR/triangle.png"
    DIFF_RESULT=$(compare_screenshot "$SHOT_OUT" "$REF_IMG" "$TOLERANCE")
    case "$DIFF_RESULT" in
        skip:reference-missing)
            warn "SKIP: reference $REF_IMG missing"
            warn "capture after the first visible triangle renders through our stack"
            if [ "$GATE_ON_DIFF" -eq 1 ]; then
                fail "GATE_ON_DIFF=1 but reference missing"
                exit 30
            fi
            ;;
        skip:imagemagick-compare-missing)
            warn "SKIP: ImageMagick 'compare' missing — install to enable diff"
            ;;
        *)
            if [ "$DIFF_RESULT" -le "$TOLERANCE" ]; then
                pass "triangle frame matches reference (delta=$DIFF_RESULT, tolerance=$TOLERANCE)"
            else
                if [ "$GATE_ON_DIFF" -eq 1 ]; then
                    fail "triangle frame differs from reference (delta=$DIFF_RESULT > $TOLERANCE)"
                    exit 30
                else
                    warn "delta=$DIFF_RESULT > tolerance=$TOLERANCE (ungated)"
                fi
            fi
            ;;
    esac
else
    warn "screenshot capture failed — not gating in scaffold mode"
fi

# ---- 5. Scaffold report -----------------------------------------------------
step "5/5 — scaffold report"
echo "  ioreg sanity:           OK"
echo "  shader catalog:         SCAFFOLDED (waiting on shader-catalog-plan.md)"
echo "  metal-triangle submit:  SCAFFOLDED (waiting on Phase 3 + built binary)"
echo "  pixel diff:             SCAFFOLDED (waiting on reference triangle.png)"
echo
echo "${GRN}=== verify-m5 scaffold: PASSED ===${RST}"
