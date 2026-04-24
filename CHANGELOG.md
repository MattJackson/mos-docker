# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-04-19

First usable cut of the `mos` stack: the orchestrator for macOS Sequoia
(15.7.5) running in Docker on Linux+KVM, with patched QEMU and a kernel-side
display patcher for an OEM-like experience.

### Added

- Boot path: macOS Sequoia reaches desktop in ~2 minutes with auto-login.
- Display identity: recognized as **iMac** with **3840×2160 4K + HiDPI**
  ("looks like 1920×1080"); 7 of 8 advertised resolutions visible in the
  System Settings dropdown.
- VRAM: 512 MB (real, not fake — capped by the QEMU vmware-svga device).
- EDID: authentic iMac20,1 injection (Apple PnP `APP`, product `0xAE31`).
- Framebuffer hooks: 24 of 24 `IOFramebuffer` methods hooked, verified each
  boot via `ioreg` properties.
- Access surfaces: noVNC web access, Screen Sharing at full resolution, and
  SSH for headless/dev workflows.
- Companion repositories pinned at v0.5:
  - `mos15-patcher` — kernel-side hook framework (Lilu replacement, ~700 LOC)
  - `qemu-mos15` — QEMU 10.2.2 patches (`applesmc`, `vmware_vga`, `dev-hid`)
  - `opencore-mos15` — OpenCore patches (System KC injection — research)

### Known limitations

- Dynamic wallpaper renders white (no host GPU → no Metal compositing path).
- `MTLCopyAllDevices` returns 0 — architectural, requires a real host GPU.
- 5K display mode unavailable (qemu-mos15 vmware-svga capped at ~4K).
- Display preferences do not persist across reboots.
- Several macOS daemons (`cloudd`, `accessoryupdater`) retry-loop on missing
  host services.

[Unreleased]: https://github.com/MattJackson/mos-docker/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/MattJackson/mos-docker/releases/tag/v0.5.0
