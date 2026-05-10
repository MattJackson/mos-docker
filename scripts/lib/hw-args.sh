# mos-docker — single source of truth for the macOS guest's QEMU
# hardware config. Sourced (NOT executed) by run.sh / test.sh / install.sh.
#
# Why this exists
# ---------------
# Before 2026-05-10 each launcher script defined its own QEMU args. The
# three drifted: run.sh used `-device VGA` while test.sh used vmware-svga,
# test.sh used slirp + e1000-82545em while run.sh used macvtap +
# virtio-net-pci, and so on. That meant a bug fix in one launcher silently
# left the other two broken. This lib collapses the shared baseline into
# one place and lets each launcher specify ONLY its legitimate
# differences (phase 0 = empty disk, phase 4 = apple-gfx-pci, install =
# recovery DMG).
#
# The April-2026 stable baseline (operator-confirmed 2026-05-10):
#   CPU       Skylake-Client + tagged feature set + TSX/VMX/1GB-pages stripped
#   SMP       16 vCPUs / sockets=1, cores=8, threads=2  (iMac20,1 SMBIOS shape)
#   Memory    16 GiB default + memfd backend when apple-gfx-pci is on
#   Machine   q35,accel=kvm
#   Firmware  OVMF (CODE+VARS pflash)
#   SMBIOS    type=2  (PlatformInfo overwrites at OpenCore boot)
#   AppleSMC  isa-applesmc with the OSK
#   ICH9      disable_s3=1, disable_s4=1, acpi-pci-hotplug=off
#   NIC       virtio-net-pci over macvtap (slirp fallback only when no UP NIC)
#   Display   vmware-svga from vanilla upstream QEMU
#             (apple-gfx-pci only for the M5 paravirt phase)
#             [STD-VGA IS NEVER A DEFAULT — see mos_hw_display below]
#   USB       qemu-xhci + usb-kbd + usb-tablet  (apple-magic-* via env knobs)
#   Disk      OpenCore on AHCI/IDE; disk.img on virtio-blk; cache=none,aio=native
#   Serial    chardev to file
#   Monitor   HMP + QMP unix sockets
#   VNC       127.0.0.1 only (websockify bridges to noVNC)
#   Pinning   numactl --cpunodebind/--membind  (default node 0)
#
# Calling convention
# ------------------
# Each `mos_hw_*` helper appends arguments to the caller's QEMU_ARGS array
# (which the caller declares as a regular bash array before sourcing). A
# few helpers also export side-effect variables (e.g. mos_hw_netdev_args
# may open fd 3, mos_hw_io_args sets NUMA_PIN). Helpers that need data
# from the caller take it as positional args, not env, so the call site
# stays self-documenting.
#
# Style: align with the existing test.sh comment scheme — [host] for
# resource tuning, [macOS] for universal macOS-on-QEMU/KVM-x86 invariants,
# [project] for stack-specific knobs.

