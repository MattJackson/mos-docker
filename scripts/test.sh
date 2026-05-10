#!/bin/bash
# mos-docker test — run a regression test phase (0..4 or 9).
#
# Hardware config comes from scripts/lib/hw-args.sh (single source of
# truth shared with run.sh + install.sh). This script only handles
# per-phase dispatch, supervisor pass/fail logic, and the QEMU exec.
#
# Phase chain (each isolates ONE variable on top of the previous):
#   0  bare QEMU + OVMF + std-vga + empty disk         sanity (UEFI shell)
#                                                      [project: phase 0
#                                                      stays on slirp +
#                                                      std-vga; no macOS,
#                                                      no real network
#                                                      needed]
#   1  OEM QEMU + macOS HD + vmware-svga + isa-applesmc[TRANSIENT — drops
#       + ICH9 globals + usb-kbd                       when our QEMU
#                                                      patches land
#                                                      upstream; OEM and
#                                                      patched then converge]
#                                                      bare-min stock-QEMU
#                                                      stack that boots to
#                                                      the macOS login screen
#   2  patched QEMU + same args                        binary swap (proves
#                                                      patches don't regress
#                                                      the bare-min login)
#   3  + apple-magic-keyboard + apple-mighty-mouse     Apple HID identity at
#                                                      the QEMU emulation
#                                                      level (cosmetic vs
#                                                      generic usb-kbd)
#   4  + apple-gfx-pci paravirt GPU                    THE ACTUAL MOS PRODUCT
#       (replaces vmware-svga; needs memfd backend     (currently black until
#       for coherence)                                 libapplegfx-vulkan
#                                                      opcode handlers ship;
#                                                      M5 stage 20% gate)
#
# End-state chain (after upstream merges retire phase 1):
#   0 sanity → 1 patched-baseline → 2 + apple HID → 3 apple-gfx-pci product.
#
# Networking model (changed 2026-05-10):
#   Phases 1+ default to macvtap (matches prod / install). Use
#   NETWORK_MODE=slirp to opt back into user-mode for tests that need
#   predictable host-fwd ssh. Phase 0 stays on slirp (firmware sanity,
#   no real network needed; saves macvtap setup overhead).
#
# Display model (changed 2026-05-10):
#   Phases 1+ default to vmware-svga (the April-2026 stable baseline).
#   std-vga is NEVER a default for macOS phases — it's an escape hatch
#   under DISPLAY_DEVICE=std-vga that prints a loud warning. Phase 0 is
#   the one place std-vga is hardcoded (firmware sanity, no macOS).
#   Phase 4 uses apple-gfx-pci.
set -euo pipefail

# Source the shared hardware-args lib.
# shellcheck source=lib/hw-args.sh
. /scripts/lib/hw-args.sh

PHASE="${1:-}"
case "$PHASE" in
    0|1|2|3|4|9) ;;
    *)
        echo "Usage: test <phase>" >&2
        echo "  phase: 0..4 or 9" >&2
        echo "    0=sanity, 4=production paravirt (M5 dev)," >&2
        echo "    9=interactive debug (writable disk, generic HID, vmware-svga," >&2
        echo "       NO auto-powerdown — stays alive until you stop it)" >&2
        exit 2
        ;;
esac

DATA=/data
DISK="$DATA/disk.img"
OPENCORE="$DATA/OpenCore.img"
LOG_DIR="$DATA/logs"
RUN_DIR="$DATA/run"
mkdir -p "$LOG_DIR" "$RUN_DIR"

BOOT_TS="$(date +%Y%m%d-%H%M%S)"
SERIAL_LOG="$LOG_DIR/serial-phase${PHASE}-${BOOT_TS}.log"
# Per-phase socket names so phases can run in parallel without conflict.
HMP_SOCK="$RUN_DIR/qemu-phase${PHASE}-monitor.sock"
QMP_SOCK="$RUN_DIR/qemu-phase${PHASE}-qmp.sock"
rm -f "$HMP_SOCK" "$QMP_SOCK"

