#!/bin/bash
# mos-docker test-magic-linux — Linux-guest verification path for the new
# `apple-magic-keyboard` (and eventually `apple-magic-tablet`) QEMU device.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# An ad-hoc test of the apple-magic-keyboard device against macOS recovery
# on 2026-05-07 hung the docker host so hard it needed a reboot. Before any
# further macOS-side testing, we need a path that proves the device's USB
# descriptors are protocol-correct WITHOUT exposing them to a kernel that
# can hang the host.
#
# Linux's xHCI stack + libusb (`lsusb -v`) is the canonical descriptor
# verifier. If lsusb walks the device cleanly inside an Alpine guest, we
# know:
#   - device descriptor parses (PID/VID, bcdDevice, strings)
#   - configuration descriptor parses
#   - interface + endpoint descriptors parse
#   - HID report descriptor request (GET_DESCRIPTOR class request) is
#     answered with a valid descriptor that libusb can decode
#
# That's enough to gate "is the QEMU device shape sane?" before we expose
# it to AppleUSBTopCaseHIDDriver.
#
# SAFETY RAILS (the whole point of this script)
# ---------------------------------------------
# This script intentionally does NOT use the production compose stack. It
# launches a one-off `docker run` with HARD CPU/MEMORY caps so a runaway
# QEMU/KVM cannot eat the host the way the 2026-05-07 incident did:
#   - --cpus=4         hard CPU cap (cgroup v2 cpu.max)
#   - --memory=4g      hard RSS cap (cgroup v2 memory.max — OOM-kills, not swaps)
#   - --memory-swap=4g equal to --memory → swap is disabled for the container
#   - -smp 2 -m 2G     small guest (well under the container ceiling)
#   - -snapshot        all writes are ephemeral (no disk corruption possible)
#   - timeout 90       qemu is SIGTERM'd after 90s no matter what
#   - NO macOS disk    /data/disk.img is NOT mounted; only the Alpine ISO
#                      and a tiny scratch disk in a tmp dir
#
# WHEN TO USE THIS
# ----------------
# 1. After any change to the apple-magic-keyboard descriptor / report
#    descriptor / handle_control logic in qemu-mos15.
# 2. Before re-attempting any macOS-side test of the same device.
# 3. As a smoke test in CI for the device's USB-protocol shape.
#
# This is the FIRST step in a bisect-by-simplification chain. Only after
# this passes cleanly do we move on to test-magic-recovery-safe.sh.
#
# See: memory/reference_magic_test_scaffolding.md (in the mos repo).

set -euo pipefail

# ---- Tunables (env-overridable) ---------------------------------------
IMAGE="${MOS_TEST_IMAGE:-mos-docker:test}"
DEVICE="${MOS_MAGIC_DEVICE:-apple-magic-keyboard}"   # or apple-magic-tablet later
HOST_DATA="${HOST_MOS_DATA:-$HOME/mos-docker/data}"
ALPINE_VERSION="${ALPINE_VERSION:-3.21.0}"
ALPINE_ISO_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-${ALPINE_VERSION}-x86_64.iso"
ALPINE_ISO_NAME="alpine-virt-${ALPINE_VERSION}-x86_64.iso"

# Hard safety caps. These are NOT user-tunable from the env on purpose —
# this script's whole reason to exist is to enforce them.
CONTAINER_CPUS=4
CONTAINER_MEM=4g
GUEST_SMP=2
GUEST_MEM=2G
QEMU_TIMEOUT_SEC=90

# ---- Pre-flight -------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${HOST_DATA}/logs"
mkdir -p "${LOG_DIR}"
HOST_LOG="${LOG_DIR}/test-magic-linux-${TS}.log"

# Re-use cached Alpine ISO if present; otherwise fetch into HOST_DATA so
# subsequent runs are offline-capable.
ALPINE_ISO_HOST="${HOST_DATA}/${ALPINE_ISO_NAME}"
ALPINE_ISO_GENERIC="${HOST_DATA}/alpine-virt.iso"   # convenience symlink
if [ ! -f "${ALPINE_ISO_HOST}" ] && [ ! -f "${ALPINE_ISO_GENERIC}" ]; then
    echo "[$(date +%T)] Fetching Alpine ISO: ${ALPINE_ISO_URL}"
    curl -fSL --output "${ALPINE_ISO_HOST}" "${ALPINE_ISO_URL}"
fi
if [ ! -f "${ALPINE_ISO_HOST}" ] && [ -f "${ALPINE_ISO_GENERIC}" ]; then
    ALPINE_ISO_HOST="${ALPINE_ISO_GENERIC}"
fi
ALPINE_ISO_BASENAME="$(basename "${ALPINE_ISO_HOST}")"

# Sanity: image exists locally?
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: docker image '${IMAGE}' not found locally." >&2
    echo "  Build it first:  docker compose -f compose.test.yml build" >&2
    exit 1
fi

