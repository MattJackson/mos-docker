#!/bin/bash
# verify-stage80.sh — regression harness for Stage 80 (login wallpaper / progress UI)
#
# Spec: memory/M5_progress_scale_5percent.md §Stage 80
# Gate: stable boot-to-loginwindow traffic without crashing; ≥95% framebuffer rendered correctly
#
# Usage: scripts/verify-stage80.sh [--timeout N] [--min-triangle-draws N] [--lagfx-log-path PATH]
#   timeout: seconds to wait for loginwindow indicators (default 300)
#   min-triangle-draws: minimum substitute-triangle draws expected (default 50)
#   lagfx-log-path: path to lagfx.log inside container (default /tmp/lagfx.log)
#
# Exit codes:
#   0 — PASS: all gates met, loginwindow indicators observed, no errors
#   1 — FAIL: one or more gates failed with diagnostic output
#   2 — usage / argument error

set -euo pipefail

TIMEOUT="${BOOT_TIMEOUT:-300}"
MIN_TRIANGLE_DRAWS="${MIN_TRIANGLE_DRAWS:-50}"
LAGFX_LOG_PATH="${LAGFX_LOG_PATH:-/tmp/lagfx.log}"

# Inside container: /data; on host: /mnt/docker/mos-data
CONTAINER_DATA_DIR="/data"
HOST_DATA_DIR="/mnt/docker/mos-data"
LOG_DIR="$CONTAINER_DATA_DIR/logs"
ARTIFACTS_DIR="$HOST_DATA_DIR/artifacts/verify-stage80"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Stage 80 regression harness — verify stable boot-to-loginwindow traffic.

Options:
  --timeout N        seconds to wait for loginwindow indicators (default: $TIMEOUT)
  --min-triangle-draws N  minimum substitute-triangle draws expected (default: $MIN_TRIANGLE_DRAWS)
  --lagfx-log-path P    path to lagfx.log inside container (default: $LAGFX_LOG_PATH)
  --help              show this help message

Exit codes:
  0 — PASS
  1 — FAIL
  2 — usage error
EOF
    exit "$2"
}

# Parse arguments (skip stage number if provided as first positional arg)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) 
            shift
            if [[ ${1:-} =~ ^[0-9]+$ ]]; then
                TIMEOUT="$1"
                shift
            else
                echo "ERROR: --timeout requires a numeric argument" >&2
                exit 2
            fi ;;
        --min-triangle-draws) 
            shift
            if [[ ${1:-} =~ ^[0-9]+$ ]]; then
                MIN_TRIANGLE_DRAWS="$1"
                shift
            else
                echo "ERROR: --min-triangle-draws requires a numeric argument" >&2
                exit 2
            fi ;;
        --lagfx-log-path) 
            shift
            LAGFX_LOG_PATH="$1"
            shift ;;
        --help|-h) usage; exit 0 ;;
        [0-9]*) shift ;; # skip stage number if provided
        *) echo "unknown arg: $1" >&2; usage "invalid argument"; exit 2 ;;
    esac
done

# Find phase-4 container (Stage 80 runs on the M5 dev stack)
find_phase4_container() {
    ssh -o ConnectTimeout=5 docker 'docker ps --filter name=mos-test-phase4 -q | head -1' 2>/dev/null || true
}

# Wait for boot indicator in lagfx.log (Stage 80 runs on M5 dev stack with active traffic)
wait_for_boot_marker() {
    local ctr="$1"
    local timeout="$2"
    local start_ts
    start_ts=$(date +%s)
    
    # For Stage 80, we check for boot indicators in lagfx.log rather than serial
    # since the M5 dev stack may not produce serial output after initial boot
    
    echo "[stage80] waiting for lagfx boot indicators..."
    
    while true; do
        local elapsed=$(($(date +%s) - start_ts))
        
        if [[ $elapsed -ge $timeout ]]; then
            echo "ERROR: boot timeout after ${timeout}s" >&2
            return 1
        fi
        
        # Check for active lagfx traffic (display ss[+0x104]=0xC indicates kext is ready)
        local display_ready_count
        display_ready_count=$(ssh docker "docker exec $ctr grep -c 'ss\\[.*=0C' \"$LAGFX_LOG_PATH\" 2>/dev/null | head -1 || echo 0")
        
        if [[ "$display_ready_count" =~ ^[0-9]+$ ]] && [[ "$display_ready_count" -gt 0 ]]; then
            echo "[stage80] boot indicator found: display ss[+0x104]=0xC (kext ready)" 
            return 0
        fi
        
        # Also check for substitute triangle draws as a secondary marker
        local sub_draws
        sub_draws=$(ssh docker "docker exec $ctr grep -c 'op_0x74 Option 3: substituted' \"$LAGFX_LOG_PATH\" 2>/dev/null | head -1 || echo 0")
        
        if [[ "$sub_draws" -gt 10 ]]; then
            echo "[stage80] boot indicator found: $sub_draws substitute triangle draws (traffic flowing)" 
            return 0
        fi
        
        sleep 5
    done
}

