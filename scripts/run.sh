#!/bin/bash
# mos-docker run — boot the installed macOS.
#
# Production launcher. Refuses to start if /data/disk.img is missing or
# looks empty. NEVER calls qemu-img create on the data disk.
#
# Hardware config comes from scripts/lib/hw-args.sh (single source of
# truth shared with install.sh + test.sh). This script only handles
# data-volume validation, install-media wiring, persist-vs-snapshot
# selection, observability paths, and the final exec.
set -euo pipefail

# Source the shared hardware-args lib. The lib is a *.sh helper (not
# executable) that exposes mos_hw_* functions appending to QEMU_ARGS.
# shellcheck source=lib/hw-args.sh
. /scripts/lib/hw-args.sh

DATA=/data
DISK="$DATA/disk.img"
OPENCORE="$DATA/OpenCore.img"

# --- Validate the data volume contents ----------------------------------
if [ ! -f "$DISK" ]; then
    echo "ERROR: $DISK does not exist." >&2
    echo "  Install first:  docker run ... mos-docker install" >&2
    exit 1
fi

DISK_SIZE=$(stat -Lc%s "$DISK")
if [ "$DISK_SIZE" -lt 1048576 ]; then
    echo "ERROR: $DISK is only $DISK_SIZE bytes — not a valid macOS install." >&2
    echo "  This is probably a setup script artifact. Install first:" >&2
    echo "    rm -f \$HOST_MOS_DATA/disk.img" >&2
    echo "    docker run ... mos-docker install" >&2
    exit 1
fi

BUILTIN_OPENCORE="/usr/share/mos-docker/OpenCore.img"
if [ ! -f "$OPENCORE" ]; then
    if [ -f "$BUILTIN_OPENCORE" ]; then
        echo "Staging OpenCore.img from image-builtin source."
        cp "$BUILTIN_OPENCORE" "$OPENCORE"
    else
        echo "ERROR: $OPENCORE does not exist and no builtin image present." >&2
        echo "  Drop an OpenCore EFI image at \$HOST_MOS_DATA/OpenCore.img." >&2
        exit 1
    fi
fi

# --- Boot diagnostics setup -------------------------------------------
LOG_DIR="$DATA/logs"
RUN_DIR="$DATA/run"
mkdir -p "$LOG_DIR" "$RUN_DIR"
BOOT_TS="$(date +%Y%m%d-%H%M%S)"
SERIAL_LOG="$LOG_DIR/serial-${BOOT_TS}.log"
QEMU_TRACE="$LOG_DIR/qemu-trace.log"
HMP_SOCK="$RUN_DIR/qemu-monitor.sock"
QMP_SOCK="$RUN_DIR/qemu-qmp.sock"
rm -f "$HMP_SOCK" "$QMP_SOCK"

# --- Reset NVRAM if requested -----------------------------------------
if [ -f "$DATA/.reset-nvram" ]; then
    echo "NVRAM reset requested"
    cp /usr/share/OVMF/OVMF_VARS.clean.fd /usr/share/OVMF/OVMF_VARS.fd
    rm -f "$DATA/.reset-nvram"
fi

# --- Optional install media (set by install.sh, NEVER set otherwise) --
INSTALL_MEDIA=""
if [ -n "${MOS_QEMU_INSTALL_MEDIA:-}" ] && [ -f "$MOS_QEMU_INSTALL_MEDIA" ]; then
    INSTALL_MEDIA="$MOS_QEMU_INSTALL_MEDIA"
fi

# --- Optional bundled noVNC (install mode) ----------------------------
NOVNC_BG=""
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_DISPLAY=$((VNC_PORT - 5900))
if [ "${MOS_QEMU_BUNDLED_NOVNC:-0}" = "1" ]; then
    echo "Starting bundled noVNC on http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
    websockify --web=/usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
    NOVNC_BG=$!
fi

# --- Trace backend setup ---------------------------------------------
# [project] Master switch for QEMU trace events. Default OFF to avoid
# overhead in production runs. Enable with MOS_ENABLE_TRACE=1 when
# debugging specific device paths:
#   - apple-gfx-pci: apple_gfx_* traces (realize/reset/vblank/map/etc)
#   - HID devices: hid_* traces (future)
#
# Trace event names are defined in qemu-mos15/hw/display/trace-events. A
# pattern that matches zero events silently produces an empty log, so
# verify against that file before changing the prefix.
TRACE_ARGS=()
if [ "${MOS_ENABLE_TRACE:-0}" = "1" ]; then
    if [ "${MOS_USE_APPLE_GFX_PCI:-0}" = "1" ]; then
        TRACE_ARGS=( -D "$QEMU_TRACE" -d "trace:apple_gfx_*" )
        echo "INFO: Trace backend enabled for apple-gfx-pci (apple_gfx_*) -> $QEMU_TRACE"
    fi
