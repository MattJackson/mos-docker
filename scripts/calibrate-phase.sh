#!/bin/bash
# mos-docker calibrate-phase — one-off settle-time calibration.
#
# Boots a phase, captures the framebuffer every CAPTURE_INTERVAL secs for
# CALIBRATE_DURATION secs, compares each capture to baselines/phase-N-gold.png
# via ImageMagick, prints a time-series of diff%.  Use the result to pick a
# stable settle time to hard-code into scripts/test-runner.sh.
#
# Not part of the regular test sweep — this is a one-time tool you run when:
#   - First setting up a new phase's gold image.
#   - The phase's boot timing has changed (e.g. resource bump, OS update).
#   - The runner gets the wrong settle and you need to recalibrate.
#
# Usage: scripts/calibrate-phase.sh <phase>
# Output: tab-separated `t_secs<TAB>diff_count<TAB>pct` lines on stdout.
set -euo pipefail

PHASE="${1:?usage: calibrate-phase.sh <phase>}"
CAPTURE_INTERVAL="${CAPTURE_INTERVAL:-30}"
CALIBRATE_DURATION="${CALIBRATE_DURATION:-720}"  # 12 min default
FUZZ="${FUZZ:-5%}"
DATA_DIR=/mnt/docker/mos-data
BASELINES_DIR="${BASELINES_DIR:-/home/matthew/mos-docker/baselines}"
TEST_IMAGE="${TEST_IMAGE:-mos-docker:test}"
RES_W=1920; RES_H=1080
TOTAL_PX=$((RES_W * RES_H))

case "$PHASE" in
    0|1|2|3|4) ;;
    *) echo "unknown phase: $PHASE" >&2; exit 2 ;;
esac

GOLD="$BASELINES_DIR/phase-${PHASE}-gold.png"
[ -f "$GOLD" ] || { echo "ERROR: gold not found at $GOLD" >&2; exit 1; }

CONTAINER="mos-calibrate-phase${PHASE}"
HMP_SOCK="$DATA_DIR/run/qemu-phase${PHASE}-monitor.sock"
SAMPLES_DIR="$DATA_DIR/run/calibrate-phase${PHASE}"

teardown() {
    sudo docker stop "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker rm "$CONTAINER" >/dev/null 2>&1 || true
}
trap teardown EXIT

teardown
sudo mkdir -p "$SAMPLES_DIR"
sudo rm -f "$SAMPLES_DIR"/*.ppm "$SAMPLES_DIR"/*.png 2>/dev/null || true

echo "# calibrate-phase $PHASE: launching..."
START_TS=$(date +%s)
sudo docker run -d --rm --name "$CONTAINER" \
    --privileged --network host \
    --device /dev/kvm:/dev/kvm \
    --cap-add NET_ADMIN \
    --memory 20g --cpus 20 \
    -v "$DATA_DIR":/data \
    -v "$BASELINES_DIR":/baselines \
    --entrypoint /scripts/test.sh \
    "$TEST_IMAGE" "$PHASE" >/dev/null

# Wait for HMP socket (means QEMU is up + accepting commands).
for _ in $(seq 1 120); do
    sudo test -S "$HMP_SOCK" && break
    sleep 1
done
sudo test -S "$HMP_SOCK" || { echo "ERROR: HMP socket never appeared at $HMP_SOCK" >&2; exit 1; }
echo "# calibrate-phase $PHASE: HMP socket ready, capturing every ${CAPTURE_INTERVAL}s for ${CALIBRATE_DURATION}s"
echo "# t_secs	diff_count	pct"

LAUNCH_TS=$(date +%s)
END_TS=$((LAUNCH_TS + CALIBRATE_DURATION))

while [ "$(date +%s)" -lt "$END_TS" ]; do
    NOW=$(date +%s)
    T=$((NOW - START_TS))
    SAMPLE_BASE="sample-$(printf "%04d" "$T")"
    PPM_HOST="$SAMPLES_DIR/${SAMPLE_BASE}.ppm"
    PNG_HOST="$SAMPLES_DIR/${SAMPLE_BASE}.png"
    PPM_IN="/data/run/calibrate-phase${PHASE}/${SAMPLE_BASE}.ppm"

    # Screendump via HMP.
    sudo bash -c "echo screendump $PPM_IN | socat - UNIX-CONNECT:$HMP_SOCK" >/dev/null 2>&1 || {
        echo "# t=${T}s: screendump failed (container may have exited)" >&2
        break
    }
    sleep 1
    if ! sudo test -f "$PPM_HOST"; then
        echo "# t=${T}s: PPM never written" >&2
        sleep "$CAPTURE_INTERVAL"
        continue
    fi

    # Convert + compare.
    diff_count=$(sudo docker run --rm \
        -v "$SAMPLES_DIR:/work" \
        -v "$BASELINES_DIR:/baselines:ro" \
        alpine:3.20 sh -c \
        "apk add -q imagemagick && \
         convert /work/${SAMPLE_BASE}.ppm /work/${SAMPLE_BASE}.png && \
         compare -metric AE -fuzz $FUZZ /work/${SAMPLE_BASE}.png /baselines/$(basename "$GOLD") /work/${SAMPLE_BASE}-diff.png 2>&1; true" \
        | tail -1)
    diff_int=$(awk "BEGIN { printf \"%d\", $diff_count }" 2>/dev/null || echo "")
    [ -z "$diff_int" ] && diff_int=0
    pct=$(awk "BEGIN { printf \"%.2f\", $diff_int / $TOTAL_PX * 100 }")
    echo "${T}	${diff_int}	${pct}%"

    # Drop the PPM (large) but keep the PNG sample for later inspection.
    sudo rm -f "$PPM_HOST" 2>/dev/null || true

    sleep "$CAPTURE_INTERVAL"
done

echo "# calibrate-phase $PHASE: done. Samples kept in $SAMPLES_DIR"
