#!/bin/bash
# run-all.sh — top-level verify runner. Invokes every verify-*.sh in
# milestone order and reports which milestones are green.
#
# Order matters: each step's prerequisite is the previous step's pass.
# If a step fails, subsequent steps are still attempted (they'll usually
# fail too, but the aggregate report is useful for seeing where the cliff is).
#
# Usage:
#   DOCKER_HOST=user@host VM=user@vm-ip ./tests/run-all.sh
#
# Env:
#   DOCKER_HOST  ssh target for docker host (required for M1+ scripts)
#   VM           ssh target for macOS guest (required for all scripts)
#   SKIP_M1      1 = skip verify-m1.sh (e.g. when M1 already green, iterate faster)
#
# Exit codes:
#   0   — every invoked script exited 0
#   1   — one or more scripts failed; see per-milestone lines

set -u
TESTS_DIR="$(dirname "$0")"
DOCKER_HOST="${DOCKER_HOST:-}"
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
SKIP_M1="${SKIP_M1:-0}"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
BLD=$(printf '\033[1m')
RST=$(printf '\033[0m')

declare -a RESULTS=()

run_one() {
    local label="$1"
    local script="$2"
    shift 2
    echo
    echo "${BLD}${BLU}########## $label — $script ##########${RST}"
    if [ ! -x "$TESTS_DIR/$script" ]; then
        echo "${YEL}SKIP${RST} $script not executable"
        RESULTS+=("SKIP  $label  ($script not executable)")
        return 0
    fi
    if "$TESTS_DIR/$script" "$@"; then
        RESULTS+=("${GRN}PASS${RST}  $label")
        return 0
    else
        local ec=$?
        RESULTS+=("${RED}FAIL${RST}  $label  (exit $ec)")
        return $ec
    fi
}

FAILED=0

# ---- Optional: boot-log capture + analyze ---------------------------------
# Off by default; opt in with CAPTURE_BOOT=1. When enabled, captures a
# fresh boot into tests/capture-boot-logs/<stamp>/ and runs the pattern
# analyzer against it BEFORE the milestone verifies fire. Surfaces
# panic / hang / missing-milestone signals up front so an operator
# doesn't have to read 2000 lines of docker logs by hand.
#
# Exit semantics: capture failures are logged but do NOT short-circuit
# the rest of run-all — the milestone verifies still run. The capture
# is an observability layer, not a gate.
if [ "${CAPTURE_BOOT:-0}" = "1" ]; then
    if [ -z "$DOCKER_HOST" ]; then
        echo "${YEL}SKIP${RST} boot-log capture (DOCKER_HOST not set)"
        RESULTS+=("SKIP  boot-log capture  (DOCKER_HOST not set)")
    else
        run_one "Boot-log capture" "capture-boot-log.sh" || true
        # Find the most-recent capture dir and analyze it.
        LATEST_CAP=$(ls -1dt "$TESTS_DIR/capture-boot-logs/"*/ 2>/dev/null | head -1)
        if [ -n "$LATEST_CAP" ]; then
            echo "${BLD}${BLU}########## Boot-log analyze — analyze-boot-log.sh ##########${RST}"
            if "$TESTS_DIR/analyze-boot-log.sh" "$LATEST_CAP" >/dev/null 2>&1; then
                RESULTS+=("${GRN}PASS${RST}  Boot-log analyze  ($LATEST_CAP)")
            else
                RESULTS+=("${YEL}WARN${RST}  Boot-log analyze  (signals found; see $LATEST_CAP/analysis.json)")
            fi
        fi
    fi
fi

# ---- Baseline: display path intact (verify-modes) --------------------------
# This isn't a milestone per se — it's the ongoing "we didn't break display"
# regression gate. Every run confirms it.
run_one "Baseline display (verify-modes)" "verify-modes.sh" || FAILED=1

# ---- M1: docker build green + apple-gfx-pci in binary ---------------------
if [ "$SKIP_M1" = "1" ]; then
    echo "${YEL}SKIP${RST} M1 (SKIP_M1=1)"
    RESULTS+=("SKIP  M1  (SKIP_M1=1)")
elif [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M1 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M1  (DOCKER_HOST not set)")
else
    run_one "M1 (docker build + apple-gfx-pci)" "verify-m1.sh" || FAILED=1
fi

# ---- M2: AppleParavirtGPU kext attaches + MMIO reaches decoder ------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M2 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M2  (DOCKER_HOST not set)")
else
    run_one "M2 (guest kext attaches)" "verify-m2.sh" || FAILED=1
fi

# ---- M3: metal-no-op round-trip (wraps verify-phase1.sh) ------------------
run_one "M3 (metal-no-op round-trip)" "verify-m3.sh" || FAILED=1

# ---- M4 scaffold: first pixel (Metal clear-color → noVNC) -----------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M4 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M4 scaffold  (DOCKER_HOST not set)")
else
    run_one "M4 scaffold (first pixel)" "verify-m4.sh" || FAILED=1
fi

# ---- M5 scaffold: first shader (triangle) ---------------------------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M5 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M5 scaffold  (DOCKER_HOST not set)")
else
    run_one "M5 scaffold (first shader)" "verify-m5.sh" || FAILED=1
fi

# ---- M6 scaffold: login screen ---------------------------------------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M6 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M6 scaffold  (DOCKER_HOST not set)")
else
    run_one "M6 scaffold (login screen)" "verify-login-screen.sh" || FAILED=1
fi

# ---- M7 scaffold: desktop idle ---------------------------------------------
if [ -z "$DOCKER_HOST" ]; then
    echo "${YEL}SKIP${RST} M7 (DOCKER_HOST not set)"
    RESULTS+=("SKIP  M7 scaffold  (DOCKER_HOST not set)")
else
    run_one "M7 scaffold (desktop idle)" "verify-desktop-idle.sh" || FAILED=1
fi

# ---- Optional: post-boot health report ------------------------------------
# Off by default; opt in with VM_HEALTH_REPORT=1. After the milestone
# verifies run, collect ioreg / dmesg / log-show / docker-logs into a
# tar.gz in tests/vm-health-reports/ for attaching to a bug report.
if [ "${VM_HEALTH_REPORT:-0}" = "1" ]; then
    if [ -n "$VM" ]; then
        HEALTH_OUT_DIR="$TESTS_DIR/vm-health-reports"
        mkdir -p "$HEALTH_OUT_DIR"
        echo
        echo "${BLD}${BLU}########## VM health report — vm-health-report.sh ##########${RST}"
        if "$TESTS_DIR/vm-health-report.sh" "$HEALTH_OUT_DIR"; then
            RESULTS+=("${GRN}PASS${RST}  VM health report  ($HEALTH_OUT_DIR)")
        else
            RESULTS+=("${YEL}WARN${RST}  VM health report  (partial; see $HEALTH_OUT_DIR)")
        fi
    fi
fi

# ---- Aggregate report ------------------------------------------------------
echo
echo "${BLD}########## run-all summary ##########${RST}"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo

if [ "$FAILED" -eq 0 ]; then
    echo "${GRN}ALL GREEN${RST}"
    exit 0
else
    echo "${RED}ONE OR MORE FAILED${RST}"
    exit 1
fi
