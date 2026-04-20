#!/bin/bash
# capture-doorbell-mmio.sh — runtime capture of MMIO traffic into the
# apple-gfx-pci BAR0 register window, intended to disambiguate which
# offset in {0x1004, 0x1008, 0x1010, 0x101c, 0x1020, 0x1024, 0x1028,
# 0x1030, 0x1034} is the ring write-pointer doorbell (setFifoWritten:).
#
# Spec: /Users/mjackson/mos/paravirt-re/re-followup-spec-gaps.md §1.5
#
# Doorbell definition (per that spec): the MMIO offset whose value is
# forwarded (not stored) during the first `MTLCreateSystemDefaultDevice`
# flow, and that receives a 1024-byte-aligned byte-offset / write-pointer
# value following the three setFifo{BasePage,Length,Start} writes. It is
# the last write before the atomic-swap read at 0x1014.
#
# Capture strategy (dual-mode, first that works wins):
#
#   Mode A — trace-event subscription via QMP.
#     Preferred. Uses `trace-event-set-state` to enable the
#     apple_gfx_pci_mmio_write event (from qemu-mos15's
#     apple-gfx-pci-linux.c). Trace output lands on QEMU stderr, which
#     is captured by `docker logs`. We tail docker logs for the 30-sec
#     window and scan for `apple_gfx_pci_mmio_write` lines with offset
#     in the candidate set.
#
#   Mode B — human-monitor xp snapshotting via QMP.
#     Fallback when the trace event isn't compiled in. We issue
#     `human-monitor-command` with `xp /9wx <BAR0_ADDR>+0x1004` at a
#     10 Hz poll interval, delta the snapshots against t=0, and
#     identify which candidate offsets changed and in what order.
#     Less precise (we see state, not writes) but does not require
#     a trace-enabled build.
#
# Either way, the VERDICT is "the offset in the candidate set that
# received the FIRST non-zero write AFTER the setFifo{BasePage,Length,
# Start} three-write burst". The three earlier writes are themselves
# in the candidate set too (§1.5 item 2), so the ordering matters.
# Heuristically:
#   - Values that look like PFNs (>= 0x1000) => setFifoBasePage.
#   - Values <= 0x20000 and == 0 mod 0x1000 that arrive first => length.
#   - Values 1 KB-aligned arriving just before the 0x1000=1 arm write =>
#     setFifoStart (initial write pointer).
#   - Value arriving AFTER 0x1000=1 (device armed, ring live), carrying
#     a new write-pointer post-commit => setFifoWritten (THE DOORBELL).
#
# Usage:
#   DOCKER_HOST=user@host ./tests/capture-doorbell-mmio.sh
#
# Required env:
#   DOCKER_HOST   ssh target for the docker host (we need `docker logs`
#                 + access to the QMP unix socket inside the container).
#
# Optional env:
#   CONTAINER       docker container name (default: macos-macos-1)
#   QMP_SOCK        path to QMP unix socket inside container (default:
#                   /data/run/qemu-qmp.sock — per launch.sh b96604e)
#   CAPTURE_WINDOW  seconds to capture (default: 30)
#   OUT_ROOT        capture root dir (default: tests/capture-boot-logs)
#   BAR0_HINT       physical address of apple-gfx-pci BAR0 for Mode B.
#                   If unset and Mode B is needed, we query QEMU via
#                   `info pci` to resolve it.
#   FORCE_MODE      'A' or 'B' to pin to one strategy (default: auto)
#
# Output:
#   <OUT_ROOT>/doorbell-<stamp>/doorbell-candidates.json
#   <OUT_ROOT>/doorbell-<stamp>/capture.log            (raw scrape)
#   <OUT_ROOT>/doorbell-<stamp>/capture-meta.txt
#
# Exit codes:
#   0   doorbell identified with HIGH or MED confidence
#   1   inconclusive — no writes observed in the candidate window
#   2   QMP socket unreachable / QMP handshake failed
#   3   pre-flight failure (DOCKER_HOST unreachable / container down)

set -u

DOCKER_HOST="${DOCKER_HOST:?DOCKER_HOST env var required, e.g. DOCKER_HOST=user@docker-host}"
CONTAINER="${CONTAINER:-macos-macos-1}"
QMP_SOCK="${QMP_SOCK:-/data/run/qemu-qmp.sock}"
CAPTURE_WINDOW="${CAPTURE_WINDOW:-30}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="${OUT_ROOT:-$TESTS_DIR/capture-boot-logs}"
BAR0_HINT="${BAR0_HINT:-}"
FORCE_MODE="${FORCE_MODE:-auto}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"