# Guard against double-sourcing.
[ "${_MOS_HW_ARGS_LIB:-}" = "1" ] && return 0
_MOS_HW_ARGS_LIB=1

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
# [macOS] Skylake-Client with TSX/VMX/1GB-pages stripped is the xnu pmap-
# stability fix; `-cpu host` causes panics in pmap_remove_range and
# pmap_query_page_info on multi-socket Linux hosts. CPU_MODEL=host stays
# available as a bisect override. Each feature flag is documented inline.
mos_hw_cpu_args() {
    local model="${CPU_MODEL:-Skylake-Client}"
    local cpu_args
    if [ "$model" = "host" ]; then
        # Bare-bones host passthrough — kept available so we can bisect a
        # regression "is it model-related, or something else?".
        cpu_args="host,vendor=GenuineIntel,vmware-cpuid-freq=on"
    else
        local features=(
            # CPUID identity / hypervisor signature
            vendor=GenuineIntel    # [macOS] xnu rejects AuthenticAMD; panic before kext init.
            kvm=on                 # [macOS] advertise KVM in CPUID 0x40000000+; xnu takes
                                   #         faster paths under recognized hypervisors.
            vmware-cpuid-freq=on   # [macOS] expose TSC + bus freq via CPUID 0x40000010,
                                   #         lets macOS skip an expensive calibration loop.

            # ISA features macOS x86_64 ABI assumes are present
            +invtsc                # [macOS] invariant TSC — mach_absolute_time drifts without.
            +ssse3                 # [macOS] Snow Leopard+ baseline.
            +sse4.2                # [macOS] Mountain Lion+ baseline.
            +popcnt                # [macOS] used by xnu's compressor.
            +avx                   # [macOS] Mavericks+ baseline.
            +aes                   # [macOS] FileVault + APFS/HFS encryption.
            +xsave                 # [macOS] context save/restore (mcontext).
            +xsaveopt              # [macOS] optimized XSAVE — faster ctx switch.

            # Negations — strip features that destabilize xnu under KVM.
            -hle                   # [stability] TSX HLE bit. xnu vm_map_fork takes RTM
            -rtm                   # [stability] TSX RTM bit. fast-paths that abort under
                                   #             KVM emulation, corrupting pmap free-lists.
                                   #             Caused "corrupt list around element"
                                   #             panics observed 2026-05-10.
            -vmx                   # [stability] xnu doesn't run an inner hypervisor;
                                   #             CR4.VMXE leaking through changes pmap's
                                   #             TLB-invalidate sequence.
            -pdpe1gb               # [stability] 1 GiB-page CPUID bit. xnu's
                                   #             pmap_query_page_info walks PTs assuming
                                   #             4K/2M leaves; PDPTE PS=1 GP-faults.

            # Cosmetic — Skylake-Client model claims these but the host
            # (Haswell-EP) doesn't have them. With `check` they'd be warned
            # per-vCPU on every boot ("host doesn't support requested
            # feature: ..."). Explicit negation removes them from the model
            # BEFORE the check, so the warning never fires AND the guest
            # CPUID is bit-identical to the un-negated form (KVM was already
            # filtering them out — see memory/research_cpu_model_choice_2026_05_10.md).
            -rdseed                # Broadwell+; not on Haswell-EP.
            -adx                   # Broadwell+; not on Haswell-EP.
            -smap                  # Broadwell+; not on Haswell-EP. (Different
                                   #   from CR4.SMAP which is hardware-supported;
                                   #   this is the CPUID feature bit only.)
            -xsavec                # Skylake+; not on Haswell-EP.
            -xgetbv1               # Skylake+; not on Haswell-EP.
            -3dnowprefetch         # AMD-originated; not on Intel Haswell.

            check                  # [project] refuse to start if any feature unavailable
                                   #           (typo guard — better to fail loudly than
                                   #           silently lose a feature).
        )
        cpu_args="${model},$(IFS=,; echo "${features[*]}")"
    fi
    QEMU_ARGS+=( -cpu "$cpu_args" )
}

# ---------------------------------------------------------------------------
# SMP / topology
# ---------------------------------------------------------------------------
# [host]   vCPU count is host tuning.
# [macOS]  topology shape (sockets=1, paired threads) is universal — xnu's
#          scheduler needs explicit sockets/cores/threads; iMac20,1
#          SMBIOS = 8C/16T so cores=8, threads=2 is the canonical pair.
#
# SMP must equal sockets * cores * threads. Bumping SMP requires bumping
# CORES (or THREADS) in lockstep. Defaults below match the iMac20,1 shape.
mos_hw_smp_args() {
    QEMU_ARGS+=(
        -smp "${SMP:-16},sockets=1,cores=${CORES:-8},threads=${THREADS:-2}"
    )
}

# ---------------------------------------------------------------------------
# Machine + memory
# ---------------------------------------------------------------------------
# [macOS] Q35 chipset: PCIe-native + ICH9 southbridge + AHCI. Apple
# firmware expects Q35-style ACPI; older `pc-i440fx` boots but
# AppleACPIPlatform trips on missing PCIe extension methods.
#
# [macOS] apple-gfx-pci needs a memfd memory backend — libapplegfx-vulkan
# does mremap-alias tricks that need a backed file descriptor, not
# anonymous RAM. When MOS_USE_APPLE_GFX_PCI=1, we add the memory-backend-
# memfd object AND wire it to the machine via -machine memory-backend=mem.
#
# Args:
#   $1  ram_gb  — guest RAM size in GiB (no suffix). Default: $RAM env.
mos_hw_machine_args() {
    local ram_gb="${1:-${RAM:-16}}"
    if [ "${MOS_USE_APPLE_GFX_PCI:-0}" = "1" ]; then
        QEMU_ARGS+=(
            -object "memory-backend-memfd,id=mem,size=${ram_gb}G,share=on"
            -machine q35,accel=kvm,memory-backend=mem
        )
    else
        QEMU_ARGS+=(
            -machine q35,accel=kvm
        )
    fi
    QEMU_ARGS+=(
        -enable-kvm
        -m "${ram_gb}G"
    )
}