# Per-phase port offset (6080..6089) so phases can run alongside production.
NOVNC_PORT="608${PHASE}"
VNC_PORT=$((5900 + PHASE))
VNC_DISPLAY=$((VNC_PORT - 5900))

# Pick the QEMU binary per phase. No silent fallback — predictable tests
# require the right binary or hard-fail.
#
# QEMU_VARIANT env override:
#   patched (default for all phases except 1)
#       Our mos-qemu fork: applesmc + apple-gfx-pci + apple-magic-* HID
#       + vmware_vga overlays. Required for paravirt (phase 4).
#   oem
#       Vanilla upstream QEMU 11.0.0 — no overlays. Useful for isolating
#       whether a regression is in our patches vs upstream behaviour.
#       Phase 1 uses this unconditionally for that bisect.
QEMU_VARIANT="${QEMU_VARIANT:-patched}"
QEMU_BIN=/usr/bin/qemu-system-x86_64
if [ "$PHASE" = "1" ] || [ "$QEMU_VARIANT" = "oem" ]; then
    if [ ! -x /usr/bin/qemu-system-x86_64-oem ]; then
        echo "ERROR: OEM binary requested but /usr/bin/qemu-system-x86_64-oem missing." >&2
        echo "  This image is missing it — likely a production-only image. Rebuild" >&2
        echo "  with the patched + OEM split image." >&2
        exit 1
    fi
    QEMU_BIN=/usr/bin/qemu-system-x86_64-oem
fi

# Auto-stage OpenCore.img from the in-image canonical copy on first run.
# Same logic as install.sh / run.sh — keeps source-of-truth in efi/ and
# the deployed image always matches what's in the repo.
BUILTIN_OPENCORE="/usr/share/mos-docker/OpenCore.img"
if [ ! -f "$OPENCORE" ] && [ -f "$BUILTIN_OPENCORE" ]; then
    echo "Staging OpenCore.img from image-builtin source."
    cp "$BUILTIN_OPENCORE" "$OPENCORE"
fi

# Sanity / data checks per phase.
if [ "$PHASE" -ge 1 ]; then
    [ -f "$DISK" ]      || { echo "ERROR: $DISK missing — phase $PHASE needs the macOS disk." >&2; exit 1; }
    [ -f "$OPENCORE" ]  || { echo "ERROR: $OPENCORE missing — phase $PHASE needs the OpenCore EFI image." >&2; exit 1; }
fi

# Phase-0 uses an ephemeral 1G empty disk in /data/run/ (NOT the data disk).
if [ "$PHASE" = "0" ]; then
    PHASE0_DISK="$RUN_DIR/phase0-empty.img"
    [ -f "$PHASE0_DISK" ] || qemu-img create -f raw "$PHASE0_DISK" 1G
    DISK="$PHASE0_DISK"
fi

