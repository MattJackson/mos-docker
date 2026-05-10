# syntax=docker/dockerfile:1.7
# mos-docker — production runtime image
# https://github.com/MattJackson/mos-docker
#
# Slim runtime that COPYs prebuilt QEMU + libapplegfx-vulkan from GHCR
# artifact images instead of compiling them. The patched-QEMU build
# (~3-4 min) runs once per push to mos-qemu via that repo's CI workflow
# and publishes ghcr.io/mattjackson/mos-qemu-patched:<sha>. This image
# pulls those layers and adds runtime deps + scripts in ~30s.
#
# Image override: set the build args below to pin a specific (qemu, oem)
# pair, otherwise the latest main + version-default tags are used.
#
# All persistent state lives in /data (bind mount required at runtime).
# Entrypoint dispatches based on first arg: install | run | test.

# Patched QEMU image tag. `main` = latest mos-qemu push to main branch.
# Pin to a specific commit-sha tag (or :<sha>-lagfx-<sha>) for fully
# reproducible builds.
ARG MOSQEMU_IMAGE=ghcr.io/mattjackson/mos-qemu-patched:main

# OEM (vanilla upstream) QEMU. Pinned to QEMU release version since the
# binary is invariant per release.
ARG OEM_QEMU_IMAGE=ghcr.io/mattjackson/mos-qemu-oem:11.0.0

# ---------------------------------------------------------------------------
# Pull in artifact images. These are `FROM scratch` images with /usr/*
# layout containing the QEMU install tree. Pulling is just a layer
# fetch; nothing executes here.
# ---------------------------------------------------------------------------
FROM ${MOSQEMU_IMAGE} AS qemu-patched
FROM ${OEM_QEMU_IMAGE} AS qemu-oem

# ---------------------------------------------------------------------------
# OpenCore.img builder — fast (~30s), depends on efi/ source so it stays
# in this repo (efi files change here, not in mos-qemu).
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS opencore-builder
RUN apk add --no-cache dosfstools mtools
COPY efi /tmp/efi
RUN truncate -s 512M /tmp/OpenCore.img \
    && mkfs.vfat -F 32 -n OPENCORE /tmp/OpenCore.img \
    && mmd -i /tmp/OpenCore.img ::EFI \
    && mmd -i /tmp/OpenCore.img ::EFI/BOOT \
    && mmd -i /tmp/OpenCore.img ::EFI/OC \
    && for d in /tmp/efi/EFI/BOOT /tmp/efi/EFI/OC; do \
           cd "$d" && find . -type d ! -path . | while read sub; do \
               mmd -i /tmp/OpenCore.img "::EFI/$(basename $d)/${sub#./}" 2>/dev/null || true; \
           done; \
       done \
    && cd /tmp/efi && find EFI -type f -exec mcopy -i /tmp/OpenCore.img {} ::{} \; \
    && echo "OpenCore.img built ($(stat -c%s /tmp/OpenCore.img) bytes from $(find efi -type f | wc -l) source files)"

# ---------------------------------------------------------------------------
# Final runtime image — alpine + runtime libs + QEMU binaries + scripts.
# Layer order is stable → volatile so script-only edits don't bust
# anything heavier.
# ---------------------------------------------------------------------------
FROM alpine:3.21

# 1. Heavy runtime deps (rarely changes — keep this layer hot).
#    glib/pixman/libcap-ng/libseccomp/libslirp/libaio/libbz2/dtc/vulkan-loader
#    are dynamic-link deps of the patched QEMU + libapplegfx-vulkan binaries
#    we COPY in below.
RUN apk add --no-cache \
    glib pixman libcap-ng libseccomp libslirp \
    libaio libbz2 dtc bash iproute2 ovmf \
    socat coreutils numactl numactl-tools \
    websockify novnc \
    vulkan-loader mesa-vulkan-swrast \
    chromium xvfb py3-pillow

# 2. NVRAM template (depends only on apk above).
RUN cp /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.clean.fd

# 3. Patched QEMU + libapplegfx-vulkan from GHCR. Single COPY of the
#    full /usr tree from the artifact image — files include
#    /usr/bin/qemu-system-x86_64, /usr/bin/qemu-img, /usr/share/qemu/*,
#    /usr/lib/libapplegfx-vulkan.so*. Layer invalidates whenever
#    MOSQEMU_IMAGE tag (and therefore the image content) changes.
COPY --from=qemu-patched /usr /usr

# 4. OEM (vanilla upstream) QEMU binary alongside the patched one.
#    test.sh selects between them by phase number (phase 1 = OEM bisect).
COPY --from=qemu-oem /usr/bin/qemu-system-x86_64 /usr/bin/qemu-system-x86_64-oem

# 5. OpenCore.img — built from this repo's efi/ source.
COPY --from=opencore-builder /tmp/OpenCore.img /usr/share/mos-docker/OpenCore.img

# 6. Dispatcher + sub-scripts (volatile — change frequently).
#    scripts/lib/ holds shared sourced libraries (e.g. hw-args.sh —
#    single source of truth for QEMU hardware config consumed by
#    run.sh / test.sh / install.sh-via-run).
COPY scripts/lib           /scripts/lib
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
COPY scripts/install.sh    /scripts/install.sh
COPY scripts/run.sh        /scripts/run.sh
COPY scripts/test.sh       /scripts/test.sh
RUN chmod +x /scripts/*.sh

# Sane defaults — overridable via env / docker run -e.
ENV RAM=8 SMP=4 CORES=4 \
    GPU_CORES=0 \
    NOVNC_PORT=6080 VNC_PORT=5900

# noVNC web ports — 6080 install/run, 6081-6084 test phases 1-4, 6089 phase 9.
EXPOSE 6080 6081 6082 6083 6084 6089

ENTRYPOINT ["/scripts/entrypoint.sh"]
