#!/bin/bash
# Inner script for test-magic-recovery-safe.sh — runs INSIDE the
# mos-docker:test container. Reads env vars passed via `docker run -e`
# and launches QEMU with a wall-clock timeout.
#
# Why this is a separate file (not a heredoc): the parent script tried
# to deliver this body via `docker run --detach -i ... bash -s <<EOF`,
# but `--detach` causes docker to return as soon as the container is
# created — the heredoc never finishes streaming to bash's stdin, so
# qemu was never launched. Mounting this file via `-v` and invoking it
# directly avoids the stdin-race entirely.

set -euo pipefail

: "${TS:?TS env var required}"
: "${QMP_SOCK_NAME:?QMP_SOCK_NAME env var required}"
: "${QEMU_TIMEOUT_SEC:?QEMU_TIMEOUT_SEC env var required}"
: "${GUEST_SMP:?GUEST_SMP env var required}"
: "${GUEST_MEM:?GUEST_MEM env var required}"
: "${KBD_DEVICE:?KBD_DEVICE env var required}"
: "${TABLET_DEVICE:?TABLET_DEVICE env var required}"
: "${RECOVERY_IMG:?RECOVERY_IMG env var required}"
: "${VNC_DISPLAY:=84}"
: "${VNC_PORT:=$(( 5900 + VNC_DISPLAY ))}"
: "${WEBSOCKIFY_PORT:=$(( 6000 + VNC_DISPLAY ))}"

SERIAL_LOG=/data/logs/test-magic-recovery-safe-${TS}.serial.log
SCREENSHOT=/data/logs/test-magic-recovery-safe-${TS}.png
QMP_SOCK=/data/run/${QMP_SOCK_NAME}
mkdir -p /data/logs /data/run
rm -f "$QMP_SOCK"

# Start websockify so the operator can hit
# http://docker.internal.pq.io:${WEBSOCKIFY_PORT}/vnc.html?autoconnect=1
# without any post-launch docker exec ceremony. websockify will fail to
# connect until QEMU's VNC server binds (a couple of seconds), but the
# noVNC client retries cleanly.
websockify --web=/usr/share/novnc \
    "0.0.0.0:${WEBSOCKIFY_PORT}" "127.0.0.1:${VNC_PORT}" \
    >/data/logs/test-magic-recovery-safe-${TS}.websockify.log 2>&1 &

echo "[guest-side] starting QEMU; timeout=${QEMU_TIMEOUT_SEC}s; KBD=${KBD_DEVICE} TABLET=${TABLET_DEVICE}"

(
    sleep $((QEMU_TIMEOUT_SEC - 10))
    if [ -S "$QMP_SOCK" ]; then
        {
            printf '%s\n' '{"execute":"qmp_capabilities"}'
            printf '%s\n' "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${SCREENSHOT}\"}}"
            sleep 1
        } | socat - UNIX-CONNECT:"$QMP_SOCK" 2>/dev/null || true
    fi
) &

rc=0
timeout --signal=TERM --kill-after=15 "$QEMU_TIMEOUT_SEC" \
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$GUEST_MEM" \
        -smp "${GUEST_SMP},cores=${GUEST_SMP}" \
        -machine q35 \
        -cpu host,vendor=GenuineIntel,vmware-cpuid-freq=on \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
        -smbios type=2 \
        -global ICH9-LPC.disable_s3=1 \
        -global ICH9-LPC.disable_s4=1 \
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
        -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc' \
        -device qemu-xhci,id=xhci \
        -device "$KBD_DEVICE",bus=xhci.0 \
        -device "$TABLET_DEVICE",bus=xhci.0 \
        -device ich9-ahci,id=sata \
        -drive id=OpenCoreBoot,if=none,format=raw,file=/magic-test/OpenCore.img,snapshot=on \
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
        -drive id=Recovery,if=none,format=raw,file=/magic-test/${RECOVERY_IMG},snapshot=on \
        -device virtio-blk-pci,drive=Recovery \
        -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on \
        -display none \
        -vnc "127.0.0.1:${VNC_DISPLAY},share=force-shared" \
        -chardev "file,id=serial_file,path=${SERIAL_LOG},append=off" \
        -serial chardev:serial_file \
        -qmp "unix:${QMP_SOCK},server=on,wait=off" \
        -no-reboot \
    || rc=$?

echo "[guest-side] QEMU exited rc=${rc}"
exit "${rc}"
