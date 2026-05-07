#!/bin/bash
# mos-docker test-magic-recovery-safe — gated macOS recovery boot for the
# `apple-magic-keyboard` (and apple-magic-tablet, when ready) device.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# An ad-hoc macOS-recovery test of the apple-magic-keyboard device on
# 2026-05-07 hung the docker host so hard it needed a reboot. This script
# is the post-mortem-corrected recipe: same workload, but with hard
# resource caps, a wall-clock time limit, and persistent container logs
# so a hang doesn't take down the host AND we get diagnostics out of it.
#
# DO NOT INVOKE THIS SCRIPT BLINDLY. Run test-magic-linux.sh first to
# prove the QEMU device's USB descriptors are protocol-correct under a
# Linux guest. Only then is it worth pointing macOS at it.
#
# SAFETY RAILS
# ------------
#   - --cpus=4               hard CPU cap (cgroup v2 cpu.max)
#   - --memory=4g            hard RSS cap (OOM-kills, not swaps)
#   - --memory-swap=4g       swap disabled for the container
#   - guest -smp 4 -m 4G     small guest, well under container ceiling
#   - timeout 300            5-minute wall-clock; QEMU SIGTERM'd after
#   - NO --rm                container survives so logs / serial / qmp
#                            captures are recoverable post-hang
#   - macOS disk: snapshot=on, NEVER snapshot=off — no disk corruption
#                 even if the guest panics mid-write
#   - serial + QMP captured to host-side files
#   - screenshot snapped near the end via QMP `screendump`
#   - NO `-v` boot-arg       (-v breaks recovery framebuffer; see
#                            memory/reference_verbose_boot_v_gotcha.md)
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Validates host data + image presence.
#   2. Launches a one-shot container with safety caps, named so we can
#      `docker logs` / `docker rm` it later.
#   3. Inside the container: boots macOS recovery via OpenCore with
#      apple-magic-keyboard + apple-tablet (or apple-magic-tablet
#      once that device exists) attached.
#   4. After 5 minutes (or until graceful exit), SIGTERM the QEMU and
#      pull the screenshot via QMP.
#   5. Leaves the container around with `docker rm` deferred to the
#      operator so logs survive.
#
# OUTPUTS (host-side)
#   /data/logs/test-magic-recovery-safe-<ts>.host.log    container stdout
#   /data/logs/test-magic-recovery-safe-<ts>.serial.log  guest serial
#   /data/run/test-magic-recovery-safe-<ts>.qmp.sock     QMP socket
#   /data/logs/test-magic-recovery-safe-<ts>.png         final screenshot
#
# DON'T RUN UNTIL test-magic-linux.sh IS GREEN.

set -euo pipefail

# ---- Tunables (env-overridable) ---------------------------------------
IMAGE="${MOS_TEST_IMAGE:-mos-docker:test}"
HOST_DATA="${HOST_MOS_DATA:-$HOME/mos-docker/data}"
# IMPORTANT: this script uses its OWN copies of OpenCore.img and
# recovery.img under $HOST_DATA/magic-test/, NOT the shared
# $HOST_DATA/{OpenCore,recovery}.img which are M5 development's
# working set. The script auto-creates the magic-test/ subdir and
# copies the images on first run; on subsequent runs it reuses
# them. Override the source directory with MOS_MAGIC_DATA= if you
# want to point elsewhere.
MAGIC_DATA="${MOS_MAGIC_DATA:-${HOST_DATA}/magic-test}"
RECOVERY_IMG="${MOS_RECOVERY_IMG:-recovery.img}"  # basename under MAGIC_DATA
KBD_DEVICE="${MOS_MAGIC_KBD:-apple-magic-keyboard}"
# apple-magic-tablet doesn't exist yet (only apple-magic-keyboard is in
# qemu-mos15 as of 2026-05-07). Fall back to upstream usb-tablet so the
# pointer works without dragging in the broken Package D apple-tablet.
TABLET_DEVICE="${MOS_MAGIC_TABLET:-usb-tablet}"

