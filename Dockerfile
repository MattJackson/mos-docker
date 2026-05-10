# syntax=docker/dockerfile:1.7
# mos-docker — production image
# https://github.com/MattJackson/mos-docker
#
# Single-builder design: libapplegfx-vulkan installs to /usr first, then
# QEMU configures against it via pkg-config in the same stage. Cleaner
# than multi-stage cross-COPY because libapplegfx-vulkan installs .so +
# .pc + headers atomically and we don't have to enumerate every file
# meson needs at QEMU configure time.
#
# All persistent state lives in /data (bind mount required at runtime).
# Entrypoint dispatches based on first arg: install | run | test.

ARG QEMU_VERSION=11.0.0

# ---------------------------------------------------------------------------
# Builder: libapplegfx-vulkan + patched QEMU 11.0.0
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS builder
ARG QEMU_VERSION

RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash dtc-dev \
    mesa-vulkan-swrast vulkan-loader vulkan-headers vulkan-tools \
    ccache

ENV PATH="/usr/lib/ccache/bin:${PATH}" \
    CCACHE_DIR=/root/.ccache \
    CCACHE_MAXSIZE=2G \
    CCACHE_BASEDIR=/tmp \
    CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,pch_defines \
    CCACHE_COMPILERCHECK=content \
    CCACHE_NOHASHDIR=1

# Alpine ships libvulkan.so.1 but no vulkan.pc / libvulkan.so symlink.
RUN mkdir -p /usr/lib/pkgconfig \
    && printf 'Name: vulkan\nVersion: 1.3.296\nDescription: Vulkan loader\nLibs: -L/usr/lib -lvulkan\nCflags: -I/usr/include\n' \
    > /usr/lib/pkgconfig/vulkan.pc \
    && ln -sf libvulkan.so.1 /usr/lib/libvulkan.so

# Build libapplegfx-vulkan first so QEMU's mos-qemu meson.build finds it
# at configure time. ADD re-checks upstream; a push to the lib only
# invalidates this layer + downstream. SHA pin ensures the URL itself
# changes when the source advances, so layer cache invalidates without
# needing --no-cache (default `main` keeps existing CI working).
ARG LIBAPPLEGFX_SHA=main
ADD https://github.com/MattJackson/libapplegfx-vulkan/archive/${LIBAPPLEGFX_SHA}.tar.gz /tmp/libapplegfx-vulkan.tar.gz
RUN --mount=type=cache,target=/root/.ccache \
    mkdir -p /tmp/libapplegfx-vulkan \
    && tar xz -C /tmp/libapplegfx-vulkan --strip-components=1 -f /tmp/libapplegfx-vulkan.tar.gz \
    && cd /tmp/libapplegfx-vulkan \
    && meson setup --prefix=/usr --libdir=lib -Dtests=false /tmp/lagfx-build \
    && ninja -C /tmp/lagfx-build install

# Build QEMU with mos-qemu patches.
ADD https://download.qemu.org/qemu-11.0.0.tar.xz /tmp/qemu-upstream.tar.xz
ARG MOSQEMU_SHA=main
ADD https://github.com/MattJackson/mos-qemu/archive/${MOSQEMU_SHA}.tar.gz /tmp/mos-qemu.tar.gz

# ccache is content-hashed (safe across source changes); the meson build dir
# is not (mtime-based, mis-decides on cached `.o` reuse — see lessons below).
RUN --mount=type=cache,target=/root/.ccache \
    rm -rf /tmp/qemu-${QEMU_VERSION} /tmp/mos-qemu /tmp/qemu-build \
    && mkdir -p /tmp/qemu-build \
    && tar xJ -C /tmp -f /tmp/qemu-upstream.tar.xz \
    && mkdir -p /tmp/mos-qemu \
    && tar xz -C /tmp/mos-qemu --strip-components=1 -f /tmp/mos-qemu.tar.gz \
    && cd /tmp/qemu-${QEMU_VERSION} \
    && cp /tmp/mos-qemu/hw/misc/applesmc.c hw/misc/applesmc.c \
    && cp /tmp/mos-qemu/hw/display/vmware_vga.c hw/display/vmware_vga.c \
    && cp /tmp/mos-qemu/hw/usb/dev-hid.c hw/usb/dev-hid.c \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-pci-linux.c hw/display/ \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-common-linux.c hw/display/ \
    && cp /tmp/mos-qemu/hw/display/apple-gfx-linux.h hw/display/ \
    && cp /tmp/mos-qemu/hw/display/meson.build hw/display/meson.build \
    && cp /tmp/mos-qemu/hw/display/trace-events hw/display/trace-events \
    && cp /tmp/mos-qemu/hw/display/Kconfig hw/display/Kconfig \
    && cp /tmp/mos-qemu/pc-bios/meson.build pc-bios/meson.build \
    && cp /tmp/mos-qemu/pc-bios/apple-gfx-pci.rom pc-bios/apple-gfx-pci.rom \
    && cd /tmp/qemu-build \
    && /tmp/qemu-${QEMU_VERSION}/configure \
        --target-list=x86_64-softmmu \
        --prefix=/usr \
        --enable-kvm --enable-slirp --enable-linux-aio \
        --enable-cap-ng --enable-seccomp --enable-vnc \
        --disable-docs --disable-debug-info --disable-werror \
    && make -j$(nproc) \
    && make DESTDIR=/tmp/qemu-install install \
    ; ccache -s || true