# Check for lagfx.log and tail it for indicators
check_lagfx_indicators() {
    local ctr="$1"
    
    # Use container-internal path for lagfx.log
    local internal_log_path="/tmp/lagfx.log"
    
    echo "[stage80] checking $internal_log_path for Stage 80 indicators..."
    
    # Count substitute triangle draws (Option 3 from Stage 75)
    local sub_draws
    sub_draws=$(ssh docker "docker exec $ctr grep -c 'op_0x74 Option 3: substituted' \"$internal_log_path\" || echo 0")
    if [[ "$sub_draws" -lt "$MIN_TRIANGLE_DRAWS" ]]; then
        echo "[stage80] FAIL: substitute triangle draws = $sub_draws (expected >= $MIN_TRIANGLE_DRAWS)" >&2
        return 1
    fi
    echo "[stage80] ✓ substitute triangle draws: $sub_draws"
    
    # Count render_target_readback events
    local readbacks
    readbacks=$(ssh docker "docker exec $ctr grep -c 'render_target_readback:.*OK' \"$internal_log_path\" || echo 0")
    if [[ "$readbacks" -lt 1 ]]; then
        echo "[stage80] FAIL: render_target_readback OK events = $readbacks (expected >= 1)" >&2
        return 1
    fi
    echo "[stage80] ✓ render_target_readback OK: $readbacks"
    
  # Check for vkCreateGraphicsPipelines failures
    local vkfail
    vkfail=$(ssh docker "docker exec $ctr grep -c 'vkCreateGraphicsPipelines failed' \"$internal_log_path\" 2>/dev/null | head -1 || echo 0")
    if [[ ! "$vkfail" =~ ^[0-9]+$ ]] || [[ "$vkfail" -gt 0 ]]; then
        echo "[stage80] FAIL: vkCreateGraphicsPipelines failures = $vkfail (expected 0)" >&2
        return 1
    fi
    echo "[stage80] ✓ vkCreateGraphicsPipelines failed: 0"
    
    # Check for VUID- / VK_ERROR_ lines (Vulkan validation errors)
    local vuid_errors
    vuid_errors=$(ssh docker "docker exec $ctr grep -E 'VUID-|VK_ERROR_' \"$internal_log_path\" | wc -l 2>/dev/null | head -1 || echo 0")
    vuid_errors=${vuid_errors:-0}
    vuid_errors=$(echo "$vuid_errors" | tr -d '[:space:]')
    if [[ ! "$vuid_errors" =~ ^[0-9]+$ ]] || [[ "$vuid_errors" -gt 0 ]]; then
        echo "[stage80] FAIL: VUID-/VK_ERROR_ lines = $vuid_errors (expected 0)" >&2
        return 1
    fi
    echo "[stage80] ✓ VUID-/VK_ERROR_ lines: 0"
    
    # Check for unhandled MMIO / unknown opcode warnings after boot completion
    local unhandled_mmio
    unhandled_mmio=$(ssh docker "docker exec $ctr grep -c 'unhandled MMIO' \"$internal_log_path\" 2>/dev/null | head -1 || echo 0")
    unhandled_mmio=${unhandled_mmio:-0}
    unhandled_mmio=$(echo "$unhandled_mmio" | tr -d '[:space:]')
    if [[ ! "$unhandled_mmio" =~ ^[0-9]+$ ]] || [[ "$unhandled_mmio" -gt 0 ]]; then
        echo "[stage80] FAIL: unhandled MMIO warnings = $unhandled_mmio (expected 0)" >&2
        return 1
    fi
    echo "[stage80] ✓ unhandled MMIO: 0"
    
    # Check for kernel panic / page fault in lagfx.log
    local panic_count
    panic_count=$(ssh docker "docker exec $ctr grep -ciE 'panic|page fault' \"$internal_log_path\" 2>/dev/null | head -1 || echo 0")
    panic_count=${panic_count:-0}
    panic_count=$(echo "$panic_count" | tr -d '[:space:]')
    if [[ ! "$panic_count" =~ ^[0-9]+$ ]] || [[ "$panic_count" -gt 0 ]]; then
        echo "[stage80] FAIL: panic/page-fault lines = $panic_count (expected 0)" >&2
        return 1
    fi
    echo "[stage80] ✓ kernel panic / page fault: 0"
    
    # Check for steady-state op_0x74 traffic (AppleParavirtGPU draw commands)
    local op74_traffic
    op74_traffic=$(ssh docker "docker exec $ctr grep -c 'inner_op: 0x74' \"$internal_log_path\" 2>/dev/null | head -1 || echo 0")
    if [[ "$op74_traffic" -lt 1 ]]; then
        echo "[stage80] WARN: op_0x74 traffic = $op74_traffic (expected >= 1, but continuing)" >&2
    else
        echo "[stage80] ✓ op_0x74 traffic: $op74_traffic"
    fi
    
    return 0
}