# ---------------------------------------------------------------------------
# Firmware (OVMF UEFI pflash)
# ---------------------------------------------------------------------------
# [macOS] CODE = read-only firmware image, VARS = NVRAM (Apple identity,
# boot-args, BootOrder). macOS won't boot from non-UEFI firmware — there's
# no legacy BIOS path in modern xnu.
mos_hw_firmware_args() {
    QEMU_ARGS+=(
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd
        -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd
    )
}

# ---------------------------------------------------------------------------
# macOS firmware platform glue (SMBIOS + AppleSMC + ICH9 globals)
# ---------------------------------------------------------------------------
# [macOS] All four are mandatory for macOS to boot past AppleACPICPU on
# any KVM host. Phase 0 (firmware-sanity, no macOS) skips this group.
#
#   SMBIOS type=2: baseboard table placeholder. Apple identity
#   (Mac-CFF7D910... / iMac20,1) is overwritten by OpenCore PlatformInfo
#   at boot, but the table must EXIST in firmware first.
#
#   isa-applesmc with osk=...: emulates Apple's System Management
#   Controller. The OSK string is the unlock secret xnu checks during
#   boot. Without applesmc, AppleSMC.kext fails to attach and DSMOS never
#   decrypts FileVault-encrypted Apple binaries — boot stops at "DSMOS
#   has arrived" never appearing.
#
#   ICH9-LPC.disable_s3=1 / disable_s4=1: tell macOS the platform has no
#   S3 (sleep) / S4 (hibernate) states. Without these, AppleACPI tries to
#   set up sleep state machines that crash under KVM.
#
#   acpi-pci-hotplug-with-bridge-support=off: disables QEMU's PCI hotplug
#   ACPI methods on bridges. macOS's IOPCIBridge gets confused by their
#   presence (expects either always-present devices or pure hot-add — not
#   the QEMU "may or may not be there" hybrid).
mos_hw_smbios_apple_args() {
    QEMU_ARGS+=(
        -smbios type=2
        -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
    )
}

# ---------------------------------------------------------------------------
# USB HID (keyboard + pointer)
# ---------------------------------------------------------------------------
# [macOS] qemu-xhci = USB 3 controller. macOS prefers xhci over ehci/uhci —
# its USB stack auto-binds to xhci, while ehci needs AppleUSBEHCI which
# has occasional binding flake on some models.
#
# [project] Default = generic usb-kbd + usb-tablet (absolute-positioning
# pointer; VNC remote-control needs absolute, not relative). Phase 3
# flips to apple-magic-keyboard / apple-mighty-mouse via the env knobs
# below (set by the caller before calling this helper).
#
# Env knobs (caller sets these BEFORE invoking):
#   KBD_DEVICE     keyboard type   (default: usb-kbd)
#   MOUSE_DEVICE   pointer type    (canonical name; preferred over TABLET_DEVICE)
#   TABLET_DEVICE  legacy alias for MOUSE_DEVICE (back-compat)
#
# WARNING: apple-kbd / apple-tablet break the macOS Recovery environment
# (USB binding fails). install paths must use generic devices — see
# memory/feedback_apple_hid_breaks_recovery.md.
mos_hw_usb_args() {
    local kbd="${KBD_DEVICE:-usb-kbd}"
    local pointer="${MOUSE_DEVICE:-${TABLET_DEVICE:-usb-tablet}}"
    QEMU_ARGS+=(
        -device qemu-xhci,id=xhci
        -device "${kbd},bus=xhci.0"
        -device "${pointer},bus=xhci.0"
    )
}

