# docker-macos

macOS in Docker. QEMU 10.2.2 + OpenCore 1.0.7 — built from source, no third-party runtime dependencies.

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| QEMU | 10.2.2 | Built from source ([qemu.org](https://download.qemu.org/)) |
| OpenCore | 1.0.7 | [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) |
| Lilu | 1.7.2 | [acidanthera/Lilu](https://github.com/acidanthera/Lilu) |
| VirtualSMC | 1.3.7 | [acidanthera/VirtualSMC](https://github.com/acidanthera/VirtualSMC) |
| WhateverGreen | 1.7.0 | [acidanthera/WhateverGreen](https://github.com/acidanthera/WhateverGreen) |
| CryptexFixup | 1.0.5 | [acidanthera/CryptexFixup](https://github.com/acidanthera/CryptexFixup) |
| OVMF | Alpine 3.21 | Alpine repos |
| Alpine Linux | 3.21 | Base image |

## Supported macOS Versions

| Version | Status | Screen Sharing |
|---------|--------|---------------|
| **Sequoia (15)** | Working | Native `vnc://VM_IP` |
| **Tahoe (26)** | Boots & installs | noVNC only (WindowServer crash on virtual GPU) |

## Requirements

- Linux host with Intel VT-x / KVM
- `/dev/kvm` accessible
- Docker

## Quick Start

### 1. Build files (not in git)

**Recovery image** (~1GB from Apple, ~3GB raw):
```bash
docker run --rm -v "$PWD":/out sickcodes/docker-osx:latest sh -c \
  'python3 /home/arch/OSX-KVM/fetch-macOS-v2.py --shortname=sequoia -o /tmp && \
   qemu-img convert /tmp/BaseSystem.dmg -O raw /out/sequoia_recovery.img'
```

**OpenCore bootdisk** — see [Building OpenCore](#building-opencore) below.

### 2. Build and run

Set `HOST_IFACE` in `docker-compose.yml` to your host's physical network interface.

```bash
touch mac_hdd_ng.img
docker compose up -d
```

### 3. Connect

- **noVNC:** `http://localhost:6080` (browser, always works)
- **Screen Sharing:** `vnc://VM_IP` (native macOS, Sequoia only)
- **SSH:** `ssh user@VM_IP`

### 4. Install

1. Select **macOS Base System** in the boot picker
2. Open **Disk Utility** — erase the VirtIO disk as **APFS** / **GUID Partition Map**
3. Install macOS (downloads ~13GB from Apple)

## Architecture

```
Container (Alpine 3.21)
├── QEMU 10.2.2 (built from source)
│   ├── KVM (-cpu host)
│   ├── virtio-blk (main disk + recovery)
│   ├── virtio-net (bridged via macvtap)
│   ├── VNC (localhost:5901)
│   └── Raw disk, direct I/O (cache=none, aio=native)
├── OVMF (UEFI)
├── OpenCore 1.0.7
│   ├── Lilu 1.7.2
│   ├── VirtualSMC 1.3.7
│   ├── WhateverGreen 1.7.0
│   └── CryptexFixup 1.0.5
└── Recovery image (raw)
```

## Performance Tuning

### Install vs Running

During install, macOS maxes out all available CPU and RAM. After install, it idles.

| | Install | Running |
|---|---------|---------|
| **CPU** | 24 cores | 8 cores |
| **RAM** | 24 GB | 16 GB |

Adjust `SMP`, `CORES`, and `RAM` in compose after install.

### I/O Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Disk format | Raw | No qcow2 overhead, direct block access |
| Disk cache | `cache=none` | macOS manages its own cache in RAM |
| Async I/O | `aio=native` | Linux native async I/O, bypasses QEMU userspace |
| Storage bus | `virtio-blk-pci` | Paravirtualized, ~10x faster than IDE/SATA emulation |
| Network | `virtio-net-pci` | Paravirtualized, native macOS AppleVirtIO driver |
| Recovery cache | `cache=unsafe` | Read-only image, aggressive host caching |

### Why not qcow2?

qcow2 adds a copy-on-write translation layer on every I/O operation. With raw + `cache=none` + `aio=native`, every read/write goes directly to the underlying storage. The tradeoff is disk space (256GB allocated upfront vs growing dynamically) but performance is dramatically better.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RAM` | `4` | RAM in GB |
| `SMP` | `4` | CPU threads |
| `CORES` | `4` | CPU cores |
| `DISK_SIZE` | `256G` | Virtual disk size |
| `HOST_IFACE` | `enp131s0f0` | Host network interface |
| `IMAGE_PATH` | `/opt/macos/mac_hdd_ng.img` | Disk path |
| `EXTRA` | | Additional QEMU arguments |

## Key Technical Decisions

- **`-cpu host`** — passes real CPU features. Required for Tahoe (dyld shared cache needs modern instructions)
- **`iMac20,1` SMBIOS** — one of 4 Intel models Tahoe supports
- **virtio-blk + virtio-net** — macOS has native `AppleVirtIO.kext` since Mojave. 10x faster than emulated IDE/vmxnet3
- **Raw disk + direct I/O** — no qcow2 anywhere. Zero translation overhead
- **QEMU VNC on localhost:5901** — prevents intercepting macOS Screen Sharing on port 5900
- **Smart install detection** — recovery drive attached when disk empty, removed after
- **OpenUsbKbDxe** — QEMU emulates USB keyboard, not PS2

## Building OpenCore

Download latest from upstream and build a bootdisk:

```bash
# Get components
curl -sL -o oc.zip https://github.com/acidanthera/OpenCorePkg/releases/download/1.0.7/OpenCore-1.0.7-RELEASE.zip
curl -sL -o lilu.zip https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip
curl -sL -o vsmc.zip https://github.com/acidanthera/VirtualSMC/releases/download/1.3.7/VirtualSMC-1.3.7-RELEASE.zip
curl -sL -o weg.zip https://github.com/acidanthera/WhateverGreen/releases/download/1.7.0/WhateverGreen-1.7.0-RELEASE.zip
curl -sL -o cf.zip https://github.com/acidanthera/CryptexFixup/releases/download/1.0.5/CryptexFixup-1.0.5-RELEASE.zip

# Assemble EFI, configure config.plist, then:
dd if=/dev/zero of=OpenCore.img bs=1m count=384
mkfs.fat -F 32 OpenCore.img
export MTOOLS_SKIP_CHECK=1
mmd -i OpenCore.img ::EFI ::EFI/BOOT ::EFI/OC ::EFI/OC/Drivers ::EFI/OC/Kexts ::EFI/OC/ACPI
mcopy -i OpenCore.img EFI/BOOT/BOOTx64.efi ::EFI/BOOT/
mcopy -i OpenCore.img EFI/OC/OpenCore.efi ::EFI/OC/
mcopy -i OpenCore.img EFI/OC/config.plist ::EFI/OC/
mcopy -s -i OpenCore.img EFI/OC/Drivers/* ::EFI/OC/Drivers/
mcopy -s -i OpenCore.img EFI/OC/Kexts/* ::EFI/OC/Kexts/
mcopy -s -i OpenCore.img EFI/OC/ACPI/* ::EFI/OC/ACPI/
```

### OpenCore config.plist key settings

- `SystemProductName`: `iMac20,1`
- `Timeout`: `10` (auto-boot after 10s)
- `PickerAttributes`: `0` (no cursor)
- `boot-args`: `keepsyms=1 kext-dev-mode=1`
- `csr-active-config`: `0x67` (SIP disabled for unsigned kexts)
- `SecureBootModel`: `Disabled`
- Drivers: `OpenRuntime`, `OpenHfsPlus`, `OpenPartitionDxe`, `OpenUsbKbDxe`, `UsbMouseDxe`
- Kexts: `Lilu`, `VirtualSMC`, `WhateverGreen`, `CryptexFixup`

## Display Limitations

Virtual GPU (`vmware-svga`) has no Metal/OpenGL:
- 7MB VRAM (Apple driver limitation)
- No desktop wallpaper
- "Unknown Display" (no EDID)
- Screen Sharing works on Sequoia, crashes on Tahoe

GPU passthrough (PCIe AMD card) resolves all display issues.

## License

GPL-3.0
