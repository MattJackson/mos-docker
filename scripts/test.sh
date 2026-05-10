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
    0|1|2|3|4|9) ;;
    *)
        echo "Usage: test <phase>" >&2
        echo "  phase: 0..4 or 9" >&2
        echo "    0=sanity, 4=production paravirt (M5 dev)," >&2
        echo "    9=interactive debug (writable disk, generic HID, std-vga," >&2
        echo "       NO auto-powerdown — stays alive until you stop it)" >&2
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

# --- CPU model (xnu pmap stability) ----------------------------------
# Default `Skylake-Client` not `host`. xnu's pmap takes branches on
# CPUID feature bits that misbehave under KVM:
#   -pdpe1gb : 1 GiB-page CPUID bit. xnu's pmap_query_page_info walks
#              page tables assuming 4K/2M leaves; a PDPTE with PS=1
#              GP-faults the kernel.
#   -hle -rtm: TSX. xnu's vm_map_fork takes RTM fast-paths that abort
#              under KVM emulation, corrupting pmap free-lists →
#              "corrupt list around element" panics observed 2026-05-10.
#   -vmx     : xnu doesn't use guest VMX; CR4.VMXE leaking through
#              flips pmap's TLB-invalidate sequence.
# kholia/OSX-KVM canonical for Sequoia: see notes.md "Sequoia + Tahoe".
# Override with CPU_MODEL=host to bisect.
CPU_MODEL="${CPU_MODEL:-Skylake-Client}"
if [ "$CPU_MODEL" = "host" ]; then
    CPU_ARGS="host,vendor=GenuineIntel,vmware-cpuid-freq=on"
else
    CPU_ARGS="${CPU_MODEL},vendor=GenuineIntel,kvm=on,vmware-cpuid-freq=on,+invtsc,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,-hle,-rtm,-vmx,-pdpe1gb,check"
fi

