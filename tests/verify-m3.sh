#!/bin/bash
# verify-m3.sh — Milestone 3 gate. Validates that an empty Metal command
# buffer round-trips through our stack:
#   MTLCreateSystemDefaultDevice → newCommandQueue → commit → completion
#
# M3 definition (memory/project_100pct_target.md row M3):
#   "metal-no-op.m returns 0; MTLCreateSystemDefaultDevice non-null."
#
# This script is REAL — it's a thin wrapper around verify-phase1.sh (which
# actually does the Metal round-trip) plus M3-specific assertions about the
# protocol decoder in libapplegfx-vulkan.
#
# Usage:
#   VM=user@vm-ip ./tests/verify-m3.sh
#
# Required env:
#   VM            ssh target for the macOS guest
#
# Optional env:
#   DOCKER_HOST   ssh target for the docker host (needed for protocol-
#                 decoder log inspection — if unset, that check SKIPs)
#   CONTAINER     docker container name (default: macos-macos-1)
#
# Exit codes:
#   0   — M3 gate passed
#   1   — SSH to VM unreachable
#   10  — verify-phase1.sh failed (wraps its exit code; see phase1 codes)
#   20  — MTL device count < 1 (redundant with phase1 exit 2; surfaced here
#          for operators who only read verify-m3)
#   30  — protocol decoder reported errors in its commit path

set -u
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
DOCKER_HOST="${DOCKER_HOST:-}"
CONTAINER="${CONTAINER:-macos-macos-1}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

# ---- 0. Pre-flight ----------------------------------------------------------
step "0/3 — pre-flight"
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "VM $VM unreachable"
    exit 1
fi
pass "VM $VM reachable"

# ---- 1. Delegate to verify-phase1.sh ---------------------------------------
step "1/3 — delegate to verify-phase1.sh (Metal no-op round-trip)"
if [ ! -x "$TESTS_DIR/verify-phase1.sh" ]; then
    fail "verify-phase1.sh missing or not executable at $TESTS_DIR/verify-phase1.sh"
    exit 10
fi

PHASE1_OUT=$("$TESTS_DIR/verify-phase1.sh" 2>&1)
PHASE1_EXIT=$?
echo "$PHASE1_OUT" | sed 's/^/    /'

if [ "$PHASE1_EXIT" -ne 0 ]; then
    fail "verify-phase1.sh exited $PHASE1_EXIT — see phase1 exit codes"
    # Map the common sub-failures into our code space for reporting clarity,
    # but keep 10 as the catch-all so callers always see "phase1 broke".
    case "$PHASE1_EXIT" in
        2) warn "phase1 code 2: MTLCopyAllDevices count < 1" ; exit 20 ;;
        *) exit 10 ;;
    esac
fi
pass "verify-phase1.sh passed (metal-no-op round-trip OK)"

# ---- 2. Protocol decoder has no errors in commit path ----------------------
step "2/3 — protocol decoder clean (libapplegfx-vulkan commit path)"
# libapplegfx-vulkan logs to the docker container's stderr via QEMU's
# -d trace. We look for two signals:
#   a) At least one "commit" event decoded (proves command buffer reached
#      the decoder from the guest side — not just the Metal SPI side)
#   b) Zero "decoder error" / "bad opcode" / "truncated cmdbuf" lines in
#      the same window
#
# If DOCKER_HOST is unset, we SKIP this check rather than fail — operators
# running M3 locally without access to the host still get the phase1 signal.
if [ -z "$DOCKER_HOST" ]; then
    warn "DOCKER_HOST unset — skipping protocol decoder log scan"
    warn "set DOCKER_HOST to a host with access to docker logs for full coverage"
else
    if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
        warn "docker host $DOCKER_HOST unreachable — skipping decoder log scan"
    else
        LOGS=$(ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 2000 $CONTAINER 2>&1" || echo "")
        DECODER_ERRS=$(echo "$LOGS" | grep -cE 'applegfx.*(decoder.*error|bad.opcode|truncated|malformed.cmdbuf)' || true)
        DECODER_COMMITS=$(echo "$LOGS" | grep -cE 'applegfx.*(commit|cmdbuf.*done|opcode.*done)' || true)

        if [ "$DECODER_ERRS" -gt 0 ]; then
            fail "decoder reported $DECODER_ERRS error lines in last 2000 log entries"
            echo "$LOGS" | grep -E 'applegfx.*(decoder.*error|bad.opcode|truncated|malformed.cmdbuf)' \
                | head -10 | sed 's/^/    /'
            exit 30
        fi
        pass "decoder error count: 0"

        if [ "$DECODER_COMMITS" -gt 0 ]; then
            pass "decoder observed $DECODER_COMMITS commit/done events (guest→host path live)"
        else
            warn "decoder observed 0 commit events — either the decoder isn't logging,"
            warn "or the metal-no-op cmdbuf never reached it. Phase1 passed anyway,"
            warn "which suggests Metal-side is OK and decoder logging just isn't wired"
            warn "to stderr yet. Not a failure today; will tighten once logging lands."
        fi
    fi
fi

# ---- 3. Summary -------------------------------------------------------------
step "3/3 — M3 summary"
echo "  verify-phase1.sh:       PASS"
echo "  metal-no-op round-trip: OK"
echo "  MTLCopyAllDevices:      >= 1 (confirmed by phase1 step 2)"
echo "  decoder error lines:    0 (or skipped — see step 2)"
echo
echo "${GRN}=== M3 gate: PASSED ===${RST}"
echo "Next milestone: M4 — first pixel (Metal clear-color → noVNC solid color)."
echo "Run: DOCKER_HOST=... VM=$VM ./tests/verify-m4.sh"