# ---------------------------------------------------------------------------
# Networking — macvtap + virtio-net-pci (with slirp fallback / opt-in)
# ---------------------------------------------------------------------------
# [macOS] macvtap gives the guest a real LAN IP, which macOS's recovery +
# production stack expects. user-mode (slirp) doesn't satisfy macOS's
# network-detect UX even though it'd technically NAT.
#
# [project] We auto-detect HOST_IFACE (first UP physical NIC) and fall
# back to slirp if none is up. NETWORK_MODE=slirp is an explicit opt-in
# for tests that need predictable host-fwd ssh.
#
# Side effects:
#   - opens fd 3 onto /dev/tap${ifx} when macvtap0 is created
#   - declares macvtap0 at the kernel level
#
# Args:
#   $1  hostfwd_port (optional)  — when in slirp mode, forward
#                                   tcp::$1-:22 for ssh access. Default
#                                   22220 (matches run.sh's prior
#                                   $SSH_PORT default).
mos_hw_netdev_args() {
    local hostfwd_port="${1:-22220}"
    local mode="${NETWORK_MODE:-auto}"

    if [ "$mode" = "slirp" ]; then
        echo "Networking: user-mode (slirp), hostfwd tcp::${hostfwd_port}-:22 (NETWORK_MODE=slirp)"
        QEMU_ARGS+=(
            -netdev "user,id=net0,hostfwd=tcp::${hostfwd_port}-:22"
            -device virtio-net-pci,netdev=net0
        )
        return 0
    fi

    # Auto-detect HOST_IFACE if not explicitly set: first UP physical NIC,
    # skipping virtual interfaces.
    if [ -z "${HOST_IFACE:-}" ]; then
        # awk's `exit` triggers SIGPIPE in `ip` -> `set -o pipefail` would
        # kill the script. Disable pipefail just for this pipeline.
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
        local ifx
        ifx=$(cat /sys/class/net/macvtap0/ifindex)
        local tap_dev="/dev/tap${ifx}"
        if [ ! -e "$tap_dev" ]; then
            mknod "$tap_dev" c \
                "$(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f1)" \
                "$(cat /sys/devices/virtual/net/macvtap0/tap*/dev | cut -d: -f2)"
        fi
        local mac
        mac=$(cat /sys/class/net/macvtap0/address)
        exec 3<>"$tap_dev"
        QEMU_ARGS+=(
            -netdev tap,id=net0,fd=3
            -device "virtio-net-pci,netdev=net0,mac=$mac"
        )
    else
        echo "Networking: WARN no physical NIC detected — falling back to user-mode (slirp)."
        echo "  macOS recovery may report 'no internet' even though NAT works."
        echo "  Set HOST_IFACE=<name> or NETWORK_MODE=slirp to opt in deterministically."
        QEMU_ARGS+=(
            -netdev "user,id=net0,hostfwd=tcp::${hostfwd_port}-:22"
            -device virtio-net-pci,netdev=net0
        )
    fi
}

# ---------------------------------------------------------------------------
# Display device
# ---------------------------------------------------------------------------
# [macOS] Default for ALL macOS phases = vmware-svga from vanilla upstream
# QEMU. This is the April-2026 stable baseline that ran solidly:
# loginwindow + WindowServer + System Settings stay clean for hours under
# stock kexts. Resolution auto-negotiated by the macOS guest's
# VMwareSVGA driver; no EDID dance needed.
#
# [project] apple-gfx-pci (MOS_USE_APPLE_GFX_PCI=1) is the M5 paravirt
# target. Until libapplegfx-vulkan opcode handlers ship, the device
# renders nothing — opt in only when working the M5 path. Note that
# mos_hw_machine_args also has to see MOS_USE_APPLE_GFX_PCI=1 so it adds
# the memfd backend; call ORDER is: machine_args → display_args.
#
# [macOS] std-vga is NEVER a default option for macOS phases. It boots
# and renders, but causes GUI instability under userland load (System
# Settings hangs, loginwindow respawn) compared to vmware-svga on this
# kernel/QEMU stack — see mos-docs whitepapers.
# DISPLAY_DEVICE=std-vga remains as a quoted-with-warnings escape hatch
# for ad-hoc bisecting; it prints a loud warning and is NOT a default.
#
# Phase 0 (firmware-sanity, no macOS) is the ONE place std-vga is used,
# and it's hardcoded there — call mos_hw_display_phase0_stdvga_args
# instead. Other phases must call mos_hw_display_args.
mos_hw_display_args() {
    if [ "${MOS_USE_APPLE_GFX_PCI:-0}" = "1" ]; then
        local apple_gfx_device="-device apple-gfx-pci"
        local gpu_cores_raw="${GPU_CORES:-0}"
        if [[ "$gpu_cores_raw" =~ ^[0-9]+$ ]] && [ "$gpu_cores_raw" -gt 0 ]; then
            apple_gfx_device="-device apple-gfx-pci,gpu_cores=$gpu_cores_raw"
        fi
        # shellcheck disable=SC2206  # intentional word splitting on the device flag.
        QEMU_ARGS+=( -vga none $apple_gfx_device )
        echo "WARNING: MOS_USE_APPLE_GFX_PCI=1 — display will likely be blank"
        echo "  until libapplegfx-vulkan opcode handlers are implemented (M5)."
        return 0
    fi

    local device="${DISPLAY_DEVICE:-vmware-svga}"
    case "$device" in
        vmware-svga)
            QEMU_ARGS+=( -vga none -device vmware-svga )
            ;;
        std-vga)
            # Escape hatch only — never a default for macOS. Documented as
            # unstable on Sequoia; loginwindow respawn under userland load.
            echo "WARNING: DISPLAY_DEVICE=std-vga selected explicitly."
            echo "  std-vga is unstable on macOS Sequoia under userland load — System"
            echo "  Settings hangs, loginwindow respawns. Use only for bisecting."
            echo "  Documented in mos-docs whitepapers; vmware-svga is the supported default."
            QEMU_ARGS+=( -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on )
            ;;
        none)
            QEMU_ARGS+=( -vga none )
            ;;
        *)
            # Trust operator override — pass through verbatim. e.g.
            # DISPLAY_DEVICE='qxl-vga,vgamem_mb=64' for QXL.
            QEMU_ARGS+=( -device "$device" )
            ;;
    esac
}