# Bundled noVNC for inspection.
echo "Starting bundled noVNC on http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
websockify --web=/usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
NOVNC_BG=$!
cleanup() {
    [ -n "${NOVNC_BG:-}" ] && kill "$NOVNC_BG" 2>/dev/null || true
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
    # Tear down macvtap0 if we created one (set +e: cleanup is best-effort).
    ip link del macvtap0 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Compose QEMU args via the shared hw-args lib --------------------
# QEMU_ARGS is the array each helper appends to. We assemble it
# phase-by-phase below; the shared helpers cover everything that's
# universal, and the per-phase logic only adds genuine differences.
QEMU_ARGS=()

# [host] resource tuning + machine + memory backend (memfd when phase 4).
# For phase 4 the lib auto-adds memory-backend-memfd because
# MOS_USE_APPLE_GFX_PCI=1 is set below before machine_args. We have to
# call display_args FIRST in this script to set MOS_USE_APPLE_GFX_PCI for
# phase 4, then call machine_args after — but the hw-args lib's
# convention is the opposite. To stay compatible with the lib, set the
# env knob before calling machine_args.
if [ "$PHASE" = "4" ]; then
    export MOS_USE_APPLE_GFX_PCI=1
fi

mos_hw_machine_args "${RAM:-16}"
mos_hw_cpu_args
mos_hw_smp_args

# [macOS] firmware + Apple platform glue. Phase 0 skips applesmc / ICH9
# globals — there's no macOS to satisfy.
mos_hw_firmware_args
if [ "$PHASE" -ge 1 ]; then
    mos_hw_smbios_apple_args
fi

# [macOS] USB HID. Phase 3 = "Apple HID lane" — flip defaults so the
# regression suite exercises our patched USB devices. Other phases get
# generic usb-kbd / usb-tablet (apple-kbd breaks the macOS Recovery
# environment, and apple-mighty-mouse drifts under VNC remote-control).
if [ "$PHASE" = "3" ]; then
    KBD_DEVICE="${KBD_DEVICE:-apple-magic-keyboard}"
    TABLET_DEVICE="${MOUSE_DEVICE:-${TABLET_DEVICE:-apple-mighty-mouse}}"
fi
mos_hw_usb_args

# [macOS] Display device. Phase 0 = std-vga (firmware sanity). Phase 4 =
# apple-gfx-pci (already wired by the env knob set above). Phases 1-3 +
# 9 = vmware-svga via mos_hw_display_args (the default). std-vga is
# NEVER a default for macOS phases.
if [ "$PHASE" = "0" ]; then
    mos_hw_display_phase0_stdvga_args
else
    mos_hw_display_args
fi

# [project] Networking. Phases 1+ default to macvtap (matches prod);
# phase 0 stays on slirp (firmware sanity, no real network needed).
# NETWORK_MODE=slirp opts back in to user-mode for any phase.
if [ "$PHASE" = "0" ]; then
    NETWORK_MODE=slirp mos_hw_netdev_args $((22220 + PHASE))
else
    mos_hw_netdev_args $((22220 + PHASE))
fi

# [project] Display backend (no SDL/GTK; everything goes through VNC) +
# guest-error logging. These belong with [project] observability, not
# the shared hardware lib.
QEMU_ARGS+=(
    -display none
    # [project] log guest CPU faults + unimplemented-feature accesses to
    # qemu-debug.log. Critical for apple-gfx-pci debugging — MMIO
    # accesses that hit unimplemented paths surface here. WARNING:
    # `qemu_log()` lands here, NOT in `docker logs` stderr. See
    # memory/feedback_m5_log_locations.md before adding host-side logs.
    -d guest_errors,unimp
    -D /data/logs/qemu-debug.log
)

# [project] I/O — serial log + HMP/QMP sockets + VNC. Test phases use
# the simpler `file:` chardev style for serial (one log per phase boot).
mos_hw_io_args "$SERIAL_LOG" "$HMP_SOCK" "$QMP_SOCK" "$VNC_DISPLAY" "file"

# --- Disk attach -----------------------------------------------------
# [project] Phase 0 is the empty-disk sanity test (OVMF should fall
# through to PXE). Phases 1-4 + 9 attach the real macOS disk + OpenCore
# loader.
#
# [project] write semantics:
#   default                snapshot=on, file.locking=off  → ephemeral
#                          writes (RAM overlay; disk.img never mutated;
#                          phases run concurrent + with prod safely).
#   PHASE=3 + MOS_PHASE3_PERSIST=1
#                          writes hit disk.img directly. Legacy opt-in
#                          for editing settings; phase 9 supersedes.
#   PHASE=9                always writable + locked. The point of phase
#                          9 is interactive use that survives reboot.
if [ "$PHASE" = "0" ]; then
    mos_hw_disk_phase0_args "$DISK"
else
    MACHDD_OPTS="snapshot=on,file.locking=off"
    if [ "$PHASE" = "3" ] && [ "${MOS_PHASE3_PERSIST:-0}" = "1" ]; then
        # QEMU's default file.locking=on takes a real OFD lock on
        # disk.img — a second concurrent writer fails at startup. We
        # rely on that rather than a process-scan guard.
        MACHDD_OPTS=""
        echo "  MOS_PHASE3_PERSIST=1 — writes hit $DISK directly (file.locking on)."
    fi
    if [ "$PHASE" = "9" ]; then
        MACHDD_OPTS=""
        echo "  Phase 9 — writes hit $DISK directly (file.locking on)."
    fi
    mos_hw_disk_args "$OPENCORE" "$DISK" "$MACHDD_OPTS" ""
fi

echo "================================================================"
echo "  mos-docker test — phase $PHASE"
echo "    binary:      $QEMU_BIN ($("$QEMU_BIN" --version | head -1))"
echo "    disk:        $DISK"
echo "    serial log:  $SERIAL_LOG"
echo "    QMP socket:  $QMP_SOCK"
echo "    noVNC:       http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"

# Resolve numactl prefix (may be empty); echoes status into the banner.
mos_hw_numa_pin
echo "================================================================"

# Phase 4 is the M5 development stack — runs interactively without
# auto-pass/fail (visual verification on noVNC over a long session).
# Phases 0-3 are real regression tests: boot, watch the serial log for
# known pass/fail markers, exit 0/1/2 with a clear verdict.
#
# EXTERNAL_SUPERVISOR=1 disables the inner pass/fail supervisor below
# and just runs QEMU directly. test-runner.sh (./mos verify) sets this
# so the OUTER supervisor can poll serial for the actual login marker
# and take its own gold-diff screendump — without the inner supervisor
# matching an early-userland marker, powering down QEMU, and exiting
# the container before the screendump can fire (the bug behind the
# "screenshot: FAILED to capture" + verify-runner false-PASS that
# caused 2026-05-09 regression-test paralysis).
if [ "$PHASE" = "4" ] || [ "$PHASE" = "9" ] || [ "${EXTERNAL_SUPERVISOR:-0}" = "1" ]; then
    # shellcheck disable=SC2086  # NUMA_PIN is intentionally word-split.
    exec $NUMA_PIN "$QEMU_BIN" "${QEMU_ARGS[@]}"
fi

# --- Phase 0-3 supervisor ---
# The supervisor uses pipes (grep | head), backgrounded jobs, and
# command substitutions whose exit codes are NOT signal of failure.
# Disable strict mode for the rest of the script so an in-pipe SIGPIPE
# or a no-match grep doesn't tear the supervisor down before it can
# print a verdict.
set +e
set +o pipefail
case "$PHASE" in
    0)
        # OVMF sanity: with empty disk, OVMF iterates boot devices and falls
        # through to PXE. Either the boot-device-not-found message OR a UEFI
        # shell prompt proves OVMF is alive and reached the boot manager.
        PASS_RE='UEFI Interactive Shell|Shell>|EFI Shell version|BdsDxe: failed to load Boot|Start PXE over'
        FAIL_RE='ASSERT |MdeModulePkg.*ERROR'
        DEADLINE=60
        ;;
    1|2|3)
        # PASS = macOS reached the actual login window with a real PID. The
        # broader earlier regex (matching securityd / AirPlayXPCHelper /
        # AppleKeyStore session-uid early-userland markers) reported PASS
        # within 30s on a guest that subsequently panicked at mount-phase-2
        # before ever rendering the login screen — false positives that
        # masked a real boot regression. Only `loginwindow (<PID>)` proves
        # the kernel + launchd actually ran user-facing graphical login.
        PASS_RE='loginwindow \([0-9]+\)'
        # Catch the userspace panics (mount-phase-2 SIGABRT etc.) that
        # the broader matcher used to ignore.
        FAIL_RE='panic\(cpu |Debugger called|Unable to find driver for this platform|hfs_mountfs failed|kernel panic|"Sleeping"|userspace panic|boot task failure'
        DEADLINE=300
        ;;