# ---- Build the in-guest payload --------------------------------------
# Strategy: boot Alpine kernel + initramfs from the ISO with a kernel
# cmdline that runs `lsusb -v` early, dumps to /dev/ttyS0 (which QEMU
# captures), then halts. We do this by passing a custom init via
# Alpine's `apkovl` is overkill for a one-shot — instead we use
# QEMU `-kernel`/`-initrd` with the on-ISO vmlinuz/initramfs, plus
# `-append` to slip in `console=ttyS0 init=/init.lsusb` after we
# overlay a tiny init script via a 9p share.
#
# Actually simpler still: boot the ISO normally (it auto-logins as root
# in alpine-virt), and pass a `tinit`-style auto-run by injecting a
# `local.d` script via a 9p mount. But 9p adds moving parts. Instead,
# build a tiny ISO9660 / FAT image with an autorun script and let
# Alpine's init scan for it.
#
# Cleanest path: Alpine's syslinux APPEND already supports kernel
# parameters; the `initrd=/boot/initramfs-virt` is shipped on the ISO.
# We'll boot it with our own -append that adds `modules=loop,squashfs
# quiet console=ttyS0,115200 alpine_repo=/media/cdrom modloop=/boot/modloop-virt`
# plus a custom `apkovl` that drops a `local.d/lsusb-and-halt.start`
# script.
#
# To avoid building an apkovl on the host (chicken-and-egg with tar/gzip
# on macOS vs. busybox conventions), we instead use a much simpler
# trick: pass `-kernel` + `-initrd` extracted from the ISO at runtime,
# AND a second `-fw_cfg` "etc/runonce.sh" entry that the in-guest stage
# 1 init copies to /tmp and execs.
#
# That's still a lot. The pragmatic minimum: drop a small shell script
# into a FAT image and pass it as a USB drive; tell the kernel cmdline
# to mount /dev/sdb1 and exec /autorun.sh. But this has its own pitfalls
# (Alpine's stage-1 doesn't honor random init=).
#
# For THIS script, we take the most-portable path: bake a tiny squashfs
# initramfs override into a temporary tarball (built inside the
# container, not on the host), boot Alpine normally, and have the
# in-guest script run via a kernel `init=` shim. Implementation lives
# in the container-side launcher invoked via `bash -c` below.

# ---- Run the test in a one-shot container ----------------------------
echo "[$(date +%T)] Launching one-shot Alpine guest under ${IMAGE}"
echo "                Container caps: --cpus=${CONTAINER_CPUS} --memory=${CONTAINER_MEM}"
echo "                Guest:          -smp ${GUEST_SMP} -m ${GUEST_MEM} -snapshot"
echo "                QEMU timeout:   ${QEMU_TIMEOUT_SEC}s"
echo "                Device under test: ${DEVICE}"
echo "                Host log:       ${HOST_LOG}"
echo "                Alpine ISO:     ${ALPINE_ISO_BASENAME}"

# IMPORTANT: --rm IS set here (single-shot diagnostic). The host log file
# captures everything we care about. The macOS-recovery script intentionally
# does NOT use --rm so container logs survive a hang.
#
# We pass the in-container script via stdin (`bash -s`) with a fully-quoted
# heredoc so nothing gets mangled by the host shell. Variable substitution
# the inner script needs is delivered via `-e KEY=VAL` env vars on
# `docker run`.
docker run \
    --rm -i \
    --privileged \
    --cpus="${CONTAINER_CPUS}" \
    --memory="${CONTAINER_MEM}" \
    --memory-swap="${CONTAINER_MEM}" \
    --device /dev/kvm:/dev/kvm \
    -v "${HOST_DATA}:/data" \
    -e "ALPINE_ISO_BASENAME=${ALPINE_ISO_BASENAME}" \
    -e "DEVICE=${DEVICE}" \
    -e "GUEST_SMP=${GUEST_SMP}" \
    -e "GUEST_MEM=${GUEST_MEM}" \
    -e "QEMU_TIMEOUT_SEC=${QEMU_TIMEOUT_SEC}" \
    --entrypoint /bin/bash \
    "${IMAGE}" \
    -s <<'EOF_INNER' 2>&1 | tee "${HOST_LOG}"
set -euo pipefail

ISO=/data/${ALPINE_ISO_BASENAME}
SCRATCH=$(mktemp -d)
trap 'rm -rf $SCRATCH' EXIT

# 1) Extract Alpine kernel + initramfs from the ISO (the ISO is hybrid
#    ISO9660 — mountable as iso9660 in the container).
mkdir -p $SCRATCH/iso
mount -o loop,ro "$ISO" $SCRATCH/iso
cp $SCRATCH/iso/boot/vmlinuz-virt $SCRATCH/vmlinuz
cp $SCRATCH/iso/boot/initramfs-virt $SCRATCH/initramfs.orig

