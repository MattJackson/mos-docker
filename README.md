# docker-macos

macOS in Docker. Alpine + QEMU/KVM + OpenCore — built from source, no third-party runtime dependencies.

## Component Versions

| Component | Version | Source | Date |
|-----------|---------|--------|------|
| QEMU | 10.2.2 | Built from source ([qemu.org](https://download.qemu.org/)) | 2025 |
| OpenCore | 1.0.7 | [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) | Mar 2025 |
| Lilu | 1.7.2 | [acidanthera/Lilu](https://github.com/acidanthera/Lilu) | 2025 |
| VirtualSMC | 1.3.7 | [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC) | 2025 |
| WhateverGreen | 1.7.0 | [acidanthera/WhateverGreen](https://github.com/acidanthera/WhateverGreen) | 2025 |
| CryptexFixup | 1.0.5 | [acidanthera/CryptexFixup](https://github.com/acidanthera/CryptexFixup) | 2025 |
| OVMF | Alpine 3.21 | Alpine repos | 2024 |
| Alpine Linux | 3.21 | Base image | 2024 |

No code from sickcodes/Docker-OSX, KVM-Opencore, or other stale community projects.

## Supported macOS Versions

| Version | Status | Screen Sharing | Notes |
|---------|--------|---------------|-------|
| **Sequoia (15)** | Working | Native macOS Screen Sharing | Recommended. Full desktop via `vnc://VM_IP`. |
| **Tahoe (26)** | Boots & installs | noVNC only | WindowServer crashes with native Screen Sharing (virtual GPU compositor issue). |

## Requirements

- Linux host with Intel VT-x / KVM
- `/dev/kvm` accessible
- Docker
- Host network interface for bridged networking

## Quick Start

### 1. Build files (not in git — too large)

**BaseSystem.img** — macOS recovery image (~1GB from Apple):
```bash
docker run --rm -v "$PWD":/out sickcodes/docker-osx:latest sh -c \
  'python3 /home/arch/OSX-KVM/fetch-macOS-v2.py --shortname=sequoia -o /tmp && \
   qemu-img convert /tmp/BaseSystem.dmg -O qcow2 -p -c /out/BaseSystem.img'
```

**OpenCore.qcow2** — bootloader disk (built from latest components):
```bash
# See "Building OpenCore" section below
```

### 2. Build and run

```bash
touch mac_hdd_ng.img
docker compose up -d
```

### 3. Connect

- **noVNC:** `http://localhost:6080` (browser, always works)
- **Screen Sharing:** `vnc://VM_IP` (native macOS client, Sequoia only)
- **SSH:** `ssh user@VM_IP` (enable in macOS Sharing settings)

### 4. First install

1. Open **Disk Utility** > erase the 256GB drive as **APFS** / **GUID Partition Map**
2. Install macOS (downloads ~13GB from Apple)
3. Boot picker auto-selects after 5 seconds during reboots

## Architecture

```
Container (Alpine 3.21)
├── QEMU 10.2.2 (built from source)
│   ├── KVM acceleration (-cpu host)
│   ├── macvtap bridged networking (LAN IP)
│   ├── VNC display (localhost:5901)
│   └── Raw disk with direct I/O
├── OVMF (UEFI firmware)
├── OpenCore 1.0.7 (bootloader)
│   ├── Lilu 1.7.2
│   ├── VirtualSMC 1.3.7
│   ├── WhateverGreen 1.7.0
│   └── CryptexFixup 1.0.5
└── BaseSystem.img (macOS recovery)
```

## Key Technical Decisions

- **`-cpu host`** — Required for Tahoe. Penryn emulation causes dyld shared cache failures
- **`iMac20,1` SMBIOS** — Required for Tahoe. One of 4 Intel models Apple supports on macOS 26
- **Raw disk + `cache=none,aio=native`** — Direct I/O bypasses QEMU's userspace buffering. Dramatically faster than qcow2
- **macvtap bridge** — VM gets its own LAN IP. Required for Content Caching and Bonjour discovery
- **QEMU VNC on localhost** — Binding to `0.0.0.0` intercepts macOS Screen Sharing connections
- **Smart install detection** — Recovery drive auto-attached when disk is empty, removed after install

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RAM` | `4` | RAM in GB |
| `SMP` | `4` | CPU threads |
| `CORES` | `4` | CPU cores |
| `HOST_IFACE` | `enp131s0f0` | Host network interface for bridge |
| `IMAGE_PATH` | `/opt/macos/mac_hdd_ng.img` | Virtual disk path |
| `NETWORKING` | `vmxnet3` | Network adapter type |
| `EXTRA` | | Additional QEMU arguments |

## Building OpenCore

```bash
# Download components
curl -sL -o oc.zip https://github.com/acidanthera/OpenCorePkg/releases/download/1.0.7/OpenCore-1.0.7-RELEASE.zip
curl -sL -o lilu.zip https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip
curl -sL -o vsmc.zip https://github.com/acidanthera/VirtualSMC/releases/download/1.3.7/VirtualSMC-1.3.7-RELEASE.zip
curl -sL -o weg.zip https://github.com/acidanthera/WhateverGreen/releases/download/1.7.0/WhateverGreen-1.7.0-RELEASE.zip
curl -sL -o cf.zip https://github.com/acidanthera/CryptexFixup/releases/download/1.0.5/CryptexFixup-1.0.5-RELEASE.zip

# Assemble EFI, edit config.plist, build FAT disk with mtools
# See build scripts in this repo
```

## Display Limitations

The virtual GPU (`vmware-svga`) has no Metal/OpenGL acceleration:
- macOS reports 7MB VRAM (Apple driver limitation, not QEMU)
- No desktop wallpaper (compositor needs GPU)
- Display shows as "Unknown Display" (no EDID in vmware-svga)
- Screen Sharing works on Sequoia, crashes WindowServer on Tahoe

GPU passthrough (PCIe AMD card) resolves all display issues.

## License

GPL-3.0