# Hard safety caps. Don't make these env-tunable.
CONTAINER_CPUS=4
CONTAINER_MEM=4g
GUEST_SMP=4
GUEST_MEM=4G
QEMU_TIMEOUT_SEC=300       # 5 minutes wall-clock

TS="$(date +%Y%m%d-%H%M%S)"
CONTAINER_NAME="mos-magic-recovery-${TS}"
LOG_DIR="${HOST_DATA}/logs"
RUN_DIR="${HOST_DATA}/run"
mkdir -p "${LOG_DIR}" "${RUN_DIR}"

HOST_LOG="${LOG_DIR}/test-magic-recovery-safe-${TS}.host.log"
SERIAL_LOG="${LOG_DIR}/test-magic-recovery-safe-${TS}.serial.log"
SCREENSHOT="${LOG_DIR}/test-magic-recovery-safe-${TS}.png"
QMP_SOCK_NAME="test-magic-recovery-safe-${TS}.qmp.sock"
QMP_SOCK_HOST="${RUN_DIR}/${QMP_SOCK_NAME}"

# ---- Pre-flight -------------------------------------------------------
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: docker image '${IMAGE}' not found locally." >&2
    echo "  Build it first:  docker compose -f compose.test.yml build" >&2
    exit 1
fi

# Stage MAGIC_DATA/ — our own copies of OpenCore.img + recovery.img
# so concurrent M5 development on $HOST_DATA/disk.img isn't disturbed
# by attaching the user's working set as our test inputs.
mkdir -p "${MAGIC_DATA}"
for src in OpenCore.img "${RECOVERY_IMG}"; do
    if [ ! -f "${HOST_DATA}/${src}" ]; then
        echo "ERROR: source ${HOST_DATA}/${src} missing." >&2
        echo "  Drop the file at \$HOST_MOS_DATA/${src}." >&2
        exit 1
    fi
    if [ ! -f "${MAGIC_DATA}/${src}" ] || \
       [ "${HOST_DATA}/${src}" -nt "${MAGIC_DATA}/${src}" ]; then
        echo "  Staging ${src} → ${MAGIC_DATA}/ (copy of ${HOST_DATA}/${src})"
        cp "${HOST_DATA}/${src}" "${MAGIC_DATA}/${src}.tmp"
        mv "${MAGIC_DATA}/${src}.tmp" "${MAGIC_DATA}/${src}"
    fi
done

# Sanity: refuse to attach disk.img. This script's whole point is to NOT
# put the macOS install at risk while we're debugging a host-hanging
# device. Recovery boots from recovery.img + OpenCore alone.
if [ -n "${ATTACH_DISK_IMG:-}" ]; then
    echo "ERROR: ATTACH_DISK_IMG is set. This script refuses to attach the" >&2
    echo "  precious /data/disk.img while debugging a device known to" >&2
    echo "  have hung the host. Boot recovery alone." >&2
    exit 1
fi

cat <<EOF
==========================================================
  test-magic-recovery-safe — safety rails active
    Container caps:   --cpus=${CONTAINER_CPUS} --memory=${CONTAINER_MEM} --memory-swap=${CONTAINER_MEM}
    Guest:            -smp ${GUEST_SMP} -m ${GUEST_MEM}
    Wall-clock cap:   ${QEMU_TIMEOUT_SEC}s
    Container name:   ${CONTAINER_NAME}  (NOT --rm; rm by hand after triage)
    Recovery image:   ${RECOVERY_IMG} (snapshot=on; no disk.img attached)
    Keyboard device:  ${KBD_DEVICE}
    Tablet device:    ${TABLET_DEVICE}  (apple-magic-tablet not yet in QEMU)
    Boot args:        production OpenCore (NO -v; recovery FB freezes with -v)

  Outputs (host-side):
    container stdout: ${HOST_LOG}
    guest serial:     ${SERIAL_LOG}
    QMP socket:       ${QMP_SOCK_HOST}
    final screenshot: ${SCREENSHOT}

  Triage commands (after this exits):
    docker logs ${CONTAINER_NAME}
    docker inspect ${CONTAINER_NAME}
    docker rm ${CONTAINER_NAME}      # only after you're done

