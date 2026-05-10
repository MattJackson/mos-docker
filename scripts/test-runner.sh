#!/bin/bash
# mos-docker test-runner — code-driven phase regression check.
#
# Runs ONE phase end-to-end:
#   1. Launch the phase via docker compose (test image, detached).
#   2. Tail the serial log; fail fast on panic / debugger / 240s busy timeout.
#   3. Wait for the per-phase boot marker (UEFI shell prompt for phase 0;
#      `loginwindow (PID)` for phases 1-3). Timeout = $BOOT_TIMEOUT (default 300s).
#   4. Settle $SETTLE_SECS (default 15).
#   5. Capture the QEMU framebuffer via QMP screendump → PPM → PNG.
#   6. ImageMagick `compare -metric AE -fuzz $FUZZ` vs baselines/phase-N-gold.png.
#      PASS if pixel-diff count < $DIFF_THRESHOLD_PCT% of 1920×1080.
#   7. Tear down the container, exit 0 on PASS, 1 on FAIL.
#
# Boot success requires BOTH:
#   - serial: kernel reached login state internally
#   - visual: framebuffer matches gold within tolerance
#
# Usage: scripts/test-runner.sh <phase>           # one phase
#        scripts/test-runner.sh all               # phases 0..3 sequentially
#
# Env knobs: BOOT_TIMEOUT, SETTLE_SECS, FUZZ, RUNNER_VERBOSE=1
set -euo pipefail

PHASE_ARG="${1:?usage: test-runner.sh <phase|all>}"
# Phase 1/2/3 typically reach loginwindow at 138-153s on a warm image, but
# cold-cache or first-run-after-rebuild can stretch past 300s (apple HID
# enumeration on a fresh image was observed to push past 300s on first
# run after the apple-magic-tablet → apple-mighty-mouse rename). 600s
# gives ~4x headroom over typical, still bounded so a hung phase fails
# fast.
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
SETTLE_SECS="${SETTLE_SECS:-15}"
FUZZ="${FUZZ:-5%}"
DATA_DIR=/mnt/docker/mos-data
BASELINES_DIR="${BASELINES_DIR:-/home/matthew/mos-docker/baselines}"
TEST_IMAGE="${TEST_IMAGE:-mos-docker:test}"

# Resolution for diff-threshold calc.
RES_W=1920; RES_H=1080
TOTAL_PX=$((RES_W * RES_H))

# Per-phase config.  Settle + threshold values calibrated 2026-05-06 via
# scripts/calibrate-phase.sh (see commit log).  Re-run calibration if a
# phase's boot timing changes (resource bump, OS update, etc).
#
#   phase  login-rendered@  max-diff%  → settle  threshold
#   0      ~10s (UEFI)       0.74%       15s     1%
#   1      143s              0.59%       200s    1.5%
#   2      138s              0.64%       200s    1.5%
#   3      153s              0.65%       200s    1.5%
phase_config() {
    local phase=$1
    INPUT_VERIFY=0
    case "$phase" in
        0)
            # OVMF on the empty phase-0 disk falls through to PXE after
            # the boot manager fails to find Boot0001. The "UEFI
            # Interactive Shell" prompt only appears when a shell is
            # actually loaded, which doesn't happen on the bare disk. Use
            # the markers OVMF actually prints on this path: BdsDxe
            # boot-failed line + the PXE-attempt banner.
            BOOT_MARKER='BdsDxe: failed to load Boot|Start PXE over|UEFI Interactive Shell|EDK II'
            PHASE_SETTLE=15
            DIFF_THRESHOLD_PCT=1
            ;;
        1|2)
            BOOT_MARKER='loginwindow \([0-9]+\)'
            PHASE_SETTLE=200
            DIFF_THRESHOLD_PCT=2   # 2% gives ~3x headroom over max observed (0.65%)
            ;;
        3)
            BOOT_MARKER='loginwindow \([0-9]+\)'
            PHASE_SETTLE=200
            DIFF_THRESHOLD_PCT=2
            # Phase 3 = Apple HID by definition (apple-magic-keyboard +
            # apple-mighty-mouse). Drive deterministic input after boot
            # passes and gold-diff a second screendump so the test
            # actually exercises HID delivery, not just boot.
            INPUT_VERIFY=1
            ;;
        4)
            echo "phase 4: apple-gfx-pci paravirt — no gold (M5 stage 20% gate)" >&2
            return 2
            ;;
        *)
            echo "phase $phase: unknown" >&2
            return 2
            ;;
    esac
    FAIL_MARKERS='\bpanic\b|debugger entered|halted|busy timeout.*240s'
    GOLD="$BASELINES_DIR/phase-${phase}-gold.png"
    CURRENT="$BASELINES_DIR/phase-${phase}-current.png"
    DIFF_OVERLAY="$BASELINES_DIR/phase-${phase}-diff.png"
    INPUT_GOLD="$BASELINES_DIR/phase-${phase}-input-gold.png"
    INPUT_CURRENT="$BASELINES_DIR/phase-${phase}-input-current.png"
    INPUT_DIFF="$BASELINES_DIR/phase-${phase}-input-diff.png"
    if [ ! -f "$GOLD" ]; then
        echo "phase $phase: ERROR gold not found at $GOLD" >&2
        return 2
    fi
    return 0
}

