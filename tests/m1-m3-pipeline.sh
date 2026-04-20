#!/bin/bash
# m1-m3-pipeline.sh — single-entry orchestrator for post-build M1→M2→M3
# verification. Kicks the container, waits for health, waits for SSH,
# runs verify-m1 / verify-modes / (optional) verify-phase1, then bundles
# a vm-health tarball. One command, one final answer.
#
# This script assumes `docker compose build` has ALREADY succeeded on
# DOCKER_HOST (typically portainer-1). That's the prerequisite gate;
# we do not rebuild here — build is the slow step and is owned by the
# CI workflow / the operator.
#
# The pipeline is deliberately additive to the existing verify-*.sh
# ladder: it does not replace verify-m1.sh or run-all.sh, it sequences
# them in the specific order operators need after a fresh green build.
#
# Usage:
#   DOCKER_HOST=user@docker-host VM_HOST=user@vm-ip \
#       ./tests/m1-m3-pipeline.sh
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host
#   VM_HOST       ssh target for the macOS guest. Aliased to VM for the
#                 wrapped verify-*.sh scripts (they read $VM).
#
# Optional env:
#   CONTAINER         docker container name (default: macos-macos-1)
#   REPO_DIR          path to docker-compose.yml on host (default: ~/mos/docker-macos)
#   CONTAINER_WAIT    seconds to wait for container state=running (default: 60)
#   SSH_WAIT          seconds to wait for guest SSH reachability (default: 300)
#   SKIP_M3           1 = skip verify-phase1.sh even if the binary is present
#                     (for operators who know apple-gfx-pci path is not yet live)
#   HEALTH_OUT_DIR    where vm-health-report.sh drops its tarball
#                     (default: tests/vm-health-reports)
#
# Exit codes (documented):
#   0   — every invoked gate passed (M1 green; M2+M3 green if attempted)
#   1   — container failed to reach running state within CONTAINER_WAIT
#   2   — VM SSH unreachable within SSH_WAIT
#   3   — verify-m1.sh failed (M1 gate)
#   4   — verify-phase1.sh failed (M3 gate)
#   5   — verify-modes.sh regressed (display baseline) but M1 itself passed
#   6   — pre-flight: DOCKER_HOST unreachable
#   7   — pre-flight: `docker compose up -d` failed to even start
#
# Partial-success semantics:
#   - M1 pass + verify-modes pass + M3 fail  → exit 4 (M3 gate)
#   - M1 pass + verify-modes fail            → exit 5 (baseline regressed)
#   - M1 fail                                → exit 3 (stop — no point trying M3)
#   vm-health-report.sh runs at the end REGARDLESS of pass/fail, so
#   every invocation leaves an artefact tarball behind.

set -u

DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required, e.g. DOCKER_HOST=user@docker-host}"
VM_HOST="${VM_HOST:?VM_HOST env var required, e.g. VM_HOST=user@10.0.0.1}"
CONTAINER="${CONTAINER:-macos-macos-1}"
REPO_DIR="${REPO_DIR:-~/mos/docker-macos}"
CONTAINER_WAIT="${CONTAINER_WAIT:-60}"
SSH_WAIT="${SSH_WAIT:-300}"
SKIP_M3="${SKIP_M3:-0}"

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTH_OUT_DIR="${HEALTH_OUT_DIR:-$TESTS_DIR/vm-health-reports}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"

# verify-*.sh read $VM, not $VM_HOST — mirror it so sub-scripts Just Work.
export VM="$VM_HOST"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
BLD=$(printf '\033[1m')
RST=$(printf '\033[0m')

pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLD}${BLU}=== $1 ===${RST}"; }

# Track per-step outcomes so the final summary lists everything, even
# on early exit via die().
declare -a RESULTS=()
record() { RESULTS+=("$1"); }

# die EXIT_CODE MESSAGE — write the failure into RESULTS, run the
# health-report step, then exit EXIT_CODE. We always capture health
# on exit because the artefact is the most valuable thing a failed run
# produces.
die() {
    local ec="$1"
    local msg="$2"
    fail "$msg"
    record "${RED}FAIL${RST}  $msg  (exit $ec)"
    run_health_report_best_effort
    print_summary
    exit "$ec"
}