# Phase-0 firmware-sanity display. std-vga is fine here because there's
# no macOS — we just need OVMF to render its boot manager output. NOT
# tunable; phase 0 always uses this exact device.
mos_hw_display_phase0_stdvga_args() {
    QEMU_ARGS+=( -device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on )
}

# ---------------------------------------------------------------------------
# Disk + boot media
# ---------------------------------------------------------------------------
# [macOS] OpenCore on AHCI/IDE — Apple's stock SATA driver
# (AppleAHCIPort) binds here. OpenCore.img must be on AHCI/IDE because
# OVMF's NVMe path doesn't see it on Q35 by default.
#
# [macOS] macOS system disk on virtio-blk — IOVirtIOBlock binds cleanly
# with no extra kexts (faster + lower CPU than emulated AHCI for the data
# disk). cache=none + aio=native are the standard "host page cache off,
# Linux AIO" choice that gives near-bare-metal disk perf.
#
# Args:
#   $1  opencore_path   path to OpenCore.img
#   $2  machdd_path     path to disk.img
#   $3  machdd_opts     extra options for the MacHDD drive line, e.g.
#                       "snapshot=on,file.locking=off" or "" for
#                       writeable+locked. Caller decides per-phase.
#   $4  install_media   (optional) path to recovery.img — when set, an
#                       install media ide-hd is attached at sata.3.
mos_hw_disk_args() {
    local opencore="$1"
    local machdd="$2"
    local machdd_opts="$3"
    local install_media="${4:-}"

    QEMU_ARGS+=(
        -device ich9-ahci,id=sata
        # OpenCore is loaded via IDE on the AHCI bus. snapshot=on because
        # OpenCore.img source-of-truth lives in this repo's efi/ directory;
        # runtime mutation is unwanted.
        -drive "id=OpenCoreBoot,if=none,format=raw,file=${opencore},snapshot=on"
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot
    )

    if [ -n "$install_media" ]; then
        # [project] install-only: recovery.img on sata.3 (snapshot=on so
        # the recovery image stays pristine). install.sh sets this.
        QEMU_ARGS+=(
            -drive "id=InstallMedia,if=none,file=${install_media},format=raw,snapshot=on"
            -device ide-hd,bus=sata.3,drive=InstallMedia
        )
    fi

    # MacHDD options vary per phase:
    #   prod (run.sh)        snapshot=on by default; persist=on when
    #                        MOS_PERSIST=1 (install path uses persist=on).
    #   test phases 1-3      snapshot=on,file.locking=off  (concurrent-safe ephemeral)
    #   test phases 3 (opt)  full persist when MOS_PHASE3_PERSIST=1
    #   test phase 9         full persist (interactive debug)
    # Caller passes the right opts string in $3. Empty string = bare line
    # (writeable + locked).
    local machdd_drive="id=MacHDD,if=none,file=${machdd},format=raw,cache=none,aio=native"
    if [ -n "$machdd_opts" ]; then
        machdd_drive="${machdd_drive},${machdd_opts}"
    fi
    QEMU_ARGS+=(
        -drive "$machdd_drive"
        -device virtio-blk-pci,drive=MacHDD
    )
}

