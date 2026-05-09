#!/bin/bash
# mos-docker test — run a regression test phase (0..4).
#
# This script is in the TEST image only (mos-docker:test) — production
# images don't ship it. The test image extends production with the OEM
# unpatched QEMU binary alongside the patched one, so phase 1 (OEM) and
# phase 2 (patched) can be tested with a single image.
#
# Phase chain (each isolates ONE variable on top of the previous):
#   0  bare QEMU + OVMF + std-vga + empty disk         sanity (UEFI shell)
#   1  OEM QEMU + macOS HD + std-vga + isa-applesmc  [TRANSIENT — drops when
#       + ICH9 globals + usb-kbd                       our QEMU patches land
#                                                      upstream; OEM and
#                                                      patched then converge]
#                                                      bare-min stock-QEMU
#                                                      stack that boots to
#                                                      the macOS login screen
#   2  patched QEMU + same args                        binary swap (proves
#                                                      patches don't regress
#                                                      the bare-min login)
#   3  + usb-kbd / usb-tablet (Apple HID via apple-magic-keyboard pending)                      Apple HID identity at
#                                                      the QEMU emulation
#                                                      level (cosmetic vs
#                                                      generic usb-kbd)
#   4  + apple-gfx-pci paravirt GPU                    THE ACTUAL MOS PRODUCT
#       (replaces std-vga; needs memfd backend         (currently black until
#       for coherence)                                 libapplegfx-vulkan
#                                                      opcode handlers ship;
#                                                      M5 stage 20% gate)
#
# End-state chain (after upstream merges retire phase 1):
#   0 sanity → 1 patched-baseline → 2 apple-gfx-pci product.
#
# isa-applesmc + ICH9 globals (disable_s3, disable_s4, acpi-pci-hotplug-with-
# bridge-support=off) are the bare minimum macOS Sequoia needs to boot past
# AppleACPICPU power-management waits. Without them macOS hangs in repeated
# busy timeouts (60s, 60s, 60s, 240s) and never reaches login. They're
# present from Phase 1 onward.
set -euo pipefail

PHASE="${1:-}"
case "$PHASE" in
    0|1|2|3|4) ;;
    *)
        echo "Usage: test <phase>" >&2
        echo "  phase: 0..4 (0=sanity, 4=production paravirt)" >&2
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

# Per-phase port offset (6080..6084) so phases can run alongside production.
NOVNC_PORT="608${PHASE}"
VNC_PORT=$((5900 + PHASE))
VNC_DISPLAY=$((VNC_PORT - 5900))

# Pick the QEMU binary per phase. No silent fallback — predictable tests
# require the right binary or hard-fail.
QEMU_BIN=/usr/bin/qemu-system-x86_64
if [ "$PHASE" = "1" ]; then
    if [ ! -x /usr/bin/qemu-system-x86_64-oem ]; then
        echo "ERROR: phase 1 requires /usr/bin/qemu-system-x86_64-oem (OEM unpatched binary)." >&2
        echo "  This image is missing it — likely a production-only image. Rebuild with" >&2
        echo "  Dockerfile.test (which installs both binaries)." >&2
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
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Per-phase QEMU args.
COMMON_ARGS=(
    -enable-kvm
    -m "${RAM:-8}G"
    -cpu host,vendor=GenuineIntel,vmware-cpuid-freq=on
    -machine q35
    -smp "${SMP:-8}",cores="${CORES:-8}"
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd
    -smbios type=2
    -netdev "user,id=net0,hostfwd=tcp::$((22220 + PHASE))-:22"
    -device e1000-82545em,netdev=net0
    -display none
    -vnc 127.0.0.1:${VNC_DISPLAY}
    -serial file:"$SERIAL_LOG"
    -monitor unix:"$HMP_SOCK",server,nowait
    -qmp unix:"$QMP_SOCK",server,nowait
    -d guest_errors,-exec
)

# Display device per phase:
#   0,1,2,3 → std-vga (-device VGA + EDID).  Plain `-vga std` gives a smaller
#             framebuffer than OpenCore advertises, which makes noVNC see only
#             the top-left quadrant of macOS's render surface. xres/yres +
#             vgamem_mb + edid=on fixes that.
#   4       → apple-gfx-pci (-vga none -device apple-gfx-pci). The product.
#             Needs memfd memory backend for coherence + ICH9 sleep-state
#             quiet (already added below for Phase >= 1).
if [ "$PHASE" = "4" ]; then
    COMMON_ARGS+=( -vga none -device apple-gfx-pci )
    COMMON_ARGS+=( -object "memory-backend-memfd,id=mem,size=${RAM:-8}G,share=on" )
