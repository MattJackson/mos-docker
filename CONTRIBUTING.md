# Contributing to docker-macos

## Project Structure

This project runs macOS in Docker using three repos:

- **docker-macos** (this repo) — Docker image, display driver kext, OpenCore config
- **[qemu-mos15](https://github.com/MattJackson/qemu-mos15)** — QEMU patches for macOS VMs
- **[opencore-mos15](https://github.com/MattJackson/opencore-mos15)** — OpenCore patches

## Building

### Requirements
- macOS host with Xcode command line tools (for kext cross-compilation)
- Docker (for QEMU build and VM runtime)
- Linux host with KVM (for running the VM)

### QEMUDisplay kext
```bash
cd kexts/QEMUDisplay
KERN_SDK="$(pwd)/../deps/MacKernelSDK"
# See build commands in README
```

### QEMU (on Linux server)
```bash
# Built inside Alpine container — see Dockerfile
```

## Code Style
- C/C++ for kext and QEMU code
- No third-party dependencies beyond Apple's IOKit SDK
- Document every finding in DISCOVERY.md
- One change at a time, test, prove, document

## License
GPL-3.0