# Phase-0 ephemeral disk attach (no OpenCore, no macOS). 1G empty raw on
# virtio-blk so OVMF iterates boot devices and falls through to PXE.
#
# Args:
#   $1  disk_path   path to phase 0's empty disk
mos_hw_disk_phase0_args() {
    local disk_path="$1"
    QEMU_ARGS+=(
        -drive "id=disk0,if=none,file=${disk_path},format=raw"
        -device virtio-blk-pci,drive=disk0
    )
}

# ---------------------------------------------------------------------------
# I/O — serial log + monitors + VNC
# ---------------------------------------------------------------------------
# [project] All I/O is observability — adapt to your stack's conventions
# if you're porting elsewhere.
#
# Args:
#   $1  serial_log     path to per-boot serial log file
#   $2  hmp_sock       path to HMP unix socket (interactive QEMU monitor)
#   $3  qmp_sock       path to QMP unix socket (JSON programmatic monitor)
#   $4  vnc_display    VNC display number (e.g. 0 → 5900, 4 → 5904)
#   $5  serial_style   "chardev" (run.sh's run-quietly chardev:file:append=off)
#                      or "file"    (test.sh's straight -serial file:)
mos_hw_io_args() {
    local serial_log="$1"
    local hmp_sock="$2"
    local qmp_sock="$3"
    local vnc_display="$4"
    local serial_style="${5:-chardev}"

    if [ "$serial_style" = "chardev" ]; then
        # [project] chardev wrapper around the serial log file lets us
        # share-name with HMP/QMP; append=off truncates per boot so each
        # session has its own clean log.
        QEMU_ARGS+=(
            -chardev "file,id=serial_file,path=${serial_log},append=off"
            -serial chardev:serial_file
        )
    else
        # [project] simpler `file:` form — survives QEMU exit without
        # truncation. Used by test.sh phases (one log per phase boot).
        QEMU_ARGS+=( -serial "file:${serial_log}" )
    fi

    QEMU_ARGS+=(
        # [project] HMP — interactive control via unix socket. Used by
        # `socat - unix-connect:$HMP_SOCK` for human ops, and by the
        # test runner for `screendump` (HMP is human-readable, QMP is JSON).
        -chardev "socket,id=hmp_sock,path=${hmp_sock},server=on,wait=off"
        -monitor chardev:hmp_sock

        # [project] QMP — JSON-over-unix programmatic control. Scripted
        # use: query-pci, send-key, system_powerdown, screendump.
        -qmp "unix:${qmp_sock},server=on,wait=off"

        # [project] VNC server bound to loopback only. Bundled noVNC
        # bridges 127.0.0.1:5900+N → 0.0.0.0:6080+N for browser access.
        # Loopback keeps QEMU off the host's open-port surface.
        -vnc "127.0.0.1:${vnc_display}"
    )
}

# ---------------------------------------------------------------------------
# NUMA pinning (echoes status; sets NUMA_PIN var on the caller)
# ---------------------------------------------------------------------------
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
# string to disable. No-op on single-node hosts.
#
# Sets the global NUMA_PIN to the prefix command (or empty). Caller does
# `exec $NUMA_PIN qemu ...`.
mos_hw_numa_pin() {
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
}

# ---------------------------------------------------------------------------
# Convenience: full standard macOS stack (used by run.sh + install.sh)
# ---------------------------------------------------------------------------
# Composes all the macOS-required helpers in the right order. test.sh
# does NOT use this — it picks helpers per-phase because phase 0 skips
# the macOS group, phase 4 swaps the display, etc.
#
# Caller is responsible for declaring QEMU_ARGS=() before sourcing /
# calling, and for adding -display, -d, -D and other [project]
# observability flags AFTER this returns.
mos_hw_macos_stack() {
    mos_hw_machine_args "${RAM:-16}"
    mos_hw_cpu_args
    mos_hw_smp_args
    mos_hw_firmware_args
    mos_hw_smbios_apple_args
    mos_hw_usb_args
    # display BEFORE netdev so the `WARNING:` line for apple-gfx-pci
    # appears before the macvtap status line — easier to skim.
    mos_hw_display_args
    mos_hw_netdev_args "${SSH_PORT:-22220}"
}
