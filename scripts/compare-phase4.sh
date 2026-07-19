#!/bin/bash
# compare-phase4.sh — one-command objective verdict for the M5 compositor.
#
# Pulls a FRESH phase-4 screendump off the running container via QMP
# (screendump → PNG), copies it to the laptop, and scores it against the
# phase-3 gold lock-screen oracle with compare-to-oracle.py. Prints the
# scorecard and (on FAIL) a per-region diff heatmap path.
#
# Run from the laptop (100% of dev is on the laptop; classe is pull-only).
#
# Usage:
#   scripts/compare-phase4.sh [--heatmap] [--json] [--keep]
#
# Exit codes: 0 RECOGNIZABLE=PASS · 1 FAIL · 2 capture/usage error
#
# The compositor agent runs THIS each cycle instead of eyeballing noVNC.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# compare-to-oracle.py + oracle live in the sibling mos repo.
MOS_DIR="${MOS_DIR:-$(cd "$REPO_DIR/../mos" && pwd)}"
TOOL="$MOS_DIR/paravirt-re/tools/compare-to-oracle.py"
OUT_DIR="$REPO_DIR/baselines"
mkdir -p "$OUT_DIR"

WANT_HEATMAP=0
EXTRA_ARGS=()
KEEP=0
for a in "$@"; do
    case "$a" in
        --heatmap) WANT_HEATMAP=1 ;;
        --json) EXTRA_ARGS+=(--json) ;;
        --keep) KEEP=1 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

[ -f "$TOOL" ] || { echo "ERROR: tool not found: $TOOL" >&2; exit 2; }

TS="$(date +%Y%m%d-%H%M%S)"
SHOT_NAME="phase4-compare-${TS}.png"
# Container path (bind-mounted to host /mnt/docker/mos-data/run).
CTR_SHOT="/data/run/${SHOT_NAME}"
HOST_SHOT="/mnt/docker/mos-data/run/${SHOT_NAME}"
LAPTOP_SHOT="$OUT_DIR/${SHOT_NAME}"

echo "=== compare-phase4: capturing fresh screendump via QMP ==="

CTR="$(ssh -o ConnectTimeout=8 docker 'docker ps --filter name=mos-test-phase4 -q | head -1' 2>/dev/null || true)"
if [ -z "$CTR" ]; then
    echo "ERROR: no running mos-test-phase4 container on classe." >&2
    echo "  Start the M5 dev stack first (./mos test 4 or the persistent-container recipe)." >&2
    exit 2
fi
echo "  container: $CTR"

# Locate the phase-4 QMP socket inside the container (glob for timestamped names).
QMP_SOCK="$(ssh docker "docker exec $CTR sh -c 'ls /data/run/qemu-phase4*qmp.sock 2>/dev/null | head -1'" 2>/dev/null || true)"
if [ -z "$QMP_SOCK" ]; then
    echo "ERROR: no phase-4 QMP socket (/data/run/qemu-phase4*qmp.sock) in container." >&2
    exit 2
fi
echo "  qmp: $QMP_SOCK"

# Fire screendump over QMP. socat ships inside the container (used by test.sh).
# Pipe two real newline-separated QMP commands via stdin (docker exec -i) to
# dodge all shell-escaping of the JSON. CTR_SHOT/QMP_SOCK expand on the laptop.
ssh docker "docker exec -i $CTR socat - UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1 <<EOF || true
{"execute":"qmp_capabilities"}
{"execute":"screendump","arguments":{"filename":"${CTR_SHOT}","format":"png"}}
EOF

# Give QEMU a beat to flush the PNG, then verify + pull.
for _ in 1 2 3 4 5; do
    if ssh docker "test -s ${HOST_SHOT}"; then break; fi
    sleep 1
done
if ! ssh docker "test -s ${HOST_SHOT}"; then
    echo "ERROR: screendump did not appear at ${HOST_SHOT} on classe." >&2
    echo "  (QMP socket may be busy, or screendump/png unsupported by this QEMU.)" >&2
    exit 2
fi

scp -q "docker:${HOST_SHOT}" "$LAPTOP_SHOT"
echo "  captured: $LAPTOP_SHOT ($(stat -f%z "$LAPTOP_SHOT" 2>/dev/null || stat -c%s "$LAPTOP_SHOT") bytes)"
echo

if [ "$WANT_HEATMAP" = "1" ]; then
    EXTRA_ARGS+=(--heatmap "$OUT_DIR/phase4-heatmap-${TS}.png")
fi

set +e
python3 "$TOOL" "$LAPTOP_SHOT" "${EXTRA_ARGS[@]}"
RC=$?
set -e

# Housekeeping: drop the remote copy; keep the laptop shot unless --keep off.
ssh docker "rm -f ${HOST_SHOT}" 2>/dev/null || true
if [ "$KEEP" != "1" ]; then
    : # laptop shot retained by default for inspection; delete manually if noise
fi

exit $RC