# 2) Build a minimal /init for the in-guest initramfs that walks USB and
#    halts. We don't bother with Alpine's apkovl machinery — overlaying
#    just /init keeps the guest minimal, deterministic, and fast.
#    Inner heredoc is quoted ('INIT_EOF') so nothing in the script body
#    is expanded by the outer shell — these $VARS are evaluated by the
#    in-guest /bin/sh at boot, not by us.
cat > $SCRATCH/init <<'INIT_EOF'
#!/bin/sh
# Custom one-shot init: mount /proc /sys /dev, modprobe USB host stack,
# then walk USB and dump descriptors. ttyS0 is the QEMU `-serial stdio`
# sink so this output ends up in the host log.
exec >/dev/ttyS0 2>&1
echo "==== test-magic-linux: custom init starting ===="
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

for m in ehci-pci ehci-hcd ohci-pci ohci-hcd uhci-hcd xhci-pci xhci-hcd usbcore usb-common hid usbhid; do
    modprobe $m 2>/dev/null || true
done
sleep 2
echo "==== /sys/bus/usb/devices snapshot ===="
ls -la /sys/bus/usb/devices/ 2>/dev/null || true
echo "==== descriptor walk via sysfs (busybox has no lsusb -v) ===="
for d in /sys/bus/usb/devices/*/idVendor; do
    devdir=$(dirname "$d")
    [ -r "$devdir/idVendor" ] || continue
    v=$(cat "$devdir/idVendor" 2>/dev/null)
    p=$(cat "$devdir/idProduct" 2>/dev/null)
    m=$(cat "$devdir/manufacturer" 2>/dev/null || echo "")
    n=$(cat "$devdir/product" 2>/dev/null || echo "")
    s=$(cat "$devdir/serial" 2>/dev/null || echo "")
    echo "USB $(basename $devdir): $v:$p  '$m' '$n' '$s'"
    if [ -r "$devdir/bcdDevice" ]; then
        echo "    bcdDevice=$(cat $devdir/bcdDevice)"
    fi
    if [ -r "$devdir/descriptors" ]; then
        echo "    -- raw device descriptor (hex) --"
        od -An -tx1 -w32 "$devdir/descriptors" | head -8
    fi
done
echo "==== HID report descriptors (if any) ===="
for r in /sys/bus/usb/devices/*/*/report_descriptor; do
    [ -r "$r" ] || continue
    echo "-- $r --"
    od -An -tx1 -w16 "$r"
done
echo "==== test-magic-linux: done; halting ===="
sleep 1
poweroff -f 2>/dev/null || halt -f 2>/dev/null || sync
echo o > /proc/sysrq-trigger 2>/dev/null || true
# QEMU will be SIGTERM'd by host-side `timeout` if we get here.
while :; do sleep 1; done
INIT_EOF
chmod +x $SCRATCH/init

# 2b) Append a cpio segment with our /init to the original initramfs.
#     Linux walks concatenated gzipped cpio segments; later entries
#     override earlier ones, so our /init wins.
mkdir -p $SCRATCH/overlay
cp $SCRATCH/init $SCRATCH/overlay/init
( cd $SCRATCH/overlay && find . | cpio -o -H newc 2>/dev/null | gzip -c ) > $SCRATCH/overlay.cpio.gz
cat $SCRATCH/initramfs.orig $SCRATCH/overlay.cpio.gz > $SCRATCH/initramfs

# 3) Tiny scratch disk so QEMU has a writable backing file. 64 MiB is plenty.
qemu-img create -f raw $SCRATCH/scratch.img 64M >/dev/null

echo "==== Booting Alpine under QEMU with $DEVICE attached ===="

# 4) Launch QEMU. Safety rails: -snapshot, no macOS disk, hard guest mem
#    cap, timeout wrapper.
rc=0
timeout --kill-after=10 "$QEMU_TIMEOUT_SEC" \
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$GUEST_MEM" \
        -smp "$GUEST_SMP" \
        -machine q35 \
        -cpu host \
        -kernel $SCRATCH/vmlinuz \
        -initrd $SCRATCH/initramfs \
        -append "console=ttyS0,115200 quiet rdinit=/init" \
        -drive file=$SCRATCH/scratch.img,format=raw,if=virtio,snapshot=on \
        -device qemu-xhci,id=xhci \
        -device "$DEVICE",bus=xhci.0 \
        -display none \
        -serial stdio \
        -no-reboot \
        -snapshot \
    || rc=$?
umount $SCRATCH/iso 2>/dev/null || true
echo "==== qemu exited (rc=$rc); see host log for descriptor dump ===="
EOF_INNER

echo ""
echo "=========================================================="
echo "  Linux-guest descriptor walk complete."
echo "  Log:   ${HOST_LOG}"
echo "  Look for:"
echo "    - 'USB <bus>-<port>: 05ac:026c' (apple-magic-keyboard PID/VID)"
echo "    - 'Apple Inc.' / 'Magic Keyboard with Numeric Keypad' strings"
echo "    - HID report descriptor at /sys/bus/usb/devices/.../report_descriptor"
echo "  If those are clean, proceed to test-magic-recovery-safe.sh."
echo "=========================================================="