# Build-time smoke test: VERSION-pinned. Fails loudly if the binary doesn't
# match QEMU_VERSION (catches stale-cache + silent-build-failure regressions)
# or if the overlay marker is missing. Bump the marker string when re-validating.
RUN BUILT_VER=$(/tmp/qemu-install/usr/bin/qemu-system-x86_64 --version 2>&1 | head -1) \
    && echo "$BUILT_VER" \
    && echo "$BUILT_VER" | grep -q "version ${QEMU_VERSION}" \
    || (echo "STALE BUILD: binary is '$BUILT_VER', expected version ${QEMU_VERSION}. Run: docker builder prune --all" && exit 1) \
    && grep -q "initial_surface_pushed" /tmp/qemu-${QEMU_VERSION}/hw/display/apple-gfx-common-linux.c \
    || (echo "STALE BUILD: source missing initial_surface_pushed marker" && exit 1)

# ---------------------------------------------------------------------------
# OEM (vanilla upstream) QEMU 11.0.0 builder
# ---------------------------------------------------------------------------
# Phase 1 of the regression chain bisects "is the patched binary the
# regression cause?" by booting the same args under unpatched upstream
# QEMU. Built once here so it ships in the image alongside the patched
# binary; test.sh selects between them by phase number.
FROM alpine:3.21 AS oem-builder
ARG QEMU_VERSION

RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash dtc-dev \
    ccache

ENV PATH="/usr/lib/ccache/bin:${PATH}" \
    CCACHE_DIR=/root/.ccache \
    CCACHE_MAXSIZE=2G \
    CCACHE_BASEDIR=/tmp \
    CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,pch_defines \
    CCACHE_COMPILERCHECK=content \
    CCACHE_NOHASHDIR=1

ADD https://download.qemu.org/qemu-11.0.0.tar.xz /tmp/qemu-upstream.tar.xz

RUN --mount=type=cache,target=/root/.ccache \
    rm -rf /tmp/qemu-${QEMU_VERSION} /tmp/qemu-build \
    && mkdir -p /tmp/qemu-build \
    && tar xJ -C /tmp -f /tmp/qemu-upstream.tar.xz \
    && cd /tmp/qemu-build \
    && /tmp/qemu-${QEMU_VERSION}/configure \
        --target-list=x86_64-softmmu \
        --prefix=/usr \
        --enable-kvm --enable-slirp --enable-linux-aio \
        --enable-cap-ng --enable-seccomp --enable-vnc \
        --disable-docs --disable-debug-info --disable-werror \
    && make -j$(nproc) \
    && make DESTDIR=/tmp/qemu-install install \
    && ccache -s || true

# ---------------------------------------------------------------------------
# OpenCore.img builder
# ---------------------------------------------------------------------------
# Builds a 512 MB FAT32 EFI image from `efi/EFI/` in the repo. This is the
# single source of truth for the bootloader config; the resulting .img is
# embedded in the runtime image at /usr/share/mos-docker/OpenCore.img and
# install.sh/entrypoint.sh copy it to /data/OpenCore.img on first run.
# Rebuilds whenever any file under efi/ changes.
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
# Final runtime image
# ---------------------------------------------------------------------------
FROM alpine:3.21

# Runtime deps: glib/pixman for QEMU, OVMF firmware, websockify+novnc for
# bundled VNC HTTP (install + test modes), vulkan-loader+lavapipe for
# libapplegfx-vulkan, socat for QMP/HMP debugging from host, iproute2 for
# macvtap (when HOST_IFACE set), coreutils for numfmt.
RUN apk add --no-cache \
    glib pixman libcap-ng libseccomp libslirp \
    libaio libbz2 dtc bash iproute2 ovmf \
    socat coreutils \
    websockify novnc \
    vulkan-loader mesa-vulkan-swrast \
    chromium xvfb py3-pillow

# Layer order: stable → volatile. The 32MB qemu binary COPY changes
# every iteration (mos-qemu source advances), so put the rarely-changing
# OVMF prep + dispatcher scripts ABOVE it. A scripts-only edit then
# keeps the binary COPY layer cached and skips the 32MB+ re-export.

# Clean OVMF_VARS template for NVRAM reset (depends only on the apk above).
RUN cp /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.clean.fd

# Dispatcher + sub-scripts. Edits here do NOT invalidate the binary COPYs below.
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
COPY scripts/install.sh    /scripts/install.sh
COPY scripts/run.sh        /scripts/run.sh
COPY scripts/test.sh       /scripts/test.sh
RUN chmod +x /scripts/*.sh

# OpenCore.img built from efi/ in the repo. Independent of the qemu
# builder; placed above the qemu binary COPYs so an efi-only change
# (also rare) doesn't bust the binary layer.
COPY --from=opencore-builder /tmp/OpenCore.img /usr/share/mos-docker/OpenCore.img

# Patched QEMU + libapplegfx-vulkan from the builder. These COPYs invalidate
# every iteration, so they live at the BOTTOM of the stable prefix.
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/bin/qemu-img /usr/bin/
COPY --from=builder /tmp/qemu-install/usr/share/qemu/ /usr/share/qemu/
COPY --from=builder /usr/lib/libapplegfx-vulkan.so* /usr/lib/

# OEM (vanilla upstream) QEMU binary alongside the patched one; test.sh
# uses it for phase 1 of the regression chain.
COPY --from=oem-builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/qemu-system-x86_64-oem

# Sane defaults — overridable via env / docker run -e.
ENV RAM=8 SMP=4 CORES=4 \
    GPU_CORES=0 \
    NOVNC_PORT=6080 VNC_PORT=5900

# noVNC web ports — 6080 install/run, 6081-6084 test phases 1-4.
EXPOSE 6080 6081 6082 6083 6084

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["run"]
