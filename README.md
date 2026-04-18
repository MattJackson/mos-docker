# docker-macos

macOS in Docker. Custom QEMU hardware + display driver for an OEM-like experience.

## What This Is

macOS Sequoia (15.7.5) running in Docker on Intel KVM, with:
- **256MB VRAM** (not 7MB) — read from real hardware registers
- **Custom display driver** (QEMUDisplay) — proper IOFramebuffer for VMware SVGA II
- **Complete SMC emulation** (94 keys) — no VirtualSMC kext needed
- **Apple USB identity** — Magic Keyboard, Magic Mouse, Magic Trackpad
- **iMac20,1 SMBIOS** — macOS thinks it's a real iMac

## Three Repos

| Repo | What |
|------|------|
| **docker-macos** (this) | Docker image, display driver, OpenCore config |
| **[qemu-mos15](https://github.com/MattJackson/qemu-mos15)** | QEMU patches — SMC, VMware SVGA, USB HID |
| **[opencore-mos15](https://github.com/MattJackson/opencore-mos15)** | OpenCore patches — System KC support |

## Architecture

```
QEMU mos15 (94 SMC keys, 4K VMware SVGA, Apple USB HID)
  └── KVM acceleration (-cpu host)
        └── OpenCore (SMBIOS iMac20,1, kext injection)
              └── macOS Sequoia 15.7.5
                    └── QEMUDisplay kext (256MB VRAM, 1080p/4K, Screen Sharing)
```

## Requirements

- Linux host with Intel VT-x / KVM
- `/dev/kvm` accessible
- Docker
- macOS host for kext compilation (ARM or Intel)

## Current Status

### Working
- Desktop at 1920x1080 and 3840x2160 (4K)
- 256MB VRAM reported by macOS
- Display named "iMac"
- Screen Sharing works at full resolution
- Static wallpapers
- Zero third-party kexts for base boot (SMC handled by QEMU)
- One kext (QEMUDisplay) for display driver

### In Progress
- Automatic kext injection via OpenCore (currently requires manual install)
- SVGA FIFO for full resolution on noVNC
- Dynamic wallpaper support (needs jetsam limit raising)

## Host Hardware

- **Server:** Dell PowerEdge R730
- **CPU:** 2× Intel Xeon E5-2699 v3 (Haswell-EP), 72 threads
- **RAM:** 220GB
- **KVM:** enabled

## License

GPL-3.0
