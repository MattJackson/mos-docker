# Architecture

How mos-docker is organized internally. Read this if you're contributing
or debugging the build.

## One-line summary

One Dockerfile builds the production image. `scripts/entrypoint.sh`
dispatches to one of three modes based on the first argument: `install`,
`run`, or `test`. Persistent state lives in `/data` (bind mount).

## File layout

```
mos-docker/
├── Dockerfile              # production image (alpine + patched QEMU + libapplegfx-vulkan + scripts)
├── Dockerfile.test         # extends production: adds OEM QEMU + chromium for regression capture
├── compose.yml             # `docker compose up` (production)
├── compose.test.yml        # `docker compose -f ... run --rm test 0..4`
├── mos                     # CLI wrapper: ./mos install | run | test N | logs | stop
│
├── scripts/
│   ├── entrypoint.sh       # dispatcher — first arg or $MOS_MODE → install / run / test
│   ├── install.sh          # creates fresh disk + boots with recovery.img attached
│   ├── run.sh              # production launcher; NEVER touches disk.img
│   └── test.sh             # phase 0..4 regression runner (test image only)
│
├── docs/                   # this library
├── data/                   # gitignored runtime state (disk.img, OpenCore.img, recovery.img, logs/, run/)
├── kexts/                  # macOS kext sources (Lilu plugins, etc.)
├── efi/                    # OpenCore EFI inputs (config.plist, drivers, kexts ref)
├── tests/                  # in-VM test scripts (verify-modes.sh, metal-probe.m, etc.)
│
├── README.md               # 2-command quickstart
├── SETUP.md                # detailed first-time setup
├── CHANGELOG.md            # release-tagged history
├── CLAUDE.md               # agent context (loaded by Claude Code)
├── CONTRIBUTING.md / SECURITY.md / CODE_OF_CONDUCT.md / LICENSE / CODEOWNERS
└── display-override.plist  # macOS display profile (consumed by `efi/`)
```

## Image build (Dockerfile, single-builder)

```
alpine:3.21 (builder)
    ├── apk: build-base, meson, ninja, vulkan-headers, ccache, ...
    ├── ADD libapplegfx-vulkan.tar.gz   ← from MattJackson/libapplegfx-vulkan main
    ├── meson + ninja install → /usr/lib/libapplegfx-vulkan.so + /usr/lib/pkgconfig/applegfx-vulkan.pc + headers
    ├── ADD qemu-10.2.2.tar.xz          ← from download.qemu.org (pinned)
    ├── ADD mos-qemu.tar.gz             ← from MattJackson/mos-qemu main
    ├── overlay mos-qemu's hw/misc/applesmc.c, hw/display/vmware_vga.c,
    │   hw/usb/dev-hid.c, hw/display/apple-gfx-pci-linux.c, ...
    └── configure + make + make install → /tmp/qemu-install/

alpine:3.21 (runtime)
    ├── apk: glib pixman libvulkan ovmf novnc websockify socat coreutils ...
    ├── COPY --from=builder /tmp/qemu-install/usr/bin/qemu-system-x86_64 → /usr/bin/
    ├── COPY --from=builder /tmp/qemu-install/usr/bin/qemu-img → /usr/bin/
    ├── COPY --from=builder /tmp/qemu-install/usr/share/qemu/ → /usr/share/qemu/
    ├── COPY --from=builder /usr/lib/libapplegfx-vulkan.so* → /usr/lib/
    ├── COPY scripts/{entrypoint,install,run}.sh → /scripts/
    └── ENTRYPOINT ["/scripts/entrypoint.sh"]
        CMD ["run"]
```

`Dockerfile.test` extends with:
- A second QEMU 10.2.2 build (no patches) → `/usr/bin/qemu-system-x86_64-oem`
- `chromium`, `xvfb`, `py3-pillow` for headless screenshot capture
- `scripts/test.sh` for the phase runner

## Runtime dispatch (entrypoint.sh)

```
docker run ... mos-docker [install|run|test 0..4]
                  │
                  ▼
            entrypoint.sh
                  │
            validate /dev/kvm + /data
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼
   install.sh  run.sh    test.sh N
   (creates    (NEVER   (phase
    disk +     touches   chain)
    boots      disk)
    recovery)
```

## Three modes

### `install`

Used once per host to install macOS into `/data/disk.img`.

- **Refuses to overwrite** an existing `>1 MiB disk.img`. The operator
  must manually `rm` it first to reinstall — that's the consent gesture.