esac

# Start QEMU in the background; cleanup() (above) tears it down on exit.
# shellcheck disable=SC2086  # NUMA_PIN is intentionally word-split.
$NUMA_PIN "$QEMU_BIN" "${QEMU_ARGS[@]}" &
QEMU_PID=$!

qmp_send() {
    [ -S "$QMP_SOCK" ] || return 0
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
        | socat - "UNIX-CONNECT:$QMP_SOCK" >/dev/null 2>&1 || true
}

# Capture a PNG screenshot via QMP screendump. Writes to
# /data/run/phase-${PHASE}-current.png (bind-mounted to host as
# data/run/phase-${PHASE}-current.png). Sign-off compare against the
# baselines/phase-${PHASE}-gold.png happens on the laptop side.
qmp_screendump() {
    local out="$1"
    [ -S "$QMP_SOCK" ] || return 0
    printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s","format":"png"}}\n' "$out" \
        | socat - "UNIX-CONNECT:$QMP_SOCK" >/dev/null 2>&1 || true
}

START=$(date +%s)
RESULT=
while :; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    # QEMU itself exited (crash, --version, etc.)?
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        RESULT="QEMU_EXIT"
        break
    fi

    if [ -f "$SERIAL_LOG" ]; then
        if grep -qE "$FAIL_RE" "$SERIAL_LOG" 2>/dev/null; then
            RESULT="FAIL"; break
        fi
        if grep -qE "$PASS_RE" "$SERIAL_LOG" 2>/dev/null; then
            RESULT="PASS"; break
        fi
    fi

    if [ "$ELAPSED" -ge "$DEADLINE" ]; then
        RESULT="TIMEOUT"; break
    fi

    sleep 2
