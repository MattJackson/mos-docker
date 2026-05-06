#!/bin/bash
# mos-docker test — run a regression test phase (0..4).
#
# This script is in the TEST image only (mos-docker:test) — production
# images don't ship it. Test image extends production with the OEM
# unpatched QEMU binary alongside the patched one, so phases 1 (OEM) and
# 2 (patched) can be tested with a single image.
#
# Phase chain (each isolates ONE variable on top of the previous):
#   0  vanilla VNC test   - empty disk + OVMF + std-vga             - UEFI shell
#   1  OEM QEMU + OpenCore  - macOS image + OpenCore EFI            - OpenCore picker
#   2  patched QEMU         - same as 1, swap binary                - same picker (no regression)
#   3  + Apple identity     - +SMC OSK +apple-kbd +apple-tablet     - same picker (or macOS boots, if APFS)
#   4  + apple-gfx-pci      - production stack                      - black screen until M5 stage 20%
set -euo pipefail

PHASE="${1:-}"
case "$PHASE" in
    0|1|2|3|4) ;;
    *)
        echo "Usage: test <phase>"
        echo "  phase: 0..4 (0=vanilla, 4=production)"
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
HMP_SOCK="$RUN_DIR/qemu-monitor.sock"
QMP_SOCK="$RUN_DIR/qemu-qmp.sock"
rm -f "$HMP_SOCK" "$QMP_SOCK"

# Per-phase port offset (6080..6084) so phases can run alongside production.
NOVNC_PORT="608${PHASE}"
VNC_PORT="59$((PHASE * 1 + PHASE))"   # 5900,5901,5902,5903,5904
case "$PHASE" in
    0) VNC_PORT=5900 ;;
    1) VNC_PORT=5901 ;;
    2) VNC_PORT=5902 ;;
    3) VNC_PORT=5903 ;;
    4) VNC_PORT=5904 ;;
esac
VNC_DISPLAY=$((VNC_PORT - 5900))

# Pick the QEMU binary per phase.
QEMU_BIN=/usr/bin/qemu-system-x86_64
if [ "$PHASE" = "1" ]; then
    if [ -x /usr/bin/qemu-system-x86_64-oem ]; then
        QEMU_BIN=/usr/bin/qemu-system-x86_64-oem
    else
        echo "WARN: phase 1 requested but no /usr/bin/qemu-system-x86_64-oem found." >&2
        echo "  This image may be production-only (no OEM binary). Phase 1 will" >&2
        echo "  run against the patched binary, identical to phase 2." >&2
    fi
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
trap '[ -n "${NOVNC_BG:-}" ] && kill $NOVNC_BG 2>/dev/null || true' EXIT

# Per-phase QEMU args.
COMMON_ARGS=(
    -enable-kvm
    -m "${RAM:-4}G"
    -cpu host,vendor=GenuineIntel,vmware-cpuid-freq=on
    -machine q35
    -smp "${SMP:-4}",cores="${CORES:-4}"
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
)

# Display device: phase 4 = apple-gfx-pci, others = explicit VGA + EDID.
# Plain `-vga std` backs a smaller framebuffer than OpenCore advertises,
# so noVNC sees only the top-left quadrant of macOS's render surface.
# Specifying xres/yres + vgamem_mb + edid=on fixes that.
if [ "$PHASE" = "4" ]; then
    COMMON_ARGS+=( -vga none -device apple-gfx-pci )
    # Memfd backend required for apple-gfx-pci coherence.
    COMMON_ARGS+=( -object "memory-backend-memfd,id=mem,size=${RAM:-4}G,share=on" )
    COMMON_ARGS+=( -global "ICH9-LPC.disable_s3=1" -global "ICH9-LPC.disable_s4=1" )
else
    COMMON_ARGS+=( -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on )
fi

# USB / Apple identity: phase 3+ = apple-*; otherwise = generic.
if [ "$PHASE" -ge 3 ]; then
    COMMON_ARGS+=(
        -device qemu-xhci,id=xhci
        -device apple-kbd,bus=xhci.0
        -device apple-tablet,bus=xhci.0
        -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
    )
else
    COMMON_ARGS+=(
        -device qemu-xhci,id=xhci
        -device usb-kbd,bus=xhci.0
        -device usb-tablet,bus=xhci.0
    )
fi

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
        -drive "id=MacHDD,if=none,file=$DISK,format=raw,cache=none,aio=native"
        -device virtio-blk-pci,drive=MacHDD
    )
fi

echo "================================================================"
echo "  mos-docker test — phase $PHASE"
echo "    binary:      $QEMU_BIN ($("$QEMU_BIN" --version | head -1))"
echo "    disk:        $DISK"
echo "    serial log:  $SERIAL_LOG"
echo "    noVNC:       http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
echo "================================================================"

exec "$QEMU_BIN" "${COMMON_ARGS[@]}"