else
    COMMON_ARGS+=( -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on )
fi

# isa-applesmc + ICH9 globals are bare-min for macOS to boot past
# AppleACPICPU. Always present from Phase 1 onward (Phase 0 doesn't boot
# macOS so doesn't need them).
if [ "$PHASE" -ge 1 ]; then
    COMMON_ARGS+=(
        -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
    )
fi

# USB HID — env-tunable. Defaults to generic usb-kbd / usb-tablet so
# existing phase-3 baseline behaviour is unchanged. Override to exercise
# the Apple-vendor-HID emulators (`apple-magic-keyboard` PID 0x026c /
# `apple-magic-tablet` PID 0x0265) as the regression gate before a
# downstream switch in run.sh / install.sh:
#
#     KBD_DEVICE=apple-magic-keyboard \
#     TABLET_DEVICE=apple-magic-tablet \
#     ./mos verify 3
#
# A green phase-3 under those overrides is the green light to flip the
# install/run path. A red phase-3 is a regression that blocks the flip.
KBD_DEVICE="${KBD_DEVICE:-usb-kbd}"
TABLET_DEVICE="${TABLET_DEVICE:-usb-tablet}"
COMMON_ARGS+=(
    -device qemu-xhci,id=xhci
    -device "${KBD_DEVICE},bus=xhci.0"
    -device "${TABLET_DEVICE},bus=xhci.0"
)

# Disk attach: phase 0 has just empty disk, phases 1-4 have macOS + OpenCore.
if [ "$PHASE" = "0" ]; then
    COMMON_ARGS+=(
        -drive "id=disk0,if=none,file=$DISK,format=raw"
        -device virtio-blk-pci,drive=disk0
    )
else
    COMMON_ARGS+=(
        -device ich9-ahci,id=sata
        -drive "id=OpenCoreBoot,if=none,format=raw,file=$OPENCORE,snapshot=on"
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot
        # file.locking=off lets phases run concurrently with each other +
        # with prod. Safe ONLY because snapshot=on (just below) sends every
        # write to a per-run RAM overlay; the underlying disk.img is never
        # mutated. If you ever remove snapshot=on here, restore locking or
        # you will silently corrupt disk.img when two phases (or prod) run
        # at once. test.sh deliberately doesn't honor MOS_PERSIST.
        -drive "id=MacHDD,if=none,file=$DISK,format=raw,cache=none,aio=native,snapshot=on,file.locking=off"
        -device virtio-blk-pci,drive=MacHDD
    )
fi

echo "================================================================"
echo "  mos-docker test — phase $PHASE"
echo "    binary:      $QEMU_BIN ($("$QEMU_BIN" --version | head -1))"
echo "    disk:        $DISK"
echo "    serial log:  $SERIAL_LOG"
echo "    QMP socket:  $QMP_SOCK"
echo "    noVNC:       http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
echo "================================================================"

# Phase 4 is the M5 development stack — runs interactively without
# auto-pass/fail (visual verification on noVNC over a long session).
# Phases 0-3 are real regression tests: boot, watch the serial log for
# known pass/fail markers, exit 0/1/2 with a clear verdict.
if [ "$PHASE" = "4" ]; then
    exec "$QEMU_BIN" "${COMMON_ARGS[@]}"
fi

# --- Phase 0-3 supervisor ---
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
        # macOS boot to login screen — detected via late-userland services
        # appearing in the kernel log. Any of these markers means userspace
        # has reached login window or beyond.
        PASS_RE='AirPlayXPCHelper|AppleKeyStore.*session uid|WindowServer|loginwindow|securityd|mDNSResponder'
        FAIL_RE='panic\(cpu |Debugger called|Unable to find driver for this platform|hfs_mountfs failed|kernel panic|"Sleeping"'
        DEADLINE=300
        ;;
esac

# Start QEMU in the background; cleanup() (above) tears it down on exit.
"$QEMU_BIN" "${COMMON_ARGS[@]}" &
QEMU_PID=$!

qmp_send() {
    [ -S "$QMP_SOCK" ] || return 0
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
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
