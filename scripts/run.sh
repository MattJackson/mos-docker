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

# --- Display device selection ----------------------------------------
# Default: explicit -device VGA with synthesized EDID. The plain `-vga std`
# default backs a smaller framebuffer than what OpenCore advertises during
# boot, so noVNC ends up showing only the top-left quadrant of macOS's
# render surface ("logo bottom-right" rendering quirk seen 2026-05-06).
#
# Specifying xres/yres + vgamem_mb tells std-vga to back the full
# 1920x1080x4bpp framebuffer up front (default 16M is borderline; 64M gives
# headroom for HiDPI / 2560x1600). edid=on synthesizes an EDID so macOS
# reads the proper screen size + refresh rate instead of guessing.
#
# Apple paravirt GPU (`-vga none -device apple-gfx-pci`) is the future
# production target but requires libapplegfx-vulkan opcode handlers
# (M5 stage 20%) — until those land, the device renders nothing
# (you see "Guest has not initialized the display"). Opt in with
# MOS_USE_APPLE_GFX_PCI=1 only when you're testing the M5 path.
DISPLAY_ARGS="-device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on"
MEM_BACKEND_ARGS=""
RAM_GB="${RAM:-8}"
if [ "${MOS_USE_APPLE_GFX_PCI:-0}" = "1" ]; then
    GPU_CORES_RAW="${GPU_CORES:-0}"
    APPLE_GFX_DEVICE="-device apple-gfx-pci"
    if [[ "$GPU_CORES_RAW" =~ ^[0-9]+$ ]] && [ "$GPU_CORES_RAW" -gt 0 ]; then
        APPLE_GFX_DEVICE="-device apple-gfx-pci,gpu_cores=$GPU_CORES_RAW"
    fi
    DISPLAY_ARGS="-vga none $APPLE_GFX_DEVICE"
    # apple-gfx-pci needs memfd memory backend for the mremap-alias path.
    MEM_BACKEND_ARGS="-object memory-backend-memfd,id=mem,size=${RAM_GB}G,share=on -machine memory-backend=mem"
    echo "WARNING: MOS_USE_APPLE_GFX_PCI=1 — display will likely be blank"
    echo "  until libapplegfx-vulkan opcode handlers are implemented (M5)."
fi

# --- Networking: macvtap + virtio-net-pci (known-good for macOS) ------
# macOS's recovery + production stack expects bridged networking with a
# real LAN IP. user-mode (slirp) doesn't satisfy macOS's network-detect
# UX even though it'd technically NAT. Fall back to slirp only when no
# physical interface is available (CI / developer laptop).
#
# Auto-detect HOST_IFACE if not explicitly set: pick the first UP
# physical NIC, skipping virtual interfaces (lo, docker, br-, veth,
# macvtap, virbr, tailscale).
if [ -z "${HOST_IFACE:-}" ]; then
    # awk's `exit` triggers SIGPIPE in `ip` -> `set -o pipefail` would kill
    # the script. Disable pipefail just for this pipeline.
    HOST_IFACE="$(set +o pipefail; ip -br link show 2>/dev/null | \
        awk '$1 !~ /^(lo|docker|br-|veth|macvtap|virbr|tailscale)/ && \
             $1 != "" && $2 == "UP" {print $1; exit}')"
fi

if [ -n "${HOST_IFACE:-}" ] && ip link show "$HOST_IFACE" >/dev/null 2>&1; then
    echo "Networking: macvtap bridge over $HOST_IFACE (VM gets real LAN IP)"
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
else
    echo "Networking: WARN no physical NIC detected — falling back to user-mode (slirp)."
    echo "  macOS recovery may report 'no internet' even though NAT works."
    echo "  Set HOST_IFACE=<name> to use macvtap (recommended)."
    NETDEV_ARGS="-netdev user,id=net0,hostfwd=tcp::${SSH_PORT:-22220}-:22 -device virtio-net-pci,netdev=net0"
fi

# --- MacHDD persistence mode ----------------------------------------
# Default: snapshot=on (writes go to a per-run overlay in QEMU's tmp;
# disk.img stays read-only; overlay vanishes on container exit). This
# protects the install from drift during dev iteration, and matches the
# "never auto-destroy operator state" principle.
#
# MOS_PERSIST=1 → snapshot=off; writes hit disk.img directly. Set this
# when you actually want changes to survive (e.g. installing software
# in macOS that you want to keep across runs). install.sh sets this
# automatically.
MACHDD_SNAPSHOT="snapshot=on,"
if [ "${MOS_PERSIST:-0}" = "1" ]; then
    MACHDD_SNAPSHOT=""
fi

echo "================================================================"
echo "  mos-docker — booting macOS"
echo "    disk:        $DISK ($(numfmt --to=iec "$DISK_SIZE"))"
echo "    persist:     $([ "${MOS_PERSIST:-0}" = "1" ] && echo "YES (writes hit disk.img)" || echo "no (snapshot=on; writes ephemeral)")"
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
    $MEM_BACKEND_ARGS \
    -cpu "${CPU_MODEL:-host}",vendor=GenuineIntel,vmware-cpuid-freq=on \
    -machine q35,accel=kvm \
    -smp "${SMP:-4}",cores="${CORES:-4}" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
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
    -drive id=MacHDD,if=none,file="$DISK",format=raw,cache=none,aio=native,${MACHDD_SNAPSHOT}\
    -device virtio-blk-pci,drive=MacHDD \
    $NETDEV_ARGS \
    -chardev file,id=serial_file,path="$SERIAL_LOG",append=off \
    -serial chardev:serial_file \
    -chardev socket,id=hmp_sock,path="$HMP_SOCK",server=on,wait=off \
    -monitor chardev:hmp_sock \
    -qmp unix:"$QMP_SOCK",server=on,wait=off \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    $DISPLAY_ARGS \
    ${EXTRA:-}
