# syntax=docker/dockerfile:1.7
# mos-docker — production image
# https://github.com/MattJackson/mos-docker
#
# Stages:
#   lagfx-builder   builds libapplegfx-vulkan from MattJackson/libapplegfx-vulkan
#   mos15-builder   builds QEMU 10.2.2 with mos-qemu patches (apple-gfx-pci, applesmc, dev-hid, vmware_vga)
#   final           alpine + patched QEMU + libapplegfx-vulkan + websockify/novnc + OVMF + scripts
#
# All persistent state lives in /data (bind mount required at runtime).
# Entrypoint dispatches based on first arg: install | run | test.

ARG QEMU_VERSION=10.2.2

# ---------------------------------------------------------------------------
# libapplegfx-vulkan builder
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS lagfx-builder

RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    mesa-vulkan-swrast vulkan-loader vulkan-headers vulkan-tools \
    bash curl

# Alpine ships libvulkan.so.1 but no vulkan.pc / libvulkan.so symlink.
RUN mkdir -p /usr/lib/pkgconfig \
    && printf 'Name: vulkan\nVersion: 1.3.296\nDescription: Vulkan loader\nLibs: -L/usr/lib -lvulkan\nCflags: -I/usr/include\n' \
    > /usr/lib/pkgconfig/vulkan.pc \
    && ln -sf libvulkan.so.1 /usr/lib/libvulkan.so

ADD https://github.com/MattJackson/libapplegfx-vulkan/archive/refs/heads/main.tar.gz /tmp/libapplegfx-vulkan.tar.gz
RUN mkdir -p /tmp/libapplegfx-vulkan \
    && tar xz -C /tmp/libapplegfx-vulkan --strip-components=1 -f /tmp/libapplegfx-vulkan.tar.gz \
    && cd /tmp/libapplegfx-vulkan \
    && meson setup --prefix=/usr --libdir=lib -Dtests=false /tmp/lagfx-build \
    && ninja -C /tmp/lagfx-build install

# ---------------------------------------------------------------------------
# QEMU + mos-qemu patches builder
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS mos15-builder
ARG QEMU_VERSION

RUN apk add --no-cache \
    build-base python3 ninja meson pkgconf \
    glib-dev pixman-dev libcap-ng-dev libseccomp-dev \
    libslirp-dev libaio-dev curl bash dtc-dev \
    mesa-vulkan-swrast vulkan-loader vulkan-headers \
    ccache

ENV PATH="/usr/lib/ccache/bin:${PATH}" \
    CCACHE_DIR=/root/.ccache \
    CCACHE_MAXSIZE=2G \
    CCACHE_BASEDIR=/tmp \
    CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,locale,pch_defines \
    CCACHE_COMPILERCHECK=content \
    CCACHE_NOHASHDIR=1

# Bring libapplegfx-vulkan into the build context (mos-qemu's
# hw/display/meson.build hard-requires it at configure time).
COPY --from=lagfx-builder /usr/lib/libapplegfx-vulkan.so* /usr/lib/
COPY --from=lagfx-builder /usr/lib/libvulkan.so /usr/lib/libvulkan.so

RUN mkdir -p /usr/lib/pkgconfig \
    && printf 'Name: vulkan\nVersion: 1.3.296\nDescription: Vulkan loader\nLibs: -L/usr/lib -lvulkan\nCflags: -I/usr/include\n' \
    > /usr/lib/pkgconfig/vulkan.pc

ADD https://download.qemu.org/qemu-10.2.2.tar.xz /tmp/qemu-upstream.tar.xz
ADD https://github.com/MattJackson/mos-qemu/archive/refs/heads/main.tar.gz /tmp/mos-qemu.tar.gz

RUN --mount=type=cache,target=/root/.ccache \
    --mount=type=cache,target=/tmp/qemu-build \
    rm -rf /tmp/qemu-${QEMU_VERSION} /tmp/mos-qemu \
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
    && ccache -s || true

# ---------------------------------------------------------------------------
# Final runtime image
# ---------------------------------------------------------------------------
FROM alpine:3.21

# Runtime deps: glib/pixman for QEMU, OVMF firmware, websockify+novnc for
# bundled VNC HTTP, vulkan-loader+lavapipe for libapplegfx-vulkan, socat for
# QMP/HMP debugging from the host, iproute2 for macvtap (when HOST_IFACE set).
RUN apk add --no-cache \
    glib pixman libcap-ng libseccomp libslirp \
    libaio libbz2 dtc bash iproute2 ovmf \
    socat coreutils \
    websockify novnc \
    vulkan-loader mesa-vulkan-swrast

# Patched QEMU + libapplegfx-vulkan
COPY --from=mos15-builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 /usr/bin/
COPY --from=mos15-builder /tmp/qemu-install/usr/bin/qemu-img /usr/bin/
COPY --from=mos15-builder /tmp/qemu-install/usr/share/qemu/ /usr/share/qemu/
COPY --from=lagfx-builder /usr/lib/libapplegfx-vulkan.so* /usr/lib/

# Clean OVMF_VARS template for NVRAM reset
RUN cp /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.clean.fd

# Dispatcher + sub-scripts
COPY scripts/entrypoint.sh /scripts/entrypoint.sh
COPY scripts/install.sh    /scripts/install.sh
COPY scripts/run.sh        /scripts/run.sh
RUN chmod +x /scripts/*.sh

# Sane defaults — overridable via env / docker run -e
ENV RAM=8 SMP=4 CORES=4 \
    GPU_CORES=0 \
    NOVNC_PORT=6080 VNC_PORT=5900

# noVNC web port (install mode + test mode); production typically uses
# external noVNC service so this is informational only.
EXPOSE 6080

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["run"]
