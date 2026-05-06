# mos-docker

Run macOS Sequoia in a Docker container on Linux + KVM. Two commands from a fresh host:

```bash
# 1. Install (one-time, interactive — connect to noVNC at http://localhost:6080)
docker run -it --rm --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/mos-data:/data" ghcr.io/mattjackson/mos-docker install

# 2. Run (daemon)
docker run -d --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/mos-data:/data" ghcr.io/mattjackson/mos-docker
```

That's it. macOS persists in `./mos-data/disk.img` between runs.

> **Prerequisite:** before step 1, drop a macOS recovery image at
> `./mos-data/recovery.img` and an OpenCore EFI image at
> `./mos-data/OpenCore.img`. See [SETUP.md](SETUP.md) for how to acquire each.
> The container will print the exact instructions if either is missing.

## What you get

- macOS Sequoia VM with KVM acceleration (≥30 fps @ 1080p on modern hardware)
- Apple paravirtualized GPU (`apple-gfx-pci` device, lavapipe Vulkan backend) — see *Project status*
- noVNC web client at `http://localhost:6080/vnc.html?autoconnect=1`
- Persistent `disk.img` survives container removal

## Project status

This is the runtime side of [mos](https://github.com/MattJackson/mos), an open-source effort to bring up Apple's `ParavirtualizedGraphics` framework against a host-side Vulkan/lavapipe backend running under QEMU/KVM. The plumbing (QEMU patches, kexts, OpenCore wiring) is solid and stable; the host-side opcode handlers in `libapplegfx-vulkan` are partially implemented (M5 milestone). Without those, the apple-gfx-pci device doesn't render — you'll see a blank screen at boot when using the production stack.

For the milestones-met state today (a working paravirt GPU stack short of pixels), use the regression test phases — see *Regression testing* below.

## Quick reference

| Command | What it does |
|---|---|
| `docker run ... install` | Install macOS into `disk.img` |
| `docker run ...` (default `run`) | Boot installed macOS |
| `docker run ... test 0..4` | Run a regression-test phase |

## Repo layout

```
.
├── Dockerfile          production image build
├── Dockerfile.test     test image (extends production + adds OEM binary + chromium)
├── compose.yml         production (`docker compose up`)
├── compose.test.yml    regression tests (`docker compose -f compose.test.yml ...`)
├── mos                 CLI wrapper (./mos install | run | test N | logs | stop)
├── scripts/
│   ├── entrypoint.sh   dispatcher (run | install | test)
│   ├── install.sh      install workflow
│   ├── run.sh          production launcher
│   ├── test.sh         regression test phase runner
│   └── compare-regression.sh  ImageMagick perceptual diff
├── baselines/          gold screenshots for regression tests
├── data/               (gitignored) disk.img, OpenCore.img, recovery.img, logs/
├── README.md           you are here
└── SETUP.md            full first-time setup guide
```

## If you cloned this repo (developer/contributor)

```bash
git clone https://github.com/MattJackson/mos-docker
cd mos-docker
./mos build              # build the production image
./mos install            # install macOS (interactive)
./mos run                # boot in background
./mos logs               # tail the log
./mos stop               # stop
```

For regression tests:

```bash
./mos build-test         # build the test image
./mos test 0             # run phase 0 (vanilla VNC sanity)
./mos test 1             # ... etc through 4
```

See [SETUP.md](SETUP.md) for the full walkthrough including how to acquire the recovery + OpenCore images.

## Persistent state

Everything that needs to survive container removal lives in `./data/` (or wherever `-v $PATH:/data` points):

| File | Size | Purpose |
|---|---|---|
| `disk.img` | up to 256 GB | macOS install (created by `install`, sparse-allocated, grows on use) |
| `OpenCore.img` | ~512 MB | Bootable OpenCore EFI volume (operator-supplied, see SETUP.md) |
| `recovery.img` | ~3.2 GB | Apple recovery image, only needed for `install` (operator-supplied) |
| `logs/` | rolls daily | Per-boot QEMU serial logs |
| `run/` | runtime sockets | QMP + HMP unix sockets, ephemeral |

## Safety guarantees

- `run` mode **never** modifies `disk.img`. If it's missing or invalid, the container exits with a clear error pointing at `install`.
- `install` mode **never** overwrites an existing `disk.img` >1 MiB. To reinstall, delete the file manually.
- All sub-scripts use `set -euo pipefail`; any error halts immediately.

These are direct lessons from [an incident](docs/incidents/2026-05-06-disk-wipe.md) where a bad install-mode auto-detect destroyed a 256 GB install.

## Hardware requirements

- Linux x86_64 host with VT-x and `/dev/kvm` accessible
- ≥ 32 GB RAM (16 GB for the VM at runtime + headroom)
- ≥ 300 GB free disk (256 GB sparse install + builds + recovery)
- Optional: discrete GPU for any host-side GUI you want to keep responsive while the VM runs

## License

AGPL-3.0. See [LICENSE](LICENSE).

## Related projects

- [mos](https://github.com/MattJackson/mos) — RE notes, kext sources, milestones
- [mos-qemu](https://github.com/MattJackson/mos-qemu) — QEMU 10.2.2 fork with `apple-gfx-pci` + `applesmc` + `dev-hid` patches
- [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan) — host-side paravirt GPU library (Vulkan/lavapipe backend)
