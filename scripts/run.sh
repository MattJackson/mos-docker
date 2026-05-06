#!/bin/bash
# mos-docker run — boot the installed macOS.
#
# Production launcher. Refuses to start if /data/disk.img is missing or
# looks empty. NEVER calls qemu-img create on the data disk.
set -euo pipefail

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

if [ ! -f "$OPENCORE" ]; then
    echo "ERROR: $OPENCORE does not exist." >&2
    echo "  Drop an OpenCore EFI image at \$HOST_MOS_DATA/OpenCore.img." >&2
    echo "  Build instructions: SETUP.md" >&2
    exit 1
fi

# --- Boot diagnostics setup -------------------------------------------
LOG_DIR="$DATA/logs"
RUN_DIR="$DATA/run"
mkdir -p "$LOG_DIR" "$RUN_DIR"
BOOT_TS="$(date +%Y%m%d-%H%M%S)"
SERIAL_LOG="$LOG_DIR/serial-${BOOT_TS}.log"
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
    INSTALL_MEDIA="-drive id=InstallMedia,if=none,file=$MOS_QEMU_INSTALL_MEDIA,format=raw,snapshot=on -device ide-hd,bus=sata.3,drive=InstallMedia"
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

# --- apple-gfx-pci gpu_cores plumbing ---------------------------------
GPU_CORES_RAW="${GPU_CORES:-0}"
APPLE_GFX_DEVICE="-device apple-gfx-pci"
if [[ "$GPU_CORES_RAW" =~ ^[0-9]+$ ]] && [ "$GPU_CORES_RAW" -gt 0 ]; then
    APPLE_GFX_DEVICE="-device apple-gfx-pci,gpu_cores=$GPU_CORES_RAW"
fi

# --- Memory backend (memfd required for apple-gfx-pci coherence) ------
RAM_GB="${RAM:-8}"
MEM_BACKEND="memory-backend-memfd,id=mem,size=${RAM_GB}G,share=on"

# --- Networking: prefer user-mode unless HOST_IFACE+macvtap requested -
NETDEV_ARGS="-netdev user,id=net0,hostfwd=tcp::${SSH_PORT:-22220}-:22 \
             -device e1000-82545em,netdev=net0"
if [ -n "${HOST_IFACE:-}" ]; then
    if ! ip link show "$HOST_IFACE" >/dev/null 2>&1; then
        echo "ERROR: HOST_IFACE='$HOST_IFACE' not found inside container." >&2
        ip -br link show >&2
        exit 1
    fi
    ip link del macvtap0 2>/dev/null || true
    ip link add link "$HOST_IFACE" name macvtap0 type macvtap mode bridge
    ip link set macvtap0 allmulticast on
    ip link set macvtap0 up
    IFX=$(cat /sys/class/net/macvtap0/ifindex)
    TAP_DEV="/dev/tap${IFX}"
    if [ ! -e "$TAP_DEV" ]; then
        mknod "$TAP_DEV" c \
            $(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f1) \
            $(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f2)
    fi
    MAC=$(cat /sys/class/net/macvtap0/address)
    exec 3<>"$TAP_DEV"
    NETDEV_ARGS="-netdev tap,id=net0,fd=3 -device virtio-net-pci,netdev=net0,mac=$MAC"
fi

echo "================================================================"
echo "  mos-docker — booting macOS"
echo "    disk:        $DISK ($(numfmt --to=iec "$DISK_SIZE"))"
echo "    OpenCore:    $OPENCORE"
echo "    serial log:  $SERIAL_LOG"
echo "    HMP socket:  $HMP_SOCK"
echo "    QMP socket:  $QMP_SOCK"
[ -n "$INSTALL_MEDIA" ] && echo "    install:     $MOS_QEMU_INSTALL_MEDIA"
echo "================================================================"

# Cleanup websockify on exit
trap '[ -n "$NOVNC_BG" ] && kill $NOVNC_BG 2>/dev/null || true' EXIT

exec qemu-system-x86_64 \
    -enable-kvm \
    -m "${RAM_GB}G" \
    -object "$MEM_BACKEND" \
    -cpu "${CPU_MODEL:-host}",vendor=GenuineIntel,vmware-cpuid-freq=on \
    -machine q35,accel=kvm,memory-backend=mem \
    -smp "${SMP:-4}",cores="${CORES:-4}" \
    -device qemu-xhci,id=xhci \
    -device apple-kbd,bus=xhci.0 \
    -device apple-tablet,bus=xhci.0 \
    -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc' \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    -smbios type=2 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCoreBoot,if=none,format=raw,file="$OPENCORE",snapshot=on \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    $INSTALL_MEDIA \
    -drive id=MacHDD,if=none,file="$DISK",format=raw,cache=none,aio=native \
    -device virtio-blk-pci,drive=MacHDD \
    $NETDEV_ARGS \
    -chardev file,id=serial_file,path="$SERIAL_LOG",append=off \
    -serial chardev:serial_file \
    -chardev socket,id=hmp_sock,path="$HMP_SOCK",server=on,wait=off \
    -monitor chardev:hmp_sock \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    -vga none \
    $APPLE_GFX_DEVICE \
    ${EXTRA:-}