fi

# --- MacHDD persistence mode ----------------------------------------
# [project] Default: snapshot=on (writes go to a per-run overlay in
# QEMU's tmp; disk.img stays read-only; overlay vanishes on container
# exit). This protects the install from drift during dev iteration, and
# matches the "never auto-destroy operator state" principle.
#
# MOS_PERSIST=1 → snapshot=off; writes hit disk.img directly. Set this
# when you actually want changes to survive (e.g. installing software
# in macOS that you want to keep across runs). install.sh sets this
# automatically.
MACHDD_OPTS="snapshot=on"
if [ "${MOS_PERSIST:-0}" = "1" ]; then
    MACHDD_OPTS=""
fi

# --- Build the QEMU args via the shared lib --------------------------
# Order: macOS stack first (CPU, SMP, memory, machine, firmware, SMBIOS+
# AppleSMC+ICH9, USB, display, network), then disk + I/O. Phase-specific
# bits stay here in run.sh.
QEMU_ARGS=()
mos_hw_macos_stack
mos_hw_disk_args "$OPENCORE" "$DISK" "$MACHDD_OPTS" "$INSTALL_MEDIA"
mos_hw_io_args "$SERIAL_LOG" "$HMP_SOCK" "$QMP_SOCK" "$VNC_DISPLAY" "chardev"

echo "================================================================"
echo "  mos-docker — booting macOS"
echo "    disk:        $DISK ($(numfmt --to=iec "$DISK_SIZE"))"
echo "    persist:     $([ "${MOS_PERSIST:-0}" = "1" ] && echo "YES (writes hit disk.img)" || echo "no (snapshot=on; writes ephemeral)")"
echo "    OpenCore:    $OPENCORE"
echo "    serial log:  $SERIAL_LOG"
echo "    HMP socket:  $HMP_SOCK"
echo "    QMP socket:  $QMP_SOCK"
[ -n "$INSTALL_MEDIA" ] && echo "    install:     $INSTALL_MEDIA"

# Resolve numactl prefix (may be empty); echoes status into the banner.
mos_hw_numa_pin
echo "================================================================"

# Cleanup websockify on exit
trap '[ -n "$NOVNC_BG" ] && kill $NOVNC_BG 2>/dev/null || true' EXIT

# Enable libapplegfx logging — trace level for debugging, info for production.
# Set via LAGFX_LOG_LEVEL=trace|info|warn (default: warn). Override with:
#   export LAGFX_LOG_LEVEL=trace && ./mos run
export LAGFX_LOG_LEVEL="${LAGFX_LOG_LEVEL:-trace}"
echo "INFO: libapplegfx logging enabled at level: $LAGFX_LOG_LEVEL"

# Stage 65d Option 3: triangle shader modules for compute handler 0x74.
# Set via LAGFX_TRIANGLE_VERTEX_SPV and LAGFX_TRIANGLE_FRAGMENT_SPV env vars.
# SPVs should be baked into the container (e.g., at /usr/share/lagfx/).
export LAGFX_TRIANGLE_VERTEX_SPV="${LAGFX_TRIANGLE_VERTEX_SPV:-}"
export LAGFX_TRIANGLE_FRAGMENT_SPV="${LAGFX_TRIANGLE_FRAGMENT_SPV:-}"
if [ -n "$LAGFX_TRIANGLE_VERTEX_SPV" ] && [ -n "$LAGFX_TRIANGLE_FRAGMENT_SPV" ]; then
    if [ -f "$LAGFX_TRIANGLE_VERTEX_SPV" ] && [ -f "$LAGFX_TRIANGLE_FRAGMENT_SPV" ]; then
        echo "INFO: triangle shader modules: vertex=$LAGFX_TRIANGLE_VERTEX_SPV fragment=$LAGFX_TRIANGLE_FRAGMENT_SPV"
    else
        echo "WARN: LAGFX_TRIANGLE_*_SPV set but files not found — triangle modules will be NULL"
    fi
else
    echo "INFO: LAGFX Triangle SPVs not configured (set env vars to enable)"
fi

# shellcheck disable=SC2086  # NUMA_PIN is intentionally word-split.
exec $NUMA_PIN qemu-system-x86_64 \
    "${QEMU_ARGS[@]}" \
    "${TRACE_ARGS[@]}" \
    ${EXTRA:-}
