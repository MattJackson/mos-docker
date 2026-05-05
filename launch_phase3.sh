#!/bin/bash
# Phase 3 — Add Apple SMC OSK + apple-kbd / apple-tablet USB identity.
# Adds vs Phase 2:
#   -device isa-applesmc,osk=...       (Apple SMC with the OSK macOS expects)
#   -device apple-kbd  (replaces usb-kbd; Apple-USB descriptor wrapper)
#   -device apple-tablet (replaces usb-tablet)
#   -global ICH9-LPC.disable_s3=1 / disable_s4=1 / acpi-pci-hotplug-with-bridge-support=off
# Still uses vmware-vga (NOT apple-gfx-pci) — Phase 4 swaps the display.
# Pass: macOS login screen rendered via vmware-vga, noVNC at http://<host>:6083
set -euo pipefail
cd /opt/macos

LOG_DIR="${LOG_DIR:-/data/logs}"
RUN_DIR="${RUN_DIR:-/data/run}"
mkdir -p "${LOG_DIR}" "${RUN_DIR}"
NOVNC_PORT="${NOVNC_PORT:-6083}"
VNC_PORT="${VNC_PORT:-5903}"
VNC_DISPLAY=$((VNC_PORT - 5900))
SERIAL_LOG="${LOG_DIR}/serial-$(date +%Y%m%d-%H%M%S).log"
HMP_SOCK="${RUN_DIR}/qemu-monitor.sock"
QMP_SOCK="${RUN_DIR}/qemu-qmp.sock"
rm -f "${HMP_SOCK}" "${QMP_SOCK}"

IMAGE_PATH="${IMAGE_PATH:-/image}"
OPENCORE_IMG="${OPENCORE_IMG:-/opt/macos/OpenCore.img}"

[ -e "${IMAGE_PATH}" ]   || { echo "ERROR: macOS image missing at ${IMAGE_PATH}" >&2; exit 1; }
[ -d "${IMAGE_PATH}" ]   && { echo "ERROR: ${IMAGE_PATH} is a directory" >&2; exit 1; }
[ -f "${OPENCORE_IMG}" ] || { echo "ERROR: OpenCore.img missing at ${OPENCORE_IMG}" >&2; exit 1; }

CURRENT_SIZE=$(stat -Lc%s "${IMAGE_PATH}" 2>/dev/null || echo 0)
INSTALL_MEDIA=""
if [ "${CURRENT_SIZE}" -lt 1048576 ]; then
    qemu-img create -f raw "${IMAGE_PATH}" "${DISK_SIZE:-256G}"
    if [ -f /opt/macos/recovery.img ]; then
        INSTALL_MEDIA="-drive id=InstallMedia,if=none,file=/opt/macos/recovery.img,format=raw,snapshot=on -device ide-hd,bus=sata.3,drive=InstallMedia"
    fi
fi

echo "=== Phase 3 — patched + Apple identity (vmware-vga display) ==="
qemu-system-x86_64 --version | head -1
echo "noVNC: http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
echo "Serial log: ${SERIAL_LOG}"

websockify --web=/usr/share/novnc "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &

exec qemu-system-x86_64 \
    -enable-kvm \
    -m "${RAM:-8}G" \
    -cpu host,vendor=GenuineIntel,vmware-cpuid-freq=on \
    -machine q35 \
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
    -drive id=OpenCoreBoot,if=none,format=raw,file="${OPENCORE_IMG}",snapshot=on \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    ${INSTALL_MEDIA} \
    -drive id=MacHDD,if=none,file="${IMAGE_PATH}",format=raw,cache=none,aio=native \
    -device virtio-blk-pci,drive=MacHDD \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT:-22223}-:22 \
    -device e1000-82545em,netdev=net0 \
    -vga vmware \
    -display none \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    -serial file:"${SERIAL_LOG}" \
    -monitor unix:"${HMP_SOCK}",server,nowait \
    -qmp unix:"${QMP_SOCK}",server,nowait