# Drive a deterministic HID input sequence into a running QEMU via QMP.
# Used by phase 3's INPUT_VERIFY to exercise apple-magic-keyboard +
# apple-mighty-mouse delivery. Sends three keys (a/b/c → 3 password dots
# at the loginwindow prompt) and an absolute mouse position (15000,15000
# in QEMU's 0..32767 abs space — center of screen, cursor visible).
qmp_drive_input() {
    local sock=$1
    sudo bash -c "{
        printf '%s\n' '{\"execute\":\"qmp_capabilities\"}'
        printf '%s\n' '{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"a\"}]}}'
        printf '%s\n' '{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"b\"}]}}'
        printf '%s\n' '{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"c\"}]}}'
        printf '%s\n' '{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":15000}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":15000}}]}}'
    } | socat - UNIX-CONNECT:$sock" >/dev/null 2>&1
}

# Send Escape via QMP to clear the password field after input verify, so
# subsequent runs of the same phase find a clean loginwindow state.
qmp_clear_password() {
    local sock=$1
    sudo bash -c "{
        printf '%s\n' '{\"execute\":\"qmp_capabilities\"}'
        printf '%s\n' '{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"esc\"}]}}'
    } | socat - UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
}

teardown() {
    local name=$1
    sudo docker stop "$name" >/dev/null 2>&1 || true
    sudo docker rm "$name" >/dev/null 2>&1 || true
}

