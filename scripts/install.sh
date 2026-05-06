#!/bin/bash
# mos-docker install — install macOS into /data/disk.img via the recovery image.
#
# Refuses to overwrite an existing install. To reinstall, delete /data/disk.img
# manually first.
#
# After this runs, you can shut down the VM (from inside macOS) and use
# `docker run ... mos-docker run` to boot the installed system.
set -euo pipefail

DATA=/data
DISK="$DATA/disk.img"
RECOVERY="$DATA/recovery.img"
OPENCORE="$DATA/OpenCore.img"
DISK_SIZE="${DISK_SIZE:-256G}"

echo "================================================================"
echo "  mos-docker — install workflow"
echo "================================================================"

# --- Safety: refuse to overwrite an existing install --------------------
if [ -f "$DISK" ]; then
    SIZE=$(stat -Lc%s "$DISK")
    if [ "$SIZE" -gt 1048576 ]; then
        echo "ERROR: $DISK already exists ($(numfmt --to=iec "$SIZE")) — looks installed."
        echo "  Refusing to overwrite. To reinstall:"
        echo "    rm -f $DATA/disk.img    # on the host, NOT inside the container"
        echo "    docker run ... mos-docker install"
        exit 1
    fi
    echo "Existing $DISK is $SIZE bytes (<1 MiB) — treating as fresh install."
fi

# --- Stage recovery.img -------------------------------------------------
if [ ! -f "$RECOVERY" ]; then
    echo
    echo "Recovery image not found at $RECOVERY."
    echo
    echo "Acquire it once and drop it at \$HOST_MOS_DATA/recovery.img:"
    echo
    echo "  Option A: macrecovery.py (from any Mac or Linux with python3)"
    echo "    git clone https://github.com/acidanthera/OpenCorePkg"
    echo "    cd OpenCorePkg/Utilities/macrecovery"
    echo "    python3 macrecovery.py -b Mac-AA95B1DDAB278B95 \\"
    echo "      -m 00000000000000000 download"
    echo "    # produces BaseSystem.dmg + BaseSystem.chunklist + RecoveryHDMeta.dmg"
    echo "    dmg2img BaseSystem.dmg recovery.img"
    echo "    mv recovery.img \$HOST_MOS_DATA/"
    echo
    echo "  Option B: from another Mac with macOS already installed,"
    echo "    use 'createinstallmedia' or DiskUtility to export the InstallESD."
    echo
    echo "Then re-run: docker run ... mos-docker install"
    exit 1
fi
RECOVERY_SIZE=$(stat -Lc%s "$RECOVERY")
echo "Recovery image: $RECOVERY ($(numfmt --to=iec "$RECOVERY_SIZE"))"

# --- Stage OpenCore.img -------------------------------------------------
if [ ! -f "$OPENCORE" ]; then
    echo
    echo "OpenCore.img not found at $OPENCORE."
    echo "  Drop a built OpenCore EFI image (~512 MB FAT32) at this path."
    echo "  Build instructions: SETUP.md → 'Build OpenCore.img'"
    exit 1
fi
OPENCORE_SIZE=$(stat -Lc%s "$OPENCORE")
echo "OpenCore image: $OPENCORE ($(numfmt --to=iec "$OPENCORE_SIZE"))"

# --- Create the blank macOS disk ---------------------------------------
echo
echo "================================================================"
echo "  Creating fresh ${DISK_SIZE} disk at $DISK"
echo "  Aborting in 5 seconds — Ctrl-C now if this is wrong."
echo "================================================================"
sleep 5
qemu-img create -f raw "$DISK" "$DISK_SIZE"
echo "Disk created: $DISK ($DISK_SIZE)"

# --- Hand off to the QEMU launcher with install media attached ---------
echo
echo "================================================================"
echo "  Booting VM with macOS recovery media."
echo "  Connect via noVNC: http://<host>:6080/vnc.html?autoconnect=1"
echo
echo "  In the recovery installer:"
echo "    1. Disk Utility → erase the virtio disk as APFS"
echo "    2. Quit Disk Utility → 'Reinstall macOS'"
echo "    3. Wait ~30-60 min for install to complete"
echo "    4. After install reboots, finish Setup Assistant"
echo "    5. Shut down (Apple menu) — container will exit"
echo "    6. docker run ... mos-docker run"
echo "================================================================"
echo

# Boot via the shared QEMU launcher with install media + bundled noVNC.
# Install MUST persist writes to disk.img — that's the whole point of installing.
# (run.sh defaults to snapshot=on for safety; install opts in to writeable.)
export MOS_QEMU_INSTALL_MEDIA="$RECOVERY"
export MOS_QEMU_BUNDLED_NOVNC=1
export MOS_PERSIST=1
exec /scripts/run.sh