# --- COMMON_ARGS — grouped by scope ----------------------------------
# Three groups, in this order:
#
#   [host]     Resource tuning for the box you're on. Adjust freely
#              (RAM, vCPU count, hypervisor choice).
#   [macOS]    Universal macOS-on-QEMU/KVM-x86 recipe. Apply to any
#              Linux host running stock macOS — not project-specific.
#              Don't change unless you've read the linked context.
#   [project]  Specific to this stack (phase model, log paths, hostfwd
#              scheme, observability). Adapt to your scripting.
#
# A clean set of args for "macOS on a different host or framework"
# would keep [macOS] verbatim, replace [host] with your tuning, and
# rewrite [project] to your stack's conventions.
COMMON_ARGS=(
    # ===================================================================
    # [host] — resource tuning
    # ===================================================================

    # KVM hardware acceleration. Without this xnu runs under TCG
    # (software interp) — boot takes 30+ min instead of ~90s. On non-
    # Linux hosts substitute the local hypervisor (HVF, WHPX).
    -enable-kvm

    # Guest RAM. macOS Sequoia floor is ~8 GB to boot at all, 16 GB for
    # a usable GUI without thrashing. Tunable via RAM env var.
    -m "${RAM:-16}G"

    # SMP topology — vCPU count + topology layout. Counts here are
    # [host] tuning, but the topology shape (sockets=1, paired threads)
    # is [macOS] — see the [macOS] comment block above the array on
    # why xnu's scheduler needs explicit sockets/cores/threads.
    -smp "${SMP:-16}",sockets=1,cores="${CORES:-8}",threads="${THREADS:-2}"

    # ===================================================================
    # [macOS] — universal macOS-on-QEMU/KVM-x86 recipe
    # ===================================================================

    # CPU model + feature set. Default Skylake-Client with TSX/VMX/1GB-
    # pages stripped is the xnu pmap-stability fix; `-cpu host` causes
    # panics in pmap_remove_range and pmap_query_page_info. See the
    # long comment block above the array for per-flag rationale.
    -cpu "$CPU_ARGS"

    # Intel Q35 chipset — PCIe-native + ICH9 southbridge + AHCI. Apple
    # firmware expects Q35-style ACPI; older `pc-i440fx` boots but
    # AppleACPIPlatform trips on missing PCIe extension methods.
    -machine q35

    # OVMF UEFI firmware. Two pflash drives by UEFI convention:
    # CODE = read-only firmware image, VARS = NVRAM (Apple identity,
    # boot-args, BootOrder). macOS won't boot from non-UEFI firmware
    # (no legacy BIOS path in modern xnu).
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd

    # SMBIOS type 2 = baseboard table placeholder. Apple identity
    # (Mac-CFF7D910... / iMac20,1) is overwritten by OpenCore
    # PlatformInfo at boot, but the table must EXIST in firmware first.
    # Without `-smbios type=2`, OpenCore has nowhere to write into.
    -smbios type=2

    # Intel 82545EM NIC — Apple ships a stock driver
    # (AppleIntel8254XEthernet.kext) for this exact chip. Other
    # emulated NICs boot but show "no network" without third-party
    # kexts; e1000-82545em is the zero-extra-kext choice.
    -device e1000-82545em,netdev=net0

    # ===================================================================
    # [project] — networking, display, observability for this stack
    # ===================================================================

    # User-mode (slirp) NAT with hostfwd for ssh. Guest gets 10.0.2.15
    # / gateway 10.0.2.2. Per-phase port offset (22220+PHASE → 22) so
    # phases can run side-by-side. Prod path (run.sh) uses macvtap for
    # real LAN IP; test stays on slirp for deterministic regression
    # behavior independent of host LAN.
    -netdev "user,id=net0,hostfwd=tcp::$((22220 + PHASE))-:22"

    # No SDL/GTK window — we drive display via VNC so a headless
    # container works the same as one with a console attached.
    -display none

    # VNC server bound to loopback only. Bundled noVNC bridges
    # 127.0.0.1:5900+N → 0.0.0.0:6080+N for browser access. Loopback
    # keeps QEMU off the host's open-port surface.
    -vnc 127.0.0.1:${VNC_DISPLAY}

    # Kernel serial console → file. xnu boot-args set `serial=3`
    # (kernel printf to COM1); captures everything plus panic
    # stackshots. file: chardev (not stdio) survives QEMU exit without
    # truncation.
    -serial file:"$SERIAL_LOG"

    # HMP (Human Monitor Protocol) interactive control via unix socket.
    # Used by test.sh's qmp_send for system_powerdown, and by operators
    # with `socat - unix-connect:$HMP_SOCK`.
    -monitor unix:"$HMP_SOCK",server,nowait

    # QMP (QEMU Machine Protocol) — JSON-over-unix programmatic control.
    # Same socket-server pattern as HMP, scripted use: screenshots,
    # query-pci, graceful poweroff.
    -qmp unix:"$QMP_SOCK",server,nowait

    # Log guest CPU faults + unimplemented-feature accesses to
    # qemu-debug.log. Critical for apple-gfx-pci debugging — MMIO
    # accesses that hit unimplemented paths surface here. WARNING:
    # `qemu_log()` lands here, NOT in `docker logs` stderr. See
    # memory/feedback_m5_log_locations.md before adding host-side logs.
    -d guest_errors,unimp

    # Destination file for -d. Inside container, mapped to host
    # /mnt/docker/mos-data/logs/qemu-debug.log via /data bind-mount.
    -D /data/logs/qemu-debug.log
)