done
ELAPSED=$(($(date +%s) - START))

echo "================================================================"
case "$RESULT" in
    PASS)
        MATCH=$(grep -oE "$PASS_RE" "$SERIAL_LOG" 2>/dev/null | head -1)
        echo "  ✓ PASS  phase $PHASE in ${ELAPSED}s — matched: ${MATCH}"
        # Let the screen settle a beat, then capture for sign-off compare.
        sleep 3
        SHOT="/data/run/phase-${PHASE}-current.png"
        qmp_screendump "$SHOT"
        if [ -s "$SHOT" ]; then
            echo "    screenshot: $SHOT ($(stat -c%s "$SHOT" 2>/dev/null) bytes)"
        else
            echo "    screenshot: FAILED to capture"
        fi
        qmp_send system_powerdown
        EXIT=0
        ;;
    FAIL)
        MATCH=$(grep -oE "$FAIL_RE" "$SERIAL_LOG" 2>/dev/null | head -1)
        echo "  ✗ FAIL  phase $PHASE in ${ELAPSED}s — matched: ${MATCH}"
        qmp_send quit
        EXIT=1
        ;;
    TIMEOUT)
        echo "  ✗ TIMEOUT  phase $PHASE — ${DEADLINE}s elapsed without pass marker"
        echo "    last log lines:"
        tail -5 "$SERIAL_LOG" 2>/dev/null | sed 's/^/      | /'
        qmp_send quit
        EXIT=2
        ;;
    QEMU_EXIT)
        echo "  ✗ QEMU_EXIT  phase $PHASE — QEMU died after ${ELAPSED}s"
        EXIT=3
        ;;
esac
echo "  serial log: $SERIAL_LOG"
echo "================================================================"

# Give QEMU up to 10s for graceful shutdown via QMP, then SIGKILL.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
kill -9 "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

exit $EXIT
