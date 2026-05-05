#!/bin/bash
# Phase 0 — Vanilla VNC sanity check.
# QEMU + OVMF + empty raw disk. NO macOS, NO OpenCore, NO patches, NO
# apple-gfx-pci. Boots to UEFI shell after no bootable device is found.
# Pass: UEFI shell rendered through noVNC at http://<host>:6080
set -euo pipefail
cd /opt/macos

LOG_DIR="${LOG_DIR:-/data/logs}"
RUN_DIR="${RUN_DIR:-/data/run}"
mkdir -p "${LOG_DIR}" "${RUN_DIR}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_DISPLAY=$((VNC_PORT - 5900))
SERIAL_LOG="${LOG_DIR}/serial-$(date +%Y%m%d-%H%M%S).log"
HMP_SOCK="${RUN_DIR}/qemu-monitor.sock"
QMP_SOCK="${RUN_DIR}/qemu-qmp.sock"
rm -f "${HMP_SOCK}" "${QMP_SOCK}"

EMPTY_DISK="${RUN_DIR}/phase0-empty.img"
if [ ! -f "${EMPTY_DISK}" ]; then
    qemu-img create -f raw "${EMPTY_DISK}" 1G
fi

echo "=== Phase 0 — vanilla VNC test ==="
qemu-system-x86_64 --version | head -1
echo "noVNC: http://0.0.0.0:${NOVNC_PORT}/vnc.html?autoconnect=1"
echo "Serial log: ${SERIAL_LOG}"

websockify --web=/usr/share/novnc "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &

exec qemu-system-x86_64 \
    -enable-kvm \
    -m "${RAM:-2}G" \
    -cpu host \
    -machine q35 \
    -smp "${SMP:-2}" \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -drive id=disk0,if=none,file="${EMPTY_DISK}",format=raw \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -vga vmware \
    -display none \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    -serial file:"${SERIAL_LOG}" \
    -monitor unix:"${HMP_SOCK}",server,nowait \
    -qmp unix:"${QMP_SOCK}",server,nowait
