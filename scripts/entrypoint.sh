#!/bin/bash
# mos-docker entrypoint — dispatcher.
#
# Usage (inside container):
#   docker run ... mos-docker install   → run install workflow
#   docker run ... mos-docker run       → boot installed macOS (default)
#   docker run ... mos-docker test 0..4 → regression test phase
#
# Each sub-command is a separate script in /scripts/. This file's job is just
# to validate the runtime environment and dispatch.
set -euo pipefail

# Resolve mode: first arg, falls back to $MOS_MODE, falls back to "run".
MODE="${1:-${MOS_MODE:-run}}"
shift || true   # drop the mode arg so sub-scripts see remaining args

# Sanity: KVM must be present for any QEMU launch (install/run/test all need it).
if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm not present in container." >&2
    echo "  Run docker with: --device /dev/kvm  (or --privileged)" >&2
    echo "  Host needs CPU virtualization enabled in BIOS + kvm module loaded." >&2
    exit 1
fi
if [ ! -w /dev/kvm ]; then
    echo "ERROR: /dev/kvm exists but not writable from container." >&2
    echo "  Add the container user to group 'kvm', or run as root via --privileged." >&2
    exit 1
fi

# Sanity: /data must be a writable bind mount for state to survive container removal.
if [ ! -d /data ]; then
    echo "ERROR: /data is not mounted." >&2
    echo "  Run docker with: -v /path/to/host/dir:/data" >&2
    echo "  This is where disk.img / OpenCore.img / recovery.img / logs/ live." >&2
    exit 1
fi
if [ ! -w /data ]; then
    echo "ERROR: /data is not writable from inside the container." >&2
    echo "  Check ownership of the host bind-mount directory." >&2
    exit 1
fi

mkdir -p /data/logs /data/run

case "$MODE" in
    install)
        exec /scripts/install.sh "$@"
        ;;
    run)
        exec /scripts/run.sh "$@"
        ;;
    test)
        exec /scripts/test.sh "$@"
        ;;
    *)
        echo "ERROR: unknown mode '$MODE'" >&2
        echo "  Valid modes: install, run, test" >&2
        echo "  Examples:" >&2
        echo "    docker run ... mos-docker install" >&2
        echo "    docker run ... mos-docker run" >&2
        echo "    docker run ... mos-docker test 0" >&2
        exit 2
        ;;
esac