==========================================================
EOF

# ---- Launch ----------------------------------------------------------
# We bind /data into the container so the serial/screenshot writes show
# up on the host directly. The QMP socket is also created under /data/run
# so the host can `socat` into it for live inspection if desired.
#
# Inner script delivered via stdin (`bash -s`) with a fully-quoted heredoc
# so embedded JSON / escaped quotes for QMP commands aren't mangled by
# the host shell. Variables that vary per-run are passed via `-e`.
docker run \
    --detach -i \
    --name "${CONTAINER_NAME}" \
    --cpus="${CONTAINER_CPUS}" \
    --memory="${CONTAINER_MEM}" \
    --memory-swap="${CONTAINER_MEM}" \
    --device /dev/kvm:/dev/kvm \
    -v "${HOST_DATA}:/data" \
    -v "${MAGIC_DATA}:/magic-test:ro" \
    -e "TS=${TS}" \
    -e "QMP_SOCK_NAME=${QMP_SOCK_NAME}" \
    -e "QEMU_TIMEOUT_SEC=${QEMU_TIMEOUT_SEC}" \
    -e "GUEST_SMP=${GUEST_SMP}" \
    -e "GUEST_MEM=${GUEST_MEM}" \
    -e "KBD_DEVICE=${KBD_DEVICE}" \
    -e "TABLET_DEVICE=${TABLET_DEVICE}" \
    -e "RECOVERY_IMG=${RECOVERY_IMG}" \
    --entrypoint /bin/bash \
    "${IMAGE}" \
    -s > "${HOST_LOG}" 2>&1 <<'EOF_INNER'
set -euo pipefail
SERIAL_LOG=/data/logs/test-magic-recovery-safe-${TS}.serial.log
SCREENSHOT=/data/logs/test-magic-recovery-safe-${TS}.png
QMP_SOCK=/data/run/${QMP_SOCK_NAME}
mkdir -p /data/logs /data/run
rm -f "$QMP_SOCK"

echo "[guest-side] starting QEMU; timeout=${QEMU_TIMEOUT_SEC}s"

# Background the screenshot grab: at T-10s, ask QMP for a screendump.
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
        -vnc 127.0.0.1:84 \
        -chardev "file,id=serial_file,path=${SERIAL_LOG},append=off" \
        -serial chardev:serial_file \
        -qmp "unix:${QMP_SOCK},server=on,wait=off" \
        -no-reboot \
    || rc=$?
echo "[guest-side] QEMU exited rc=${rc}"
EOF_INNER

echo "Container ${CONTAINER_NAME} launched (detached)."
echo ""
echo "Stream container logs:"
echo "  docker logs -f ${CONTAINER_NAME}"
echo ""
echo "Stream guest serial (host-side, live):"
echo "  tail -F ${SERIAL_LOG}"
echo ""
echo "noVNC port forward (run separately if you want to watch):"
echo "  docker exec ${CONTAINER_NAME} websockify --web=/usr/share/novnc 6084 127.0.0.1:5984 &"
echo ""
echo "When done (or after a hang):"
echo "  docker stop ${CONTAINER_NAME} || docker kill ${CONTAINER_NAME}"
echo "  docker logs ${CONTAINER_NAME} > ${HOST_LOG}.tail 2>&1"
echo "  ls -la ${SERIAL_LOG} ${SCREENSHOT}"
echo "  docker rm ${CONTAINER_NAME}"
echo ""
echo "Wall-clock cap is ${QEMU_TIMEOUT_SEC}s — the QEMU process inside"
echo "the container will be SIGTERM'd at T+${QEMU_TIMEOUT_SEC}s. The"
echo "container itself stays around so logs survive."
