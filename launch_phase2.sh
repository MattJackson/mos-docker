#!/bin/bash
# Phase 2 — Same launcher as Phase 1; only the QEMU binary differs.
# The mos15-patched binary now in /usr/bin/qemu-system-x86_64 adds:
#   - patched applesmc.c (functional SMC backend)
#   - patched dev-hid.c (Apple-USB descriptor wrappers)
#   - patched vmware_vga.c (modernized timing/VRAM)
#   - apple-gfx-pci-linux.c device (NOT enabled this phase)
# We do NOT yet pass -device isa-applesmc, -device apple-kbd, etc. — those
# come in Phase 3. This phase only proves the patched binary doesn't break
# the OpenCore stage.
# Pass: identical visual to Phase 1. noVNC at http://<host>:6082
set -euo pipefail
cd /opt/macos

LOG_DIR="${LOG_DIR:-/data/logs}"
RUN_DIR="${RUN_DIR:-/data/run}"
mkdir -p "${LOG_DIR}" "${RUN_DIR}"
NOVNC_PORT="${NOVNC_PORT:-6082}"
VNC_PORT="${VNC_PORT:-5902}"
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

echo "=== Phase 2 — mos15-patched 10.2.2 + OpenCore (no Apple identity) ==="
qemu-system-x86_64 --version | head -1
qemu-system-x86_64 -device help 2>&1 | grep -q '^name "apple-gfx-pci"' \
    && echo "✓ patched binary detected (apple-gfx-pci device available, NOT enabled)" \
    || { echo "ERROR: this image lacks the patched QEMU binary" >&2; exit 1; }
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
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -smbios type=2 \
    -device ich9-ahci,id=sata \
    -drive id=OpenCoreBoot,if=none,format=raw,file="${OPENCORE_IMG}",snapshot=on \
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
    ${INSTALL_MEDIA} \
    -drive id=MacHDD,if=none,file="${IMAGE_PATH}",format=raw,cache=none,aio=native \
    -device virtio-blk-pci,drive=MacHDD \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT:-22222}-:22 \
    -device e1000-82545em,netdev=net0 \
    -vga vmware \
    -display none \
    -vnc 127.0.0.1:${VNC_DISPLAY} \
    -serial file:"${SERIAL_LOG}" \
    -monitor unix:"${HMP_SOCK}",server,nowait \
    -qmp unix:"${QMP_SOCK}",server,nowait