# --- Display device per phase ----------------------------------------
# [project] Phase 4 = M5 dev = apple-gfx-pci (the paravirt GPU we're
# building); 0-3 + 9 = std-vga as the known-good baseline that lets
# loginwindow / WindowServer render without our half-built stack.
#
# [macOS] std-vga vs `-vga std`: plain `-vga std` gives a small
# framebuffer that makes noVNC see only the top-left quadrant of
# macOS's render surface. The explicit `-device VGA xres/yres/
# vgamem_mb/edid=on` form fixes that — gives macOS a 1920x1080@32
# framebuffer to render into and an EDID so AppleSupport / NSScreen
# both see a real "monitor".
#
# [macOS] apple-gfx-pci needs `memory-backend-memfd,share=on` —
# libapplegfx-vulkan does mremap-alias tricks that need a backed file
# descriptor, not anonymous RAM.
if [ "$PHASE" = "4" ]; then
    COMMON_ARGS+=( -vga none -device apple-gfx-pci )
    COMMON_ARGS+=( -object "memory-backend-memfd,id=mem,size=${RAM:-8}G,share=on" )
else
    COMMON_ARGS+=( -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on )
fi

# --- macOS firmware platform glue ------------------------------------
# [macOS] All four lines are mandatory for macOS to boot past
# AppleACPICPU on any KVM host. Phase 0 skips them (sanity test, no
# macOS).
#
#   isa-applesmc with osk=...: emulates Apple's System Management
#   Controller. The OSK string is the unlock secret xnu checks during
#   boot. Without applesmc, AppleSMC.kext fails to attach and DSMOS
#   never decrypts FileVault-encrypted Apple binaries — boot stops at
#   "DSMOS has arrived" never appearing.
#
#   ICH9-LPC.disable_s3=1 / disable_s4=1: tell macOS the platform has
#   no S3 (sleep) / S4 (hibernate) states. Without these, AppleACPI
#   tries to set up sleep state machines that crash under KVM.
#
#   acpi-pci-hotplug-with-bridge-support=off: disables QEMU's PCI
#   hotplug ACPI methods on bridges. macOS's IOPCIBridge gets confused
#   by their presence (expects either always-present devices or pure
#   hot-add — not the QEMU "may or may not be there" hybrid).
if [ "$PHASE" -ge 1 ]; then
    COMMON_ARGS+=(
        -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
    )
fi

# --- USB HID (keyboard + pointer) ------------------------------------
# [project] Phase 3 is the "Apple HID" lane by convention — its
# defaults flip to apple-magic-keyboard / apple-mighty-mouse so the HID
# regression suite exercises our patched USB devices. Other phases use
# generic usb-kbd / usb-tablet because:
#   [macOS]   usb-tablet is an absolute-positioning pointer; VNC
#             remote-control needs absolute pointers, not relative
#             mice (apple-mighty-mouse drifts under VNC; see
#             memory/feedback_apple_hid_vnc_pointer_drift.md).
#   [macOS]   apple-kbd / apple-tablet break the macOS Recovery
#             environment (USB binding fails); install paths must use
#             generic devices (memory/feedback_apple_hid_breaks_recovery.md).
#
# Override knobs:
#   KBD_DEVICE    keyboard type (default: usb-kbd; phase 3: apple-magic-keyboard)
#   MOUSE_DEVICE  pointer type (canonical name)
#   TABLET_DEVICE legacy alias for MOUSE_DEVICE (back-compat)
if [ "$PHASE" = "3" ]; then
    KBD_DEVICE="${KBD_DEVICE:-apple-magic-keyboard}"
    TABLET_DEVICE="${MOUSE_DEVICE:-${TABLET_DEVICE:-apple-mighty-mouse}}"
else
    KBD_DEVICE="${KBD_DEVICE:-usb-kbd}"
    TABLET_DEVICE="${MOUSE_DEVICE:-${TABLET_DEVICE:-usb-tablet}}"
fi
COMMON_ARGS+=(
    # [macOS] qemu-xhci = USB 3 controller. macOS prefers xhci over
    # ehci/uhci — its USB stack auto-binds to xhci, while ehci needs
    # AppleUSBEHCI which has occasional binding flake on some models.
    -device qemu-xhci,id=xhci
    -device "${KBD_DEVICE},bus=xhci.0"
    -device "${TABLET_DEVICE},bus=xhci.0"
)

