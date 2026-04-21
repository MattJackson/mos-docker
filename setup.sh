#!/bin/bash
# setup.sh -- stage per-deployment artifacts for mos-docker.
#
# This script is idempotent. Run it on the Linux host where you'll run
# `docker compose up -d`. It prepares ./volumes/ with the three runtime
# bind-mount artifacts (disk.img, recovery.img, opencore.img) and the
# operator-local output dirs (logs/, run/).
#
# See volumes/README.md for what each artifact is and how it's produced.
#
# Environment overrides:
#   DISK_SIZE          default 256G. Sparse-allocated on first launch by
#                      launch.sh's qemu-img create; we only touch an empty
#                      file here.
#   RECOVERY_URL       if set, curl fetches recovery.img from this URL.
#                      Useful when you've pre-staged the ~3 GB file on an
#                      internal artifact store. Leave unset to see
#                      pointers to macrecovery.py instead.
#   OPENCORE_SRC       path to a prebuilt opencore.img on this host; if
#                      set, setup.sh cp's it into volumes/. Otherwise
#                      setup.sh prints build instructions.
#   FORCE              if "1", overwrite existing volumes/*.img files.
#                      Default: skip files that already exist and look
#                      non-empty.

set -euo pipefail

cd "$(dirname "$0")"

VOLUMES="./volumes"
DISK_IMG="${VOLUMES}/disk.img"
RECOVERY_IMG="${VOLUMES}/recovery.img"
OPENCORE_IMG="${VOLUMES}/opencore.img"
LOG_DIR="./logs"
RUN_DIR="./run"

DISK_SIZE="${DISK_SIZE:-256G}"
RECOVERY_URL="${RECOVERY_URL:-}"
OPENCORE_SRC="${OPENCORE_SRC:-}"
FORCE="${FORCE:-0}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "Ensuring ${VOLUMES}/ ${LOG_DIR}/ ${RUN_DIR}/ exist"
mkdir -p "${VOLUMES}" "${LOG_DIR}" "${RUN_DIR}"

# ---------- disk.img -------------------------------------------------------
# launch.sh treats anything <1 MiB as install mode and qemu-img creates at
# DISK_SIZE on first boot. We just materialise the empty file so docker's
# bind-mount points at a regular file (not an auto-created directory).
if [ "${FORCE}" = "1" ] || [ ! -e "${DISK_IMG}" ]; then
    log "Creating empty ${DISK_IMG} (launch.sh will size to ${DISK_SIZE} on first boot)"
    : >"${DISK_IMG}"
else
    size=$(stat -Lc%s "${DISK_IMG}" 2>/dev/null || echo 0)
    if [ "${size}" -lt 1048576 ]; then
        log "${DISK_IMG} exists and is ${size} bytes -- install mode on next boot"
    else
        log "${DISK_IMG} exists and is ${size} bytes -- boot mode on next boot"
    fi
fi

# ---------- recovery.img ---------------------------------------------------
recovery_ok=0
if [ -s "${RECOVERY_IMG}" ] && [ "${FORCE}" != "1" ]; then
    size=$(stat -Lc%s "${RECOVERY_IMG}" 2>/dev/null || echo 0)
    log "${RECOVERY_IMG} already present (${size} bytes) -- skipping"
    recovery_ok=1
elif [ -n "${RECOVERY_URL}" ]; then
    log "Fetching recovery.img from RECOVERY_URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "${RECOVERY_IMG}" "${RECOVERY_URL}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${RECOVERY_IMG}" "${RECOVERY_URL}"
    else
        die "neither curl nor wget available to fetch RECOVERY_URL"
    fi
    recovery_ok=1
else
    cat <<'MSG' >&2
WARN: volumes/recovery.img is missing and RECOVERY_URL is not set.
      This file is Apple's recovery DMG converted to raw (~3.2 GB).
      Produce it once with:

          # on any macOS host
          cd /path/to/OpenCorePkg/Utilities/macrecovery
          python3 macrecovery.py -b Mac-AA95B1DDAB278B95 \
              -m 00000000000000000 download
          dmg2img BaseSystem.dmg recovery.img
          # copy to this host at docker-macos/volumes/recovery.img

      Or set RECOVERY_URL=... to fetch from an internal mirror and
      rerun setup.sh. See volumes/README.md for full details.
MSG
fi

# ---------- opencore.img ---------------------------------------------------
opencore_ok=0
if [ -s "${OPENCORE_IMG}" ] && [ "${FORCE}" != "1" ]; then
    size=$(stat -Lc%s "${OPENCORE_IMG}" 2>/dev/null || echo 0)
    log "${OPENCORE_IMG} already present (${size} bytes) -- skipping"
    opencore_ok=1
elif [ -n "${OPENCORE_SRC}" ]; then
    [ -s "${OPENCORE_SRC}" ] || die "OPENCORE_SRC='${OPENCORE_SRC}' not found or empty"
    log "Copying OPENCORE_SRC=${OPENCORE_SRC} -> ${OPENCORE_IMG}"
    cp "${OPENCORE_SRC}" "${OPENCORE_IMG}"
    opencore_ok=1
else
    cat <<'MSG' >&2
WARN: volumes/opencore.img is missing.
      Build on a macOS host (hdiutil + newfs_msdos are required):

          cd /path/to/mos/docker-macos
          ./build-mos15-img.sh
          cp builds/mos15_*.img volumes/opencore.img

      Or set OPENCORE_SRC=/path/to/prebuilt.img and rerun setup.sh.
      See volumes/README.md for the full build pipeline (mos15-patcher,
      QEMUDisplayPatcher, SystemKernelExtensions.kc inputs).
MSG
fi

# ---------- summary --------------------------------------------------------
echo
log "Summary"
printf '  %-26s %s\n' "disk.img"     "$(ls -lh "${DISK_IMG}" 2>/dev/null | awk '{print $5, $9}')"
if [ "${recovery_ok}" = "1" ]; then
    printf '  %-26s %s\n' "recovery.img"     "$(ls -lh "${RECOVERY_IMG}" 2>/dev/null | awk '{print $5, $9}')"
else
    printf '  %-26s %s\n' "recovery.img"     "MISSING"
fi
if [ "${opencore_ok}" = "1" ]; then
    printf '  %-26s %s\n' "opencore.img"     "$(ls -lh "${OPENCORE_IMG}" 2>/dev/null | awk '{print $5, $9}')"
else
    printf '  %-26s %s\n' "opencore.img"     "MISSING"
fi

if [ "${recovery_ok}" = "1" ] && [ "${opencore_ok}" = "1" ]; then
    cat <<'MSG'

Ready.

Next:
    docker compose build
    docker compose up -d
    docker logs -f mos-docker-macos-1   # or whatever your compose project names it

If this is a first boot, the VM enters install mode automatically because
disk.img is empty. Open noVNC at http://localhost:6080 and step through
the macOS installer (see SETUP.md step 6).
MSG
    exit 0
else
    cat <<'MSG' >&2

Not ready -- stage the missing artifact(s) above and rerun ./setup.sh.
MSG
    exit 1
fi