# Candidate offsets (see re-followup-spec-gaps.md §1 MMIO write table
# entries with "calls setter" in the write side — i.e. the slots that
# forward to one of the setFifo* setters).
CANDIDATE_OFFSETS=(0x1004 0x1008 0x1010 0x101c 0x1020 0x1024 0x1028 0x1030 0x1034)

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="$OUT_ROOT/doorbell-$STAMP"
mkdir -p "$OUT_DIR"
CAP_LOG="$OUT_DIR/capture.log"
META_FILE="$OUT_DIR/capture-meta.txt"
JSON_OUT="$OUT_DIR/doorbell-candidates.json"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
BLU=$(printf '\033[0;34m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}PASS${RST} $1"; }
fail() { echo "${RED}FAIL${RST} $1"; }
warn() { echo "${YEL}WARN${RST} $1"; }
step() { echo; echo "${BLU}===${RST} $1"; }

# ---- Pre-flight ------------------------------------------------------------
step "0/5 — pre-flight"
if ! ssh $SSH_OPTS "$DOCKER_HOST" "true" 2>/dev/null; then
    fail "docker host $DOCKER_HOST unreachable via SSH"
    exit 3
fi
pass "docker host $DOCKER_HOST reachable"

STATE=$(ssh $SSH_OPTS "$DOCKER_HOST" \
    "sudo docker inspect -f '{{.State.Status}}' $CONTAINER 2>/dev/null" || echo "missing")
if [ "$STATE" != "running" ]; then
    fail "container $CONTAINER state=$STATE (expected running)"
    exit 3
fi
pass "container $CONTAINER running"

# Resolve the QMP socket on the HOST side. launch.sh (per commit b96604e)
# binds it inside the container at /data/run/qemu-qmp.sock and the compose
# file bind-mounts ./run:/data/run — so on the host it's <REPO_DIR>/run/qemu-qmp.sock.
# We don't hardcode that path; instead we drive QMP via `docker exec` so the
# in-container path is always valid.
ssh $SSH_OPTS "$DOCKER_HOST" \
    "sudo docker exec $CONTAINER test -S $QMP_SOCK" 2>/dev/null
if [ $? -ne 0 ]; then
    fail "QMP socket $QMP_SOCK not present inside $CONTAINER"
    fail "launch.sh (commit b96604e) should create it — verify the container"
    fail "was rebuilt and launched after that commit landed."
    exit 2
fi
pass "QMP socket present at $QMP_SOCK (inside container)"

# We need socat inside the container to talk to the unix socket, OR we can
# pipe via `docker exec -i` to a python one-liner. Prefer socat if present
# (smaller blast radius). Fall back to python.
QMP_BRIDGE=""
if ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER sh -c 'command -v socat >/dev/null 2>&1'"; then
    QMP_BRIDGE="socat"
    pass "QMP bridge: socat (inside container)"
elif ssh $SSH_OPTS "$DOCKER_HOST" \
        "sudo docker exec $CONTAINER sh -c 'command -v python3 >/dev/null 2>&1'"; then
    QMP_BRIDGE="python3"
    pass "QMP bridge: python3 (socat not installed)"
else
    fail "neither socat nor python3 available inside $CONTAINER"
    fail "install one of them in the Dockerfile (socat preferred) to enable"
    fail "this capture. For now, bailing."
    exit 2
fi

{
    echo "stamp=$STAMP"
    echo "docker_host=$DOCKER_HOST"
    echo "container=$CONTAINER"
    echo "qmp_sock=$QMP_SOCK"
    echo "qmp_bridge=$QMP_BRIDGE"
    echo "capture_window=$CAPTURE_WINDOW"
    echo "candidate_offsets=${CANDIDATE_OFFSETS[*]}"
    echo "force_mode=$FORCE_MODE"
    echo "bar0_hint=$BAR0_HINT"
} > "$META_FILE"

# ---- QMP helper ------------------------------------------------------------
# qmp_send JSON_LINE — pushes a single QMP command (with qmp_capabilities
# handshake already prepended) into the socket and prints the response line.
# Uses a heredoc so multiple commands can be issued in one session.
qmp_session() {
    # Arg 1: a multi-line string of JSON commands (one per line). We always
    # prepend qmp_capabilities and append qmp quit.
    local commands="$1"
    if [ "$QMP_BRIDGE" = "socat" ]; then
        {
            echo '{"execute":"qmp_capabilities"}'
            printf '%s\n' "$commands"
            echo '{"execute":"quit"}'
        } | ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec -i $CONTAINER socat - UNIX-CONNECT:$QMP_SOCK 2>/dev/null" || true
    else
        # python3 bridge: same semantics, writes and reads line-by-line.
        {
            echo '{"execute":"qmp_capabilities"}'
            printf '%s\n' "$commands"
            echo '{"execute":"quit"}'
        } | ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec -i $CONTAINER python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(\"$QMP_SOCK\")
banner = s.recv(4096)
sys.stdout.write(banner.decode(\"utf-8\", errors=\"replace\"))
for line in sys.stdin:
    s.sendall(line.encode(\"utf-8\"))
    try:
        resp = s.recv(65536)
    except Exception:
        break
    if resp:
        sys.stdout.write(resp.decode(\"utf-8\", errors=\"replace\"))
        sys.stdout.flush()
s.close()
' 2>/dev/null" || true
    fi
}

# ---- Attempt QMP handshake -------------------------------------------------
step "1/5 — QMP handshake"
HANDSHAKE_OUT=$(qmp_session '{"execute":"query-version"}')
echo "$HANDSHAKE_OUT" > "$OUT_DIR/qmp-handshake.log"
if ! echo "$HANDSHAKE_OUT" | grep -q '"QMP"'; then
    fail "QMP banner not received — socket handshake failed"
    exit 2
fi
pass "QMP banner received"
if ! echo "$HANDSHAKE_OUT" | grep -q '"return"'; then
    warn "QMP handshake: no 'return' envelope observed — proceeding cautiously"
fi

# ---- Mode selection --------------------------------------------------------
step "2/5 — mode selection (A=trace-event / B=xp-snapshot)"
# Check whether apple_gfx_pci_mmio_write is a known trace event.
TRACE_EVENTS=$(qmp_session '{"execute":"trace-event-get-state","arguments":{"name":"apple_gfx_pci_*"}}')
echo "$TRACE_EVENTS" >> "$OUT_DIR/qmp-handshake.log"

MODE="B"
if [ "$FORCE_MODE" = "A" ]; then
    MODE="A"
elif [ "$FORCE_MODE" = "B" ]; then
    MODE="B"
else
    if echo "$TRACE_EVENTS" | grep -q 'apple_gfx_pci_mmio_write'; then
        MODE="A"
    fi
fi

case "$MODE" in
    A)
        pass "Mode A (trace-event subscription) selected"
        ;;
    B)
        pass "Mode B (xp-snapshot polling) selected"
        warn "Mode A unavailable — apple_gfx_pci_mmio_write trace event not"
        warn "exposed in this QEMU build. Mode B is less precise (delta of"
        warn "state, not a stream of writes). See re-followup-spec-gaps.md §1.5."
        ;;
esac

# ---- Mode A: enable trace, sample docker logs -----------------------------
run_mode_a() {
    step "3/5 — Mode A: enable apple_gfx_pci_mmio_write trace"
    qmp_session '{"execute":"trace-event-set-state","arguments":{"name":"apple_gfx_pci_mmio_write","enable":true}}' \
        >> "$OUT_DIR/qmp-handshake.log"
    # Verify enabled.
    VERIFY=$(qmp_session '{"execute":"trace-event-get-state","arguments":{"name":"apple_gfx_pci_mmio_write"}}')
    echo "$VERIFY" >> "$OUT_DIR/qmp-handshake.log"
    if echo "$VERIFY" | grep -q '"state": "enabled"'; then
        pass "trace event enabled"
    else
        warn "trace-event-set-state did not report enabled — continuing anyway"
    fi

    step "4/5 — capture docker logs for ${CAPTURE_WINDOW}s"
    # Tail docker logs in the background; stop after CAPTURE_WINDOW sec.
    ( ssh $SSH_OPTS "$DOCKER_HOST" \
          "sudo docker logs -f --tail 0 $CONTAINER 2>&1" \
          > "$CAP_LOG" ) &
    TAIL_PID=$!
    sleep "$CAPTURE_WINDOW"
    kill "$TAIL_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    pass "capture complete ($(wc -l < "$CAP_LOG" | tr -d ' ') lines)"

    step "5/5 — analyze capture"
    # Extract apple_gfx_pci_mmio_write lines with offset in candidate set.
    # Expected trace format (from qemu-mos15 apple-gfx-pci-linux.c):
    #   apple_gfx_pci_mmio_write ofs=0x1034 val=0x00001234 size=4
    # Fall back to any line mentioning an offset in the candidate set.
    CANDIDATE_REGEX=$(printf '%s|' "${CANDIDATE_OFFSETS[@]}" | sed 's/|$//' | sed 's/|/\\|/g')
    grep -E "apple_gfx_pci_mmio_write.*ofs=(0x)?($CANDIDATE_REGEX)" "$CAP_LOG" \
        > "$OUT_DIR/mmio-hits.txt" 2>/dev/null || true
    # Emit JSON verdict.
    emit_verdict_mode_a
}

# ---- Mode B: xp-snapshot polling -------------------------------------------
run_mode_b() {
    step "3/5 — Mode B: resolve BAR0 of apple-gfx-pci"
    # `info pci` returns the PCI tree including BAR addresses. Parse it
    # for the apple-gfx-pci device and extract its BAR0 base.
    local pci_info
    pci_info=$(qmp_session '{"execute":"human-monitor-command","arguments":{"command-line":"info pci"}}')
    echo "$pci_info" > "$OUT_DIR/info-pci.log"
    local bar0
    if [ -n "$BAR0_HINT" ]; then
        bar0="$BAR0_HINT"
        pass "BAR0 hint: $bar0 (from env)"
    else
        # Crude parse: look for "apple-gfx-pci" then pick the next BAR0 line.
        bar0=$(echo "$pci_info" | awk '
            /apple-gfx-pci/ { found=1 }
            found && /BAR0:/ {
                # BAR0: 32 bit memory at 0xfe000000 [0xfe00ffff]
                match($0, /at 0x[0-9a-fA-F]+/);
                if (RSTART > 0) {
                    s = substr($0, RSTART+3, RLENGTH-3);
                    print s;
                    exit;
                }
            }')
        if [ -n "$bar0" ]; then
            pass "resolved BAR0 = $bar0 via info pci"
        else
            warn "could not parse BAR0 from info pci — set BAR0_HINT env to override"
            warn "capture will still run but xp reads may land on nothing"
            bar0="0xfe000000"  # last-ditch default; operator should set BAR0_HINT.
        fi
    fi
    echo "bar0=$bar0" >> "$META_FILE"

    step "4/5 — xp-poll the candidate window for ${CAPTURE_WINDOW}s"
    local end_ts=$(( $(date +%s) + CAPTURE_WINDOW ))
    local tick=0
    # Build a single QMP command batch that dumps all candidate offsets
    # in one human-monitor-command invocation per tick — one QMP round-trip
    # per snapshot, ~10 Hz. Each tick's output is appended to CAP_LOG with
    # a "t=N" header.
    > "$CAP_LOG"
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        {
            echo "=== tick=$tick ts=$(date +%s) ==="
            for ofs in "${CANDIDATE_OFFSETS[@]}"; do
                # Each ofs is like 0x1034. Combine bar0 + ofs in shell:
                local addr
                addr=$(printf '0x%x\n' $(( bar0 + ofs )))
                echo "--- ofs=$ofs addr=$addr ---"
                qmp_session "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"xp /1wx $addr\"}}"
            done
        } >> "$CAP_LOG"
        tick=$((tick + 1))
        sleep 0.1
    done
    pass "xp polling complete ($tick ticks captured)"

    step "5/5 — analyze capture (delta)"
    emit_verdict_mode_b
}

# ---- Verdict emitters ------------------------------------------------------
emit_verdict_mode_a() {
    local hits="$OUT_DIR/mmio-hits.txt"
    local count
    count=$(wc -l < "$hits" 2>/dev/null | tr -d ' ')
    [ -z "$count" ] && count=0
    echo "observed $count MMIO writes in candidate window"

    if [ "$count" = "0" ]; then
        warn "no writes observed — capture inconclusive"
        cat > "$JSON_OUT" <<EOF
{
  "mode": "A",
  "window_sec": $CAPTURE_WINDOW,
  "verdict": "inconclusive",
  "verdict_confidence": "none",
  "doorbell_offset": null,
  "writes": [],
  "notes": [
    "Mode A: trace event 'apple_gfx_pci_mmio_write' was enabled but no",
    "hits landed in docker logs during the capture window.",
    "Likely causes: (1) VM had already completed FIFO setup before",
    "capture started — re-run immediately after 'docker compose restart';",
    "(2) trace events weren't routed to QEMU stderr (tracing backend",
    "must be 'log' in the qemu-mos15 build — run with -trace to verify);",
    "(3) apple-gfx-pci isn't actually attached as a device (check",
    "'info pci' inside QMP)."
  ]
}
EOF
        exit 1
    fi

    # Build an ordered list of writes. Format each as JSON.
    # Regex: apple_gfx_pci_mmio_write ofs=0x1034 val=0x... size=4
    awk '
        match($0, /ofs=(0x)?[0-9a-fA-F]+/) {
            ofs = substr($0, RSTART, RLENGTH);
            gsub(/ofs=(0x)?/, "0x", ofs);
        }
        match($0, /val=(0x)?[0-9a-fA-F]+/) {
            val = substr($0, RSTART, RLENGTH);
            gsub(/val=(0x)?/, "0x", val);
        }
        { printf "%s %s %s\n", NR, ofs, val }
    ' "$hits" > "$OUT_DIR/writes-ordered.txt"

    # Heuristic per script header / spec §1.5:
    # - First three non-zero writes in candidate set => set{BasePage,Length,Start}
    # - Next write to an offset in {0x1004,0x1008,0x1010,0x101c,0x1020,
    #   0x1024,0x1028,0x1030,0x1034} AFTER a write to 0x1000 is the DOORBELL.
    local all_writes
    all_writes=$(cat "$hits" | head -20)
    # Find the arm-sequence index: line with ofs=0x1000 val!=0 in capture.log
    local arm_line
    arm_line=$(grep -n 'apple_gfx_pci_mmio_write.*ofs=0x1000' "$CAP_LOG" \
               | grep -v 'val=0x0$' | head -1 | awk -F: '{print $1}')
    local doorbell_offset="null"
    local confidence="low"
    if [ -n "$arm_line" ]; then
        # First candidate-range write AFTER the arm line is the doorbell.
        doorbell_offset=$(awk -v start="$arm_line" '
            NR > start && /apple_gfx_pci_mmio_write/ {
                for (i=1;i<=NF;i++) if ($i ~ /ofs=/) {
                    o=$i; sub(/ofs=(0x)?/, "0x", o); print o; exit
                }
            }' "$CAP_LOG")
        if [ -n "$doorbell_offset" ]; then
            confidence="high"
        else
            doorbell_offset="null"
            confidence="low"
        fi
    fi

    # Emit JSON.
    {
        printf '{\n'
        printf '  "mode": "A",\n'
        printf '  "window_sec": %s,\n' "$CAPTURE_WINDOW"
        printf '  "verdict": "%s",\n' \
            "$([ "$doorbell_offset" = "null" ] && echo inconclusive || echo identified)"
        printf '  "verdict_confidence": "%s",\n' "$confidence"
        printf '  "doorbell_offset": %s,\n' \
            "$([ "$doorbell_offset" = "null" ] && echo null || echo "\"$doorbell_offset\"")"
        printf '  "arm_line": %s,\n' \
            "$([ -z "$arm_line" ] && echo null || echo "$arm_line")"
        printf '  "writes": [\n'
        local first=1
        while read -r idx ofs val; do
            [ -z "$ofs" ] && continue
            if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
            printf '    {"seq": %s, "offset": "%s", "value": "%s"}' "$idx" "$ofs" "$val"
        done < "$OUT_DIR/writes-ordered.txt"
        printf '\n  ],\n'
        printf '  "notes": [\n'
        printf '    "Heuristic: first candidate-range write AFTER a non-zero write to 0x1000",\n'
        printf '    "(the FIFO arm) is the doorbell (setFifoWritten:) per",\n'
        printf '    "re-followup-spec-gaps.md §1.5."\n'
        printf '  ]\n'
        printf '}\n'
    } > "$JSON_OUT"

    if [ "$doorbell_offset" != "null" ]; then
        pass "doorbell identified: $doorbell_offset (confidence=$confidence)"
        exit 0
    else
        warn "writes observed but doorbell post-arm pattern not present"
        exit 1
    fi
}

emit_verdict_mode_b() {
    # Mode B only sees STATE, not write stream. We identify candidate
    # offsets whose value at t=0 was zero but became non-zero later.
    # Ordering: the offset that FLIPS LAST and is followed by no further
    # change (saturates to some write-pointer value) is the best doorbell
    # candidate. This is heuristic and LOW confidence compared to Mode A.
    local python_ok=0
    if ssh $SSH_OPTS "$DOCKER_HOST" \
            "sudo docker exec $CONTAINER sh -c 'command -v python3 >/dev/null 2>&1'" 2>/dev/null; then
        python_ok=1
    fi

    # Simple analysis: for each candidate offset, walk CAP_LOG collecting
    # its observed values over time.
    > "$OUT_DIR/per-offset-trace.txt"
    for ofs in "${CANDIDATE_OFFSETS[@]}"; do
        echo "=== ofs=$ofs ===" >> "$OUT_DIR/per-offset-trace.txt"
        awk -v target="$ofs" '
            /^=== tick=/ { tick=$2; sub(/^tick=/,"",tick) }
            $0 ~ "--- ofs=" target " " { want=1; next }
            want && /^[0-9a-fA-F]+:/ {
                # format: "00000000fe001034: 0x00000000"
                val=$2; printf "tick=%s val=%s\n", tick, val; want=0
            }
        ' "$CAP_LOG" >> "$OUT_DIR/per-offset-trace.txt"
    done

    # Identify the last-flipping candidate.
    local best_offset="" best_tick=-1
    for ofs in "${CANDIDATE_OFFSETS[@]}"; do
        local flip_tick
        flip_tick=$(awk -v target="$ofs" '
            /^=== ofs=/ { on = ($0 ~ target) ? 1 : 0; next }
            on && /^tick=/ {
                t=$1; v=$2; sub(/^tick=/,"",t); sub(/^val=/,"",v);
                if (v != "0x00000000" && first == 0) { print t; first=1 }
            }' "$OUT_DIR/per-offset-trace.txt" | head -1)
        if [ -n "$flip_tick" ] && [ "$flip_tick" -gt "$best_tick" ]; then
            best_tick="$flip_tick"
            best_offset="$ofs"
        fi
    done

    local verdict="inconclusive" conf="none" doorbell="null"
    if [ -n "$best_offset" ] && [ "$best_tick" -ge 0 ]; then
        verdict="identified-tentative"
        conf="low"
        doorbell="\"$best_offset\""
    fi

    {
        printf '{\n'
        printf '  "mode": "B",\n'
        printf '  "window_sec": %s,\n' "$CAPTURE_WINDOW"
        printf '  "verdict": "%s",\n' "$verdict"
        printf '  "verdict_confidence": "%s",\n' "$conf"
        printf '  "doorbell_offset": %s,\n' "$doorbell"
        printf '  "best_flip_tick": %s,\n' "$best_tick"
        printf '  "notes": [\n'
        printf '    "Mode B identifies the candidate offset whose state",\n'
        printf '    "flipped from zero to non-zero LATEST during the capture.",\n'
        printf '    "This is a weak proxy: the doorbell offset is the one that",\n'
        printf '    "was LAST written during FIFO arming (setFifoWritten:).",\n'
        printf '    "Confidence is low because Mode B samples state, not writes.",\n'
        printf '    "Rebuild qemu-mos15 with apple_gfx_pci_mmio_write trace event",\n'
        printf '    "enabled and re-run for a high-confidence verdict (Mode A)."\n'
        printf '  ]\n'
        printf '}\n'
    } > "$JSON_OUT"

    if [ "$verdict" != "inconclusive" ]; then
        pass "tentative doorbell: $best_offset (tick $best_tick, confidence=$conf)"
        exit 0
    else
        warn "no candidate flipped to non-zero during capture"
        exit 1
    fi
}

# ---- Dispatch --------------------------------------------------------------
case "$MODE" in
    A) run_mode_a ;;
    B) run_mode_b ;;
esac

# Should not reach here; both run_mode_* exit explicitly.
fail "internal error: mode dispatch fell through"
exit 1