- Creates a fresh `256 GB` sparse `disk.img`.
- Sets `MOS_QEMU_INSTALL_MEDIA=/data/recovery.img` and execs `run.sh`.
- Boot sequence: OVMF → OpenCore → recovery image → Disk Utility +
  installer → user reboots VM into installed system.

### `run` (default)

Production. Boots whatever is at `/data/disk.img`.

- **Refuses to start** if `disk.img` is missing or `<1 MiB`.
- **NEVER** calls `qemu-img create`. The destructive code path doesn't
  exist in production.
- Launches QEMU with patched binary, OpenCore.img attached, macvtap
  bridged networking (auto-detects host NIC), bundled noVNC if
  `MOS_QEMU_BUNDLED_NOVNC=1`.

### `test N` (test image only)

Regression test phase runner. Each phase isolates one variable:

| Phase | Stack |
|---|---|
| 0 | Vanilla QEMU + OVMF + empty disk → UEFI shell |
| 1 | + macOS image + OpenCore (OEM QEMU binary) → OpenCore picker |
| 2 | + patched QEMU binary → same picker (binary-swap regression check) |
| 3 | + Apple identity (SMC + apple-kbd/tablet) → macOS boots |
| 4 | + apple-gfx-pci → black screen until M5 ships |

Each phase has its own port (6080..6084) so multiple phases run side-by-side.

## Persistent state (`/data`)

Everything that needs to survive container removal:

| File | Size | Origin | Purpose |
|---|---|---|---|
| `disk.img` | up to 256 GB | `install.sh` creates | macOS install |
| `OpenCore.img` | ~512 MB | operator-supplied (see [opencore-image.md](opencore-image.md)) | Bootable EFI |
| `recovery.img` | ~3.2 GB | operator-supplied (see [recovery-image.md](recovery-image.md)) | Install media |
| `logs/serial-*.log` | rolls | per-boot | QEMU guest serial dumps |
| `run/qemu-monitor.sock` | runtime | per-boot | HMP socket (host can `socat - unix:...`) |
| `run/qemu-qmp.sock` | runtime | per-boot | QMP JSON socket |

Container is otherwise stateless — re-create from image any time.

## Safety guarantees (encoded in code)

- **`run` mode never modifies `disk.img`.** The `qemu-img create` call
  doesn't exist in the production code path. Period.
- **`install` mode refuses to overwrite >1 MiB `disk.img`.** Even when
  invoked deliberately. Operator must `rm` first.
- **`entrypoint.sh` validates `/dev/kvm` access + `/data` writability**
  up front. Container exits with a clear error on misconfigured docker
  run, instead of starting QEMU and racing into bad state.
- **No `2>/dev/null || echo 0` patterns** in size checks. `stat` is
  allowed to fail loud.

These are direct lessons from
[incidents/2026-05-06-disk-wipe.md](incidents/2026-05-06-disk-wipe.md).
Don't undo them.

## Networking

Default: macvtap bridge over the host's primary physical NIC. VM gets
a real LAN IP via host's DHCP. Falls back to user-mode (slirp) if no
physical NIC is detected. See [networking.md](networking.md).

## Display

Default: `-vga std` (Bochs/QEMU stdvga). Works for OpenCore + recovery
+ post-install kernel via linear framebuffer. Reliable.

`MOS_USE_APPLE_GFX_PCI=1` opts into `-vga none -device apple-gfx-pci`
which is the M5 paravirt GPU target — currently broken until
libapplegfx-vulkan opcode handlers ship.

## Why this shape

The architecture is the result of collapsing a 5-Dockerfile + 5-launcher
phased chain into a single image with three modes. Pre-collapse:

- Dockerfile.base + Dockerfile.phase0..4 + Dockerfile.screenshot
- launch.sh + launch_phase0..3.sh
- compose.phase0..4.yml + compose.screenshot.yml + docker-compose.yml
- scripts/build-phases.sh (sequential build orchestrator)

Five copies of the install-mode auto-detect code path. Five places to
patch every bug fix. One of those five copies wiped a 256 GB install on
2026-05-06. The collapse forces bugs to be fixed in one place — which
encodes the safety guarantees structurally rather than relying on
"remember to update all five."

The phased regression chain is preserved, just collapsed: `test.sh`
takes a phase number and configures QEMU args + binary selection
internally. Same bisection power, ⅕ the surface area.