run_phase() {
    local phase=$1
    phase_config "$phase" || return $?

    # Container name carries a unique per-invocation suffix so two
    # concurrent `./mos verify N` invocations (e.g. M5 lane + HID lane
    # both probing the same phase) don't collide on `--name`. Suffix
    # is HHMMSS+PID — collision-resistant within the same second.
    local container="mos-runner-phase${phase}-$(date +%H%M%S)-$$"
    local serial_glob="$DATA_DIR/logs/serial-phase${phase}-*.log"
    # screendump uses HMP (`echo screendump <path>`), not QMP (which is JSON).
    # test.sh creates both sockets — HMP on qemu-phaseN-monitor.sock, QMP on
    # qemu-phaseN-qmp.sock. Use HMP for human-readable command syntax.
    local hmp_sock="$DATA_DIR/run/qemu-phase${phase}-monitor.sock"
    # screendump path must be container-internal — QEMU runs INSIDE the
    # container where /data/run/ is the mount; reading happens from the
    # corresponding host path /mnt/docker/mos-data/run/.
    local ppm_in_container="/data/run/phase${phase}-runner.ppm"
    local ppm="$DATA_DIR/run/phase${phase}-runner.ppm"
    local png="$DATA_DIR/run/phase${phase}-runner.png"
    local diff_png="$DATA_DIR/run/phase${phase}-runner-diff.png"

    # Evict any leftover same-phase runner container (e.g. operator Ctrl-C'd
    # a prior run, leaving the detached `-d` container behind). The unique
    # HHMMSS+PID suffix means `teardown "$container"` below would only catch
    # the new name, not prior leftovers — so prefix-match here.
    local stale
    for stale in $(sudo docker ps -aq --filter "name=^mos-runner-phase${phase}-" 2>/dev/null); do
        sudo docker rm -f "$stale" >/dev/null 2>&1 || true
    done
    teardown "$container"

    local start_ts=$(date +%s)
    echo "[runner] phase $phase: launching ($container)..."
    # --init: tini as PID 1 reaps QEMU's exit (clean OR via KVM-kernel
    # SIGSEGV) deterministically. Without it, when test.sh's `exec qemu`
    # makes QEMU itself PID 1, an abnormal exit can desync dockerd's
    # task-state machine from containerd, producing a "Up" zombie that
    # nothing short of a daemon restart will clear.
    sudo docker run -d --rm --init --name "$container" \
        --privileged --network host \
        --device /dev/kvm:/dev/kvm \
        --cap-add NET_ADMIN \
        --memory 24g --cpus 32 \
        -e RAM=16 -e SMP=16 -e CORES=16 \
        -e EXTERNAL_SUPERVISOR=1 \
        -v "$DATA_DIR":/data \
        -v "$BASELINES_DIR":/baselines \
        ${KBD_DEVICE:+-e KBD_DEVICE="$KBD_DEVICE"} \
        ${TABLET_DEVICE:+-e TABLET_DEVICE="$TABLET_DEVICE"} \
        --entrypoint /scripts/test.sh \
        "$TEST_IMAGE" "$phase" >/dev/null

    # Wait for a serial log created AFTER we launched (avoid picking up
    # stale logs from prior runs that may contain unrelated panic markers).
    local serial_log=""
    for _ in $(seq 1 60); do
        local candidate
        candidate=$(sudo sh -c "ls -t $serial_glob 2>/dev/null | head -1")
        if [ -n "$candidate" ]; then
            local log_mtime
            log_mtime=$(sudo stat -c%Y "$candidate" 2>/dev/null || echo 0)
            if [ "$log_mtime" -ge "$start_ts" ]; then
                serial_log="$candidate"
                break
            fi
        fi
        sleep 1
    done
    if [ -z "$serial_log" ]; then
        echo "[runner] phase $phase: FAIL — no fresh serial log appeared in 60s (stale logs may exist)"
        teardown "$container"
        return 1
    fi
    [ "${RUNNER_VERBOSE:-0}" = "1" ] && echo "[runner] phase $phase: serial=$serial_log"

    # Poll: fail-fast on panic markers, succeed on boot marker.
    local boot_time=0
    while true; do
        local elapsed=$(($(date +%s) - start_ts))

        if sudo grep -qE "$FAIL_MARKERS" "$serial_log" 2>/dev/null; then
            local panic_line=$(sudo grep -nE "$FAIL_MARKERS" "$serial_log" | head -1)
            echo "[runner] phase $phase: FAIL panic=\"$panic_line\" t=${elapsed}s"
            echo "  full serial: $serial_log"
            teardown "$container"
            return 1
        fi

        if sudo grep -qE "$BOOT_MARKER" "$serial_log" 2>/dev/null; then
            boot_time=$elapsed
            break
        fi

        if [ "$elapsed" -gt "$BOOT_TIMEOUT" ]; then
            echo "[runner] phase $phase: FAIL — boot timeout after ${BOOT_TIMEOUT}s"
            echo "  full serial: $serial_log"
            teardown "$container"
            return 1
        fi
        sleep 5
    done

    [ "${RUNNER_VERBOSE:-0}" = "1" ] && echo "[runner] phase $phase: boot marker hit at ${boot_time}s, settling ${PHASE_SETTLE}s..."
    sleep "$PHASE_SETTLE"

    # Capture framebuffer via HMP screendump. Use the container-internal
    # path because QEMU is running inside the container.
    if ! sudo bash -c "echo screendump $ppm_in_container | socat - UNIX-CONNECT:$hmp_sock" >/dev/null 2>&1; then
        echo "[runner] phase $phase: FAIL — QMP screendump failed (socket missing or no display surface)"
        echo "  This may mean the guest never created a DisplaySurface (e.g. apple-gfx-pci with no opcodes)."
        teardown "$container"
        return 1
    fi
    sleep 2
    if ! sudo test -f "$ppm"; then
        echo "[runner] phase $phase: FAIL — screendump produced no PPM"
        teardown "$container"
        return 1
    fi

    # Convert PPM → PNG via alpine+imagemagick container.
    sudo docker run --rm -v "$DATA_DIR/run:/work" alpine:3.20 sh -c \
        "apk add -q imagemagick && convert /work/$(basename "$ppm") /work/$(basename "$png")" >/dev/null 2>&1 || {
            echo "[runner] phase $phase: FAIL — PPM→PNG conversion failed"
            teardown "$container"
            return 1
        }
    sudo cp "$png" "$CURRENT"

    # Compare against gold via alpine+imagemagick container.
    # `compare -metric AE -fuzz N%` prints the count of differing pixels to stderr,
    # exits 1 if there's any diff. We capture stderr and ignore exit code.
    local diff_count
    diff_count=$(sudo docker run --rm \
        -v "$DATA_DIR/run:/work" \
        -v "$BASELINES_DIR:/baselines:ro" \
        alpine:3.20 sh -c \
        "apk add -q imagemagick && compare -metric AE -fuzz $FUZZ /work/$(basename "$png") /baselines/$(basename "$GOLD") /work/$(basename "$diff_png") 2>&1; true" \
        | tail -1)
    sudo cp "$diff_png" "$DIFF_OVERLAY" 2>/dev/null || true

    # ImageMagick reports the count as scientific notation when large
    # (e.g. `1.85972e+06`). Normalize via awk to a plain integer so the
    # comparison below works.
    local diff_int
    diff_int=$(awk "BEGIN { printf \"%d\", $diff_count }" 2>/dev/null || echo "")
    if [[ ! "$diff_int" =~ ^[0-9]+$ ]]; then
        echo "[runner] phase $phase: FAIL — image compare error: $diff_count"
        teardown "$container"
        return 1
    fi
    diff_count=$diff_int

    local threshold_px=$((TOTAL_PX * DIFF_THRESHOLD_PCT / 100))
    local pct
    pct=$(awk "BEGIN { printf \"%.2f\", $diff_count / $TOTAL_PX * 100 }")

    if [ "$diff_count" -ge "$threshold_px" ]; then
        echo "[runner] phase $phase: FAIL  boot=${boot_time}s diff=${diff_count}/${TOTAL_PX} (${pct}%) threshold=${DIFF_THRESHOLD_PCT}%"
        echo "  current: $CURRENT"
        echo "  diff:    $DIFF_OVERLAY"
        teardown "$container"
        return 1
    fi

    # Boot diff passed. If the phase wants HID input verification, drive
    # a deterministic key + mouse sequence and gold-diff a second
    # screendump so the test actually proves HID delivery, not just
    # boot.
    if [ "${INPUT_VERIFY:-0}" = "1" ]; then
        local qmp_sock="$DATA_DIR/run/qemu-phase${phase}-qmp.sock"
        local input_ppm_in="/data/run/phase${phase}-input.ppm"
        local input_ppm="$DATA_DIR/run/phase${phase}-input.ppm"
        local input_png="$DATA_DIR/run/phase${phase}-input.png"
        local input_diff_png="$DATA_DIR/run/phase${phase}-input-diff.png"

        [ "${RUNNER_VERBOSE:-0}" = "1" ] && echo "[runner] phase $phase: input verify — driving keys + mouse via QMP..."
        if ! qmp_drive_input "$qmp_sock"; then
            echo "[runner] phase $phase: FAIL — QMP input injection failed (socket $qmp_sock)"
            teardown "$container"
            return 1
        fi
        sleep 2

        if ! sudo bash -c "echo screendump $input_ppm_in | socat - UNIX-CONNECT:$hmp_sock" >/dev/null 2>&1; then
            echo "[runner] phase $phase: FAIL — input screendump failed"
            qmp_clear_password "$qmp_sock"
            teardown "$container"
            return 1
        fi
        sleep 2
        if ! sudo test -f "$input_ppm"; then
            echo "[runner] phase $phase: FAIL — input screendump produced no PPM"
            qmp_clear_password "$qmp_sock"
            teardown "$container"
            return 1
        fi

        sudo docker run --rm -v "$DATA_DIR/run:/work" alpine:3.20 sh -c \
            "apk add -q imagemagick && convert /work/$(basename "$input_ppm") /work/$(basename "$input_png")" >/dev/null 2>&1 || {
                echo "[runner] phase $phase: FAIL — input PPM→PNG conversion failed"
                qmp_clear_password "$qmp_sock"
                teardown "$container"
                return 1
            }
        sudo cp "$input_png" "$INPUT_CURRENT"

        # Auto-bootstrap: if no input gold exists yet, capture this run as
        # the gold, mark the run PASS with a bootstrap note, and let the
        # operator review the screenshot before subsequent runs enforce
        # diff. Future runs gold-diff strictly.
        if [ ! -f "$INPUT_GOLD" ]; then
            sudo cp "$INPUT_CURRENT" "$INPUT_GOLD"
            qmp_clear_password "$qmp_sock"
            echo "[runner] phase $phase: PASS  boot=${boot_time}s diff=${diff_count}/${TOTAL_PX} (${pct}%) [input-gold bootstrapped at $INPUT_GOLD — review then commit]"
            teardown "$container"
            return 0
        fi

        local input_diff_count
        input_diff_count=$(sudo docker run --rm \
            -v "$DATA_DIR/run:/work" \
            -v "$BASELINES_DIR:/baselines:ro" \
            alpine:3.20 sh -c \
            "apk add -q imagemagick && compare -metric AE -fuzz $FUZZ /work/$(basename "$input_png") /baselines/$(basename "$INPUT_GOLD") /work/$(basename "$input_diff_png") 2>&1; true" \
            | tail -1)
        sudo cp "$input_diff_png" "$INPUT_DIFF" 2>/dev/null || true

        local input_diff_int
        input_diff_int=$(awk "BEGIN { printf \"%d\", $input_diff_count }" 2>/dev/null || echo "")
        if [[ ! "$input_diff_int" =~ ^[0-9]+$ ]]; then
            echo "[runner] phase $phase: FAIL — input image compare error: $input_diff_count"
            qmp_clear_password "$qmp_sock"
            teardown "$container"
            return 1
        fi

        local input_pct
        input_pct=$(awk "BEGIN { printf \"%.2f\", $input_diff_int / $TOTAL_PX * 100 }")

        # Always send Escape to clear password field for idempotent re-runs.
        # Run AFTER the diff capture so the diff reflects the post-input
        # state, not the post-clear state.
        qmp_clear_password "$qmp_sock"

        if [ "$input_diff_int" -ge "$threshold_px" ]; then
            echo "[runner] phase $phase: FAIL  input-diff=${input_diff_int}/${TOTAL_PX} (${input_pct}%) threshold=${DIFF_THRESHOLD_PCT}%"
            echo "  input current: $INPUT_CURRENT"
            echo "  input diff:    $INPUT_DIFF"
            teardown "$container"
            return 1
        fi

        echo "[runner] phase $phase: PASS  boot=${boot_time}s diff=${diff_count}/${TOTAL_PX} (${pct}%) input-diff=${input_diff_int}/${TOTAL_PX} (${input_pct}%) threshold=${DIFF_THRESHOLD_PCT}%"
        teardown "$container"
        return 0
    fi

    echo "[runner] phase $phase: PASS  boot=${boot_time}s diff=${diff_count}/${TOTAL_PX} (${pct}%) threshold=${DIFF_THRESHOLD_PCT}%"
    teardown "$container"
    return 0
}

run_all() {
    local fails=0
    local passed=()
    local failed=()
    for phase in 0 1 2 3; do
        if run_phase "$phase"; then
            passed+=("$phase")
        else
            fails=$((fails + 1))
            failed+=("$phase")
        fi
    done
    echo
    echo "================================================================"
    echo "  Summary: ${#passed[@]} pass / ${#failed[@]} fail"
    [ ${#passed[@]} -gt 0 ] && echo "  PASS: ${passed[*]}"
    [ ${#failed[@]} -gt 0 ] && echo "  FAIL: ${failed[*]}"
    echo "================================================================"
    return "$fails"
}

case "$PHASE_ARG" in
    all) run_all ;;
    [0-4]) run_phase "$PHASE_ARG" ;;
    *) echo "usage: $0 <phase|all>" >&2; exit 2 ;;
esac
