#!/bin/bash
# Sequentially build the phased docker chain: base → phase0 → ... → phaseN.
# Each phase image inherits FROM the previous, so the chain must be built
# in order before any phase compose can run.
#
# Usage:
#   scripts/build-phases.sh        # build full chain through phase 4
#   scripts/build-phases.sh 2      # build through phase 2 only
#   scripts/build-phases.sh --no-cache 4
set -euo pipefail

cd "$(dirname "$0")/.."

CACHE_FLAG=""
if [ "${1:-}" = "--no-cache" ]; then
    CACHE_FLAG="--no-cache"
    shift
fi

TARGET_PHASE="${1:-4}"
if ! [[ "$TARGET_PHASE" =~ ^[0-4]$ ]]; then
    echo "ERROR: target phase must be 0..4 (got '$TARGET_PHASE')" >&2
    exit 2
fi

build_image() {
    local tag="$1" dockerfile="$2"
    echo
    echo "=== building $tag (-f $dockerfile) ==="
    DOCKER_BUILDKIT=1 docker build $CACHE_FLAG -t "$tag" -f "$dockerfile" .
}

build_image mos-docker-base:latest   Dockerfile.base
build_image mos-docker-phase0:latest Dockerfile.phase0
[ "$TARGET_PHASE" -ge 1 ] && build_image mos-docker-phase1:latest Dockerfile.phase1
[ "$TARGET_PHASE" -ge 2 ] && build_image mos-docker-phase2:latest Dockerfile.phase2
[ "$TARGET_PHASE" -ge 3 ] && build_image mos-docker-phase3:latest Dockerfile.phase3
[ "$TARGET_PHASE" -ge 4 ] && build_image mos-docker-phase4:latest Dockerfile.phase4

echo
echo "=== built through phase $TARGET_PHASE ==="
docker images | grep -E "^mos-docker-(base|phase[0-4])\s" | sort