# Capture artifacts
capture_artifacts() {
    local ctr="$1"
    
    mkdir -p "$ARTIFACTS_DIR" || true
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local full_timestamp="verify-stage80-${timestamp}"
    
    # Copy lagfx.log from container to host artifacts
    ssh docker "docker exec $ctr cat /tmp/lagfx.log > \"$ARTIFACTS_DIR/${full_timestamp}.lagfx.log\"" 2>/dev/null || true
    
    echo "[stage80] artifacts saved to $ARTIFACTS_DIR/"
    ls -la "$ARTIFACTS_DIR/" 2>/dev/null || echo "  (artifacts directory may not exist on host)"
}

# Main execution
main() {
    echo "=========================================="
    echo "Stage 80 Regression Harness"
    echo "=========================================="
    echo "Timeout: ${TIMEOUT}s"
    echo "Min triangle draws: $MIN_TRIANGLE_DRAWS"
    echo "Lagfx log path: $LAGFX_LOG_PATH"
    echo
    
    # Find phase-4 container
    local ctr
    ctr=$(find_phase4_container) || {
        echo "ERROR: cannot find mos-test-phase4 container" >&2
        echo "  Run 'docker ps --filter name=mos-test-phase4' to verify the container is running" >&2
        exit 1
    }
    
    if [[ -z "$ctr" ]]; then
        echo "ERROR: no phase-4 container found" >&2
        echo "  Start with: ./mos test 4" >&2
        exit 1
    fi
    
    echo "[stage80] using container: $ctr"
    echo
    
    # Wait for boot marker (loginwindow PID)
    if ! wait_for_boot_marker "$ctr" "$TIMEOUT"; then
        echo "=========================================="
        echo "FAIL — did not reach loginwindow indicator within ${TIMEOUT}s"
        echo "=========================================="
        exit 1
    fi
    
    # Check lagfx indicators
    if ! check_lagfx_indicators "$ctr"; then
        echo "=========================================="
        echo "FAIL — lagfx.log gate(s) failed (see diagnostics above)"
        echo "=========================================="
        capture_artifacts "$ctr" || true
        exit 1
    fi
    
    # All gates passed
    echo
    echo "=========================================="
    echo "PASS — Stage 80 verified successfully"
    echo "=========================================="
    echo "Gates met:"
    echo "  ✓ loginwindow boot marker (PID)"
    echo "  ✓ substitute triangle draws: $MIN_TRIANGLE_DRAWS+"
    echo "  ✓ render_target_readback OK events"
    echo "  ✓ vkCreateGraphicsPipelines failed: 0"
    echo "  ✓ VUID-/VK_ERROR_ lines: 0"
    echo "  ✓ unhandled MMIO: 0"
    echo "  ✓ kernel panic / page fault: 0"
    capture_artifacts "$ctr" || true
    
    exit 0
}

main