# --- Disk attach -----------------------------------------------------
# [project] Phase 0 is the empty-disk sanity test (OVMF should fall
# through to PXE). Phases 1-4 + 9 attach the real macOS disk + OpenCore
# loader.
#
# [project] write semantics:
#   default                snapshot=on, file.locking=off  → ephemeral
#                          writes (RAM overlay; disk.img never mutated;
#                          phases run concurrent + with prod safely).
#   PHASE=3 + MOS_PHASE3_PERSIST=1
#                          writes hit disk.img directly. Legacy opt-in
#                          for editing settings; phase 9 supersedes.
#   PHASE=9                always writable + locked. The point of phase
#                          9 is interactive use that survives reboot.
if [ "$PHASE" = "0" ]; then
    COMMON_ARGS+=(
        # [project] Phase 0 only: empty 1G disk on virtio-blk for the
        # firmware-sanity test (no OpenCore, no macOS).
        -drive "id=disk0,if=none,file=$DISK,format=raw"
        -device virtio-blk-pci,drive=disk0
    )
else
    MACHDD_OPTS="cache=none,aio=native,snapshot=on,file.locking=off"
    if [ "$PHASE" = "3" ] && [ "${MOS_PHASE3_PERSIST:-0}" = "1" ]; then
        # QEMU's default file.locking=on takes a real OFD lock on
        # disk.img — a second concurrent writer fails at startup. We
        # rely on that rather than a process-scan guard.
        MACHDD_OPTS="cache=none,aio=native"
        echo "  MOS_PHASE3_PERSIST=1 — writes hit $DISK directly (file.locking on)."
    fi
    if [ "$PHASE" = "9" ]; then
        MACHDD_OPTS="cache=none,aio=native"
        echo "  Phase 9 — writes hit $DISK directly (file.locking on)."
    fi
    COMMON_ARGS+=(
        # [macOS] ICH9 AHCI controller — Apple's stock SATA driver
        # (AppleAHCIPort) binds here. OpenCore.img must be on AHCI/IDE
        # because OVMF's NVMe path doesn't see it on Q35 by default.
        -device ich9-ahci,id=sata

        # [macOS] OpenCore EFI image — Apple identity, Kernel/Add
        # entries, NVRAM presets, boot-args. Loaded via IDE on the AHCI
        # bus. snapshot=on because OpenCore.img source-of-truth lives
        # in this repo's efi/ directory; runtime mutation is unwanted.
        -drive "id=OpenCoreBoot,if=none,format=raw,file=$OPENCORE,snapshot=on"
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot

        # [macOS] macOS system disk on virtio-blk — IOVirtIOBlock binds
        # cleanly with no extra kexts (faster + lower CPU than emulated
        # AHCI for the data disk).
        -drive "id=MacHDD,if=none,file=$DISK,format=raw,$MACHDD_OPTS"
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

# --- NUMA pinning ([host] for multi-socket, [macOS] for stability) ---
# [host]   The pinning policy itself (which node) is host-specific.
# [macOS]  Whether to pin AT ALL is universal: xnu's pmap can't tolerate
#          cross-socket vCPU scheduling under userland load. PT walks
#          (`pmap_remove_range`, `pmap_query_page_info`, corpse-fork
#          paths) take IPI-coordinated TLB shootdowns; cross-socket
#          atomics on PTEs widen race windows enough to corrupt
#          vm_map_entry lists and GP-fault.
#
# Concrete observations on 2x E5-2699 v3 (36C/72T NUMA-2):
#   no pin: BiomeAgent panic at ~5min, ContinuityCapture at ~3min
#   pin=0:  cleanly past both (12+ min before the pdpe1gb-class panic)
#
# Default: pin to NUMA node 0. Override with MOS_NUMA_NODE=<n> or empty
# string to disable. No-op on single-node hosts (--cpunodebind=0 just
# uses the only node).
NUMA_PIN=""
if [ -n "${MOS_NUMA_NODE-0}" ]; then
    if command -v numactl >/dev/null 2>&1; then
        NUMA_PIN="numactl --cpunodebind=${MOS_NUMA_NODE:-0} --membind=${MOS_NUMA_NODE:-0}"
        echo "    NUMA pin:    node ${MOS_NUMA_NODE:-0} (set MOS_NUMA_NODE= to disable)"
    else
        echo "    NUMA pin:    SKIPPED — numactl missing in image"
    fi
else
    echo "    NUMA pin:    disabled (MOS_NUMA_NODE empty)"
fi
echo "================================================================"

# Phase 4 is the M5 development stack — runs interactively without
# auto-pass/fail (visual verification on noVNC over a long session).
# Phases 0-3 are real regression tests: boot, watch the serial log for
# known pass/fail markers, exit 0/1/2 with a clear verdict.
#
# EXTERNAL_SUPERVISOR=1 disables the inner pass/fail supervisor below
# and just runs QEMU directly. test-runner.sh (./mos verify) sets this
# so the OUTER supervisor can poll serial for the actual login marker
# and take its own gold-diff screendump — without the inner supervisor
# matching an early-userland marker, powering down QEMU, and exiting
# the container before the screendump can fire (the bug behind the
# "screenshot: FAILED to capture" + verify-runner false-PASS that
# caused 2026-05-09 regression-test paralysis).
if [ "$PHASE" = "4" ] || [ "$PHASE" = "9" ] || [ "${EXTERNAL_SUPERVISOR:-0}" = "1" ]; then
    exec $NUMA_PIN "$QEMU_BIN" "${COMMON_ARGS[@]}"
fi

# --- Phase 0-3 supervisor ---
# The supervisor uses pipes (grep | head), backgrounded jobs, and
# command substitutions whose exit codes are NOT signal of failure.
# Disable strict mode for the rest of the script so an in-pipe SIGPIPE
# or a no-match grep doesn't tear the supervisor down before it can
# print a verdict.
set +e
set +o pipefail
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
        # PASS = macOS reached the actual login window with a real PID. The
        # broader earlier regex (matching securityd / AirPlayXPCHelper /
        # AppleKeyStore session-uid early-userland markers) reported PASS
        # within 30s on a guest that subsequently panicked at mount-phase-2
        # before ever rendering the login screen — false positives that
        # masked a real boot regression. Only `loginwindow (<PID>)` proves
        # the kernel + launchd actually ran user-facing graphical login.
        PASS_RE='loginwindow \([0-9]+\)'
        # Catch the userspace panics (mount-phase-2 SIGABRT etc.) that
        # the broader matcher used to ignore.
        FAIL_RE='panic\(cpu |Debugger called|Unable to find driver for this platform|hfs_mountfs failed|kernel panic|"Sleeping"|userspace panic|boot task failure'
        DEADLINE=300
        ;;
esac

# Start QEMU in the background; cleanup() (above) tears it down on exit.
$NUMA_PIN "$QEMU_BIN" "${COMMON_ARGS[@]}" &
QEMU_PID=$!

qmp_send() {
    [ -S "$QMP_SOCK" ] || return 0
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
        | socat - "UNIX-CONNECT:$QMP_SOCK" >/dev/null 2>&1 || true
}

# Capture a PNG screenshot via QMP screendump. Writes to
# /data/run/phase-${PHASE}-current.png (bind-mounted to host as
# data/run/phase-${PHASE}-current.png). Sign-off compare against the
# baselines/phase-${PHASE}-gold.png happens on the laptop side.
qmp_screendump() {
    local out="$1"
    [ -S "$QMP_SOCK" ] || return 0
    printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s","format":"png"}}\n' "$out" \
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
        # Let the screen settle a beat, then capture for sign-off compare.
        sleep 3
        SHOT="/data/run/phase-${PHASE}-current.png"
        qmp_screendump "$SHOT"
        if [ -s "$SHOT" ]; then
            echo "    screenshot: $SHOT ($(stat -c%s "$SHOT" 2>/dev/null) bytes)"
        else
            echo "    screenshot: FAILED to capture"
        fi
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