# run_health_report_best_effort — never let this fail the pipeline.
# Emits a WARN if vm-health-report.sh is missing or returns non-zero.
run_health_report_best_effort() {
    echo
    echo "${BLD}${BLU}=== Step 7 — vm-health-report.sh (artefact bundle) ===${RST}"
    if [ ! -x "$TESTS_DIR/vm-health-report.sh" ]; then
        warn "vm-health-report.sh missing or not executable — skipping artefact bundle"
        record "${YEL}SKIP${RST}  vm-health-report  (script missing)"
        return 0
    fi
    mkdir -p "$HEALTH_OUT_DIR"
    if DOCKER_HOST="$DOCKER_HOST" VM="$VM_HOST" \
            "$TESTS_DIR/vm-health-report.sh" "$HEALTH_OUT_DIR"; then
        pass "vm-health-report bundled to $HEALTH_OUT_DIR"
        record "${GRN}PASS${RST}  vm-health-report"
    else
        warn "vm-health-report.sh returned non-zero — partial bundle expected"
        record "${YEL}WARN${RST}  vm-health-report  (partial)"
    fi
}

print_summary() {
    echo
    echo "${BLD}=== m1-m3 pipeline summary ===${RST}"
    for r in "${RESULTS[@]}"; do
        echo "  $r"
    done
    echo
}

# ---- 0. Pre-flight ---------------------------------------------------------
step "Step 0 — pre-flight (SSH to docker host)"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    die 6 "cannot reach docker host $DOCKER_HOST via SSH"
fi
pass "docker host $DOCKER_HOST reachable"
record "${GRN}PASS${RST}  pre-flight"

# ---- 1. docker compose up -d -----------------------------------------------
step "Step 1 — docker compose up -d"
UP_OUT=$(ssh $SSH_OPTS "$DOCKER_HOST" "cd $REPO_DIR && sudo docker compose up -d 2>&1" || true)
UP_EXIT=$?
echo "$UP_OUT" | tail -20 | sed 's/^/    /'
if [ "$UP_EXIT" -ne 0 ]; then
    die 7 "docker compose up -d exited $UP_EXIT — see output above"
fi
pass "compose up -d issued"
record "${GRN}PASS${RST}  compose up -d"

# ---- 2. wait for container state=running -----------------------------------
step "Step 2 — wait for container health (max ${CONTAINER_WAIT}s)"
RUNNING=0
for i in $(seq 1 "$CONTAINER_WAIT"); do
    STATE=$(ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker inspect -f '{{.State.Status}}' $CONTAINER 2>/dev/null" || echo "missing")
    if [ "$STATE" = "running" ]; then
        RUNNING=1
        pass "container $CONTAINER is running (after ${i}s)"
        record "${GRN}PASS${RST}  container running (${i}s)"
        break
    fi
    if [ $((i % 5)) -eq 0 ]; then
        echo "    still waiting — state=$STATE (t=${i}s)"
    fi
    sleep 1
done
if [ "$RUNNING" -ne 1 ]; then
    echo
    echo "last 50 lines of docker logs $CONTAINER:"
    ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 50 $CONTAINER 2>&1" | sed 's/^/    /' || true
    die 1 "container $CONTAINER never reached running state within ${CONTAINER_WAIT}s"
fi

# ---- 3. wait for VM SSH reachability ---------------------------------------
step "Step 3 — wait for VM SSH reachability (max ${SSH_WAIT}s)"
SSH_UP=0
START_TS=$(date +%s)
while : ; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))
    if [ "$ELAPSED" -ge "$SSH_WAIT" ]; then
        break
    fi
    if ssh $SSH_OPTS "$VM_HOST" "true" 2>/dev/null; then
        SSH_UP=1
        pass "VM $VM_HOST reachable over SSH after ${ELAPSED}s"
        record "${GRN}PASS${RST}  vm ssh up (${ELAPSED}s)"
        break
    fi
    printf "."
    sleep 5
done
echo
if [ "$SSH_UP" -ne 1 ]; then
    echo "last 80 lines of docker logs $CONTAINER:"
    ssh $SSH_OPTS "$DOCKER_HOST" "sudo docker logs --tail 80 $CONTAINER 2>&1" | tail -40 | sed 's/^/    /' || true
    die 2 "VM SSH did not come up within ${SSH_WAIT}s"
fi

# ---- 4. verify-m1.sh (M1 gate) ---------------------------------------------
step "Step 4 — verify-m1.sh (M1 gate)"
M1_EXIT=0
if [ ! -x "$TESTS_DIR/verify-m1.sh" ]; then
    warn "verify-m1.sh missing or not executable — cannot run M1 gate"
    record "${YEL}SKIP${RST}  verify-m1 (script missing)"
    # Treat as a hard failure; without M1 signal we have nothing useful.
    die 3 "verify-m1.sh not available"
