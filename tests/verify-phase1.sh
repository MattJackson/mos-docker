#!/bin/bash
# verify-phase1.sh — Phase 1 exit criterion check for libapplegfx-vulkan +
# apple-gfx-pci-linux + mos-patcher integration. Run AFTER a fresh boot
# with the apple-gfx-pci device enabled in the QEMU commandline.
#
# This verifies the Metal rev-9 plan's Phase 1 gate:
#   - MTLCopyAllDevices ≥ 1
#   - metal-no-op.m (empty command buffer commit) round-trips
#
# Usage:
#   VM=user@host ./tests/verify-phase1.sh
#
# Exit codes:
#   0 — Phase 1 criterion met (device enumerated AND empty cmdbuf completed)
#   1 — SSH unreachable / VM not booted
#   2 — metal-probe shows count=0 (device not enumerating yet)
#   3 — metal-no-op binary missing on host — build first
#   4 — metal-no-op reported failure on the VM

set -u
VM="${VM:?VM env var required, e.g. VM=user@10.0.0.1}"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
TESTS_DIR="$(dirname "$0")"
PROBE_BIN="$TESTS_DIR/metal-probe"
NOOP_BIN="$TESTS_DIR/metal-no-op"

RED=$(printf '\033[0;31m')
GRN=$(printf '\033[0;32m')
YEL=$(printf '\033[0;33m')
RST=$(printf '\033[0m')
pass() { echo "${GRN}✓${RST} $1"; }
fail() { echo "${RED}✗${RST} $1"; }
warn() { echo "${YEL}!${RST} $1"; }

# ---- 1. VM reachable --------------------------------------------------------
if ! ssh $SSH_OPTS "$VM" "true" 2>/dev/null; then
    fail "can't reach $VM — VM not booted or SSH key missing"
    exit 1
fi
pass "VM reachable over SSH"

if ! ssh $SSH_OPTS "$VM" "who" | grep -q console; then
    fail "no console user logged in — CG/Metal session bootstrap unavailable"
    exit 1
fi
pass "console user logged in"

# ---- 2. Metal device enumerating -------------------------------------------
if [ ! -x "$PROBE_BIN" ]; then
    warn "$PROBE_BIN not built — run: (cd tests && clang -framework Foundation -framework Metal -framework CoreGraphics metal-probe.m -o metal-probe)"
else
    scp -q $SSH_OPTS "$PROBE_BIN" "$VM:/tmp/" 2>/dev/null
    PROBE_OUT=$(ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 /tmp/metal-probe 2>/dev/null")
    COUNT=$(echo "$PROBE_OUT" | awk '/^count:/{print $2; exit}')
    echo "$PROBE_OUT" | sed 's/^/    /'
    if [ "${COUNT:-0}" -lt 1 ]; then
        fail "MTLCopyAllDevices count=${COUNT:-0} — Phase 1 not met"
        echo
        echo "Likely blockers:"
        echo "  - libapplegfx-vulkan not yet publishing as IOAccelerator"
        echo "  - apple-gfx-pci device not attached to VM"
        echo "  - AppleParavirtGPU kext not binding to our PCI device"
        exit 2
    fi
    pass "MTLCopyAllDevices count=$COUNT"
fi

# ---- 3. Empty command buffer round-trip ------------------------------------
if [ ! -x "$NOOP_BIN" ]; then
    fail "$NOOP_BIN not built"
    echo "Build with: (cd tests && clang -framework Foundation -framework Metal metal-no-op.m -o metal-no-op)"
    exit 3
fi
scp -q $SSH_OPTS "$NOOP_BIN" "$VM:/tmp/" 2>/dev/null
NOOP_OUT=$(ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 /tmp/metal-no-op 2>&1" || echo "SSH_EXIT_$?")
NOOP_EXIT=$(ssh $SSH_OPTS "$VM" "sudo -n launchctl asuser 501 /tmp/metal-no-op >/dev/null 2>&1; echo \$?")
echo "$NOOP_OUT" | sed 's/^/    /'
case "$NOOP_EXIT" in
    0) pass "metal-no-op round-trip OK" ;;
    1) fail "metal-no-op: default device null"; exit 4 ;;
    2) fail "metal-no-op: newCommandQueue failed"; exit 4 ;;
    3) fail "metal-no-op: commandBuffer creation failed"; exit 4 ;;
    4) fail "metal-no-op: waitUntilCompleted timed out"; exit 4 ;;
    5) fail "metal-no-op: cmdbuf ended in Error state"; exit 4 ;;
    *) fail "metal-no-op: unexpected exit code $NOOP_EXIT"; exit 4 ;;
esac

echo
echo "${GRN}=== Phase 1 exit criterion MET ===${RST}"
echo "  libapplegfx-vulkan + apple-gfx-pci-linux integration verified"
echo "  next stage: Phase 2 — first Metal pixel (clear-color)"