fi
if DOCKER_HOST="$DOCKER_HOST" VM="$VM_HOST" \
        BOOT_TIMEOUT="$SSH_WAIT" \
        "$TESTS_DIR/verify-m1.sh"; then
    pass "verify-m1.sh PASSED (M1 gate green)"
    record "${GRN}PASS${RST}  verify-m1 (M1)"
else
    M1_EXIT=$?
    fail "verify-m1.sh exited $M1_EXIT — see output above"
    record "${RED}FAIL${RST}  verify-m1 (M1)  (exit $M1_EXIT)"
    # M1 failed: running M3 afterwards is pointless. Collect health + bail.
    run_health_report_best_effort
    print_summary
    exit 3
fi

# ---- 5. verify-modes.sh (baseline sanity, not a milestone) -----------------
# verify-m1.sh already invokes verify-modes.sh as its last step, so in the
# common case this is a no-op re-run. We still run it explicitly here so the
# pipeline report has a dedicated PASS/FAIL row for "display baseline intact".
# This matters when an operator is iterating on the display-patcher path
# independently of the apple-gfx-pci path.
step "Step 5 — verify-modes.sh (display baseline)"
MODES_EXIT=0
if [ ! -x "$TESTS_DIR/verify-modes.sh" ]; then
    warn "verify-modes.sh missing — skipping baseline sanity"
    record "${YEL}SKIP${RST}  verify-modes (script missing)"
else
    if VM="$VM_HOST" "$TESTS_DIR/verify-modes.sh"; then
        pass "verify-modes.sh PASSED (display baseline intact)"
        record "${GRN}PASS${RST}  verify-modes (baseline)"
    else
        MODES_EXIT=$?
        fail "verify-modes.sh exited $MODES_EXIT — display baseline regressed"
        record "${RED}FAIL${RST}  verify-modes  (exit $MODES_EXIT)"
        # Flagged for exit-5 below.
    fi
fi

# ---- 6. verify-phase1.sh (M3 gate — may fail if no apple-gfx-pci) ---------
step "Step 6 — verify-phase1.sh (M3 gate, graceful-fail permitted)"
M3_EXIT=0
if [ "$SKIP_M3" = "1" ]; then
    warn "SKIP_M3=1 — skipping verify-phase1.sh"
    record "${YEL}SKIP${RST}  verify-phase1 (SKIP_M3=1)"
elif [ ! -x "$TESTS_DIR/verify-phase1.sh" ]; then
    warn "verify-phase1.sh missing — skipping M3 gate"
    record "${YEL}SKIP${RST}  verify-phase1 (script missing)"
else
    if VM="$VM_HOST" "$TESTS_DIR/verify-phase1.sh"; then
        pass "verify-phase1.sh PASSED (M3 gate green — Metal no-op round-trip OK)"
        record "${GRN}PASS${RST}  verify-phase1 (M3)"
    else
        M3_EXIT=$?
        # M3 is the expected soft-fail today (pre-apple-gfx-pci hot path).
        # Report it clearly but don't treat it as a catastrophic regression;
        # the caller decides via exit code 4 vs 0 below.
        warn "verify-phase1.sh exited $M3_EXIT — M3 gate not yet green"
        warn "  common today: exit 2 = MTLCopyAllDevices=0 (kext not publishing"
        warn "  as IOAccelerator yet), exit 3 = no metal-no-op binary, exit 4 = noop failed"
        record "${YEL}WARN${RST}  verify-phase1 (M3 not green)  (exit $M3_EXIT)"
    fi
fi

# ---- 7. vm-health-report.sh (always) ---------------------------------------
# Always run, even on green — the tarball is the canonical artefact for
# operators reviewing a run after the fact.
run_health_report_best_effort

# ---- Summary + exit --------------------------------------------------------
print_summary

if [ "$M3_EXIT" -ne 0 ] && [ "$SKIP_M3" != "1" ]; then
    echo "${YEL}partial — M1 green, M3 not yet green${RST}"
    # Only gate on M3 when the script was actually executable; skipped M3 is exit 0.
    if [ -x "$TESTS_DIR/verify-phase1.sh" ]; then
        exit 4
    fi
fi
if [ "$MODES_EXIT" -ne 0 ]; then
    echo "${YEL}partial — M1 green but display baseline regressed${RST}"
    exit 5
fi

echo "${GRN}ALL GREEN — M1${RST}${GRN}${SKIP_M3:+}${RST}${GRN} pipeline passed${RST}"
exit 0
