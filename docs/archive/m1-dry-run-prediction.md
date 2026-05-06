# M1 docker build dry-run prediction

Paper audit of the full `docker build` recipe for mos-docker against
the current state of the dependent repos as of 2026-04-20. No build
has been attempted; this document pre-identifies the failure modes so
the first real attempt converges faster.

M1 is "first green `docker build` producing a QEMU binary that boots
macOS to the installer with `-device apple-gfx-pci` present and a
lavapipe-backed Vulkan context reachable". Not "Metal works" — just
"the stack is wired end to end and doesn't crash at boot".

Inputs audited:
- `/Users/mjackson/Developer/docker-macos/Dockerfile`
- `/Users/mjackson/Developer/docker-macos/launch.sh`
- `/Users/mjackson/Developer/docker-macos/docker-compose.yml`
- `/Users/mjackson/Developer/docker-macos/docs/qemu-mos15-build.md`
- `/Users/mjackson/Developer/qemu-mos15/hw/display/*` (local and at origin/main)
- `/Users/mjackson/Developer/qemu-mos15/pc-bios/meson.build` (local only — unpushed)
- `/Users/mjackson/Developer/libapplegfx-vulkan/meson.build` + `src/**`
  (local and at origin/main)

## 1. Bottom-line

P(docker build produces a runnable qemu-system-x86_64 with
apple-gfx-pci registered, on first attempt): **~5%.**

Prior confidence was 90%. Post-audit confidence: **25%** that M1
succeeds within five iterations with only small fixes; **5%** that
the very first `docker build` lands a working binary.

The gap is driven by **four fatal blockers**, ordered by how early
they fire:

1. **Git trees are 4 commits (libapplegfx) / 3 commits (qemu-mos15)
   ahead of origin/main.** The Dockerfile fetches origin/main
   tarballs. The fetched trees are missing the Phase 1.A.1 / 1.A.2
   scaffold, missing the pkgconfig generator, and (qemu-mos15) missing
   `pc-bios/apple-gfx-pci.rom` and `pc-bios/meson.build`.
2. **pc-bios `cp` fails at build step.** Even if the qemu-mos15 tree
   were pushed, `pc-bios/apple-gfx-pci.rom` is a binary blob that
   must land in the remote tree via LFS or a plain binary commit.
   If absent, the Dockerfile's `cp ... pc-bios/apple-gfx-pci.rom ...`
   aborts with "no such file or directory" and the `RUN` step exits
   non-zero.
3. **pkg-config name mismatch.** `libapplegfx-vulkan`'s meson build
   calls `library('applegfx-vulkan', ...)` → installs
   `applegfx-vulkan.pc`. QEMU's overlay meson.build calls
   `dependency('libapplegfx-vulkan', required: false)` → pkg-config
   asks for `libapplegfx-vulkan.pc`. These do NOT match. `required:
   false` makes the build **silently** drop the device from the
   binary rather than fail loudly. The container builds, starts —
   and `-device apple-gfx-pci` returns "No 'apple-gfx-pci' device
   model available".
4. **`trace_apple_gfx_pci_realize` / `trace_apple_gfx_pci_reset` are
   undefined.** The source files reference these trace events; they
   exist in neither upstream QEMU 10.2.2's `hw/display/trace-events`
   nor in any overlay file we copy. Compile fails at the `trace.h`
   generator / first C compile of `apple-gfx-pci-linux.c`.

Three significant soft issues are also flagged in §2.

The "silent drop" failure mode (3) is the scariest because it turns a
build fault into a runtime fault — the docker image builds, the
container starts, macOS boots (on VMware SVGA) without ever going
near apple-gfx-pci — making it look like the M1 plumbing is done when
it isn't.

## 2. Checklist

| # | Item | Predicted | Fix before try? | Reference |
|---|------|-----------|-----------------|-----------|
| A1 | Alpine apk: `build-base python3 ninja meson pkgconf` | ok | no | Dockerfile L19–23 |
| A2 | Alpine apk: `glib-dev pixman-dev libcap-ng-dev libseccomp-dev libslirp-dev libaio-dev dtc-dev` | ok | no | Dockerfile L21–22; docs/qemu-mos15-build.md L86–93 |
| A3 | Alpine apk: `mesa-vulkan-swrast vulkan-loader vulkan-headers vulkan-tools` | ok | no | Dockerfile L23 |
| A4 | Alpine apk runtime: `vulkan-loader mesa-vulkan-swrast` | ok | no | Dockerfile L66–67 |
| A5 | Alpine apk runtime: `ovmf` provides OVMF_CODE.fd + OVMF_VARS.fd | ok | no | Dockerfile L66, launch.sh L50–51 |
| A6 | Alpine `iproute2` for `ip link`/`macvtap` in launch.sh | ok | no | Dockerfile L66, launch.sh L26–38 |
| A7 | QEMU configure deps: missing `zlib-dev`/`liburing-dev` — not needed for this feature set | ok | no | Alpine 3.21 has these bundled in `build-base` and `libaio-dev` |
| A8 | Alpine `dtc-dev` vs `libfdt-dev` naming | ok | no | docs/qemu-mos15-build.md L96–101 |
| B1 | `git clone` fetches libapplegfx-vulkan `origin/main` | **expected_failure** | **yes** | Dockerfile L26–29. origin is 4 commits behind local |
| B2 | Origin/main libapplegfx-vulkan has no `src/device.c` / `mmio.c` / `display.c` | **expected_failure** | **yes** | `git ls-tree 0807ca5 -- src/` shows only `src/memory/task.c` |
| B3 | Origin/main libapplegfx-vulkan has no `pkg.generate(...)` | **expected_failure** | **yes** | `git show 0807ca5:meson.build` has no pkgconfig block |
| B4 | `ninja -C builddir install` installs pkg-config file | **expected_failure at origin/main**; ok at local | **yes** | meson.build L93–98 (local only) |
| B5 | pkgconfig name: produces `applegfx-vulkan.pc`, consumer asks `libapplegfx-vulkan.pc` | **expected_failure (silent)** | **yes** | meson.build L81 + /tmp test confirms meson naming strips `lib` |
| B6 | Library soname: meson `version:` / `soversion:` set at local, absent at origin | ok at local | low | meson.build L85–87 (local) |
| B7 | `_GNU_SOURCE` + memfd syscall fallback | ok | no | src/memory/task.c L17–19 + L47–60 |
| B8 | musl vs glibc: `syscall(__NR_memfd_create, ...)` works on musl | ok | no | musl provides `syscall()` and `__NR_*` via `<sys/syscall.h>` |
| B9 | Library tests at build: `meson test` not invoked — only `ninja install` | ok | no | Dockerfile L28–29 — skips `meson test` cleanly |
| C1 | Dockerfile `curl tar xz` of mos-qemu origin/main | partially_fails | **yes** | Dockerfile L34 — fetches tree without pc-bios/ |
| C2 | `cp ... pc-bios/meson.build pc-bios/meson.build` | **expected_failure** | **yes** | local-only file, not at 31a5eae |
| C3 | `cp ... pc-bios/apple-gfx-pci.rom pc-bios/apple-gfx-pci.rom` | **expected_failure** | **yes** | local-only file, 16896 bytes, unpushed |
| C4 | `hw/display/meson.build` overlay — `dependency('libapplegfx-vulkan')` | wrong name (B5) | **yes** | qemu-mos15 hw/display/meson.build L73 |
| C5 | `hw/display/Kconfig` gates `APPLE_GFX_PCI_LINUX` default=y if PCI_DEVICES | ok | no | Kconfig L153–162 |
| C6 | Six shell callbacks declared `static` in common-linux.c referenced externally from pci-linux.c | **expected_failure** (compile) | **yes** | common-linux.c L102, 136, 196, 266, 282, 316 → pci-linux.c L86–91 |
| C7 | `trace_apple_gfx_pci_realize()` / `trace_apple_gfx_pci_reset()` events | **expected_failure** (compile) | **yes** | pci-linux.c L104, L116 — not in trace-events |
| C8 | Other `trace_apple_gfx_*` events: all defined in upstream 10.2.2 hw/display/trace-events | ok | no | verified via `curl https://github.com/qemu/qemu/raw/v10.2.2/hw/display/trace-events` |
| C9 | apple-gfx-common-linux.c `parent_obj` access via `AppleGFXLinuxState` (requires `PCIDevice parent_obj` as first member) | ok | no | apple-gfx-linux.h L44 |
| C10 | PCI vendor/device ids 0x106b/0x1b30 | ok | no | apple-gfx-pci-linux.c L18–19. Matches Apple ParavirtualizedGraphics |
| C11 | MSI-X: `msi_init` returns before asserting vector count not exceeded by BAR size — 64 vectors × 16 bytes = 1 KB, fits in 4 KB MSI-X window | ok | no | apple-gfx-pci-linux.c L73–79 |
| C12 | `qemu_free_displaysurface` called in unrealize — function exists in QEMU 10.2.2 | ok | no | upstream ui/console.c |
| C13 | `apple_gfx_pci_reset` uses `ResetType` parameter (10.2.2 signature) | ok | no | QEMU 10.2.2 reset-domain API matches |
| D1 | libapplegfx-vulkan exports `lagfx_mmio_read`, `lagfx_device_new`, `lagfx_task_create`, `lagfx_display_new`, `lagfx_display_cursor_position`, `lagfx_mmio_write`, `lagfx_device_free`, `lagfx_device_reset`, `lagfx_display_free` | ok at local, **missing at origin/main** | **yes (covered by B1)** | local src/*.c vs origin 0807ca5 |
| D2 | Link-time visibility: no `__attribute__((visibility))` stripping; default is `extern` (shared lib exports all) | ok | no | meson default_library=shared |
| D3 | soname versioning — `soversion: '0'` at local; library SONAME will be `libapplegfx-vulkan.so.0` | ok | no | meson.build L86 |
| D4 | `lagfx_mmio_read` signature matches between `.h` and `.c` (uint32_t, lagfx_device_t*, uint64_t) | ok | no | include/libapplegfx-vulkan.h L270 vs src/mmio.c L25 |
| E1 | pc-bios install of apple-gfx-pci.rom through pc-bios/meson.build: `install_data(blobs,...)` includes it | ok | no | pc-bios/meson.build L90 (local-only) |
| E2 | QEMU `romfile` lookup at runtime via `qemu_find_file(QEMU_FILE_TYPE_BIOS, "apple-gfx-pci.rom")` | ok | no | apple-gfx-pci-linux.c L33, 180 |
| E3 | Runtime `/usr/share/qemu/apple-gfx-pci.rom` exists after COPY from builder | ok | no | Dockerfile L75 — copies entire qemu dir |
| F1 | Alpine `/usr/share/vulkan/icd.d/lvp_icd.x86_64.json` present after `apk add mesa-vulkan-swrast` | ok | no | pkgs.alpinelinux.org contents check |
| F2 | `libvulkan_lvp.so` installed at `/usr/lib/libvulkan_lvp.so` by mesa-vulkan-swrast | ok | no | same contents check |
| F3 | Vulkan loader honors `/usr/share/vulkan/icd.d/` (not just `/etc/vulkan/icd.d/`) | ok | no | `VK_DRIVERS_FILES` doc — both are default search paths |
| F4 | `launch.sh` does NOT set `LP_NUM_THREADS` — lavapipe defaults to all cores | ok (but suboptimal) | no | launch.sh – intentionally unwired per gpu_cores spec |
| F5 | `vulkaninfo` smoke test inside container would show `lavapipe` | ok | no | expected after F1 lands |
| G1 | `ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off` — valid 10.2.2 property | ok | no | upstream hw/isa/lpc_ich9.c |
| G2 | launch.sh installs `-device vmware-svga` (fallback) concurrently with future `-device apple-gfx-pci` | ok | no | launch.sh L66–67. apple-gfx-pci NOT added to launch.sh yet (intentional for M1.1) |
| G3 | `launch.sh` has no `-device apple-gfx-pci` line | **warning** | low | Even a successful build won't exercise apple-gfx-pci until launch.sh is updated. M1 definition must pin this |
| H1 | Phase 1.A.2 scaffold at local HEAD (4d6eaf4) has correct 12-byte header | ok at local; missing at origin | — | libapplegfx-vulkan log |
| H2 | Runtime doorbell/ring geometry is stubbed (`ring_armed == false`, `fifo_drain` returns 0) | ok (deferred) | no | src/protocol/fifo.c L109–149 |
| H3 | Guest kext writes to MMIO register with no decoder attached — returns 0 gracefully | ok | no | src/mmio.c L31–41 |
| I1 | `privileged: true` in docker-compose, `/dev/kvm` accessible | ok | no | docker-compose.yml L5 |
| I2 | `HOST_IFACE=eth0` placeholder — user must edit | warning | no | docker-compose.yml L8 |
| I3 | `SETUP.md step 2` recovery.img / OpenCore.img presence checked at COPY time | ok | no | Dockerfile L9–12 |

## 3. Pre-flight fixes (priority order)

Everything under P0 must land before the first serious `docker
build` attempt. P1 can be deferred but will bite fast.

### P0 — must fix before pushing build

**P0-1 — push both repos to origin/main.**
- `git -C /Users/mjackson/Developer/libapplegfx-vulkan push` — pushes commits
  up to `4d6eaf4` (adds Phase 1.A.1 scaffold, Phase 1.A.2 decoder,
  12-byte header fix, pkg.generate call).
- `git -C /Users/mjackson/Developer/qemu-mos15 push` — pushes up to `09a0ba4`
  (adds real task API wiring, PC-BIOS ROM overlay, pci-linux.c with
  trace hooks).
- Verifies rows B1–B4, C1–C3, D1, E1 all flip to "ok".

**P0-2 — fix the pkg-config name mismatch.**
Edit `/Users/mjackson/Developer/libapplegfx-vulkan/meson.build` L93–98 to add
the explicit filename override:
```meson
pkg.generate(libapplegfx_vulkan,
  name : 'libapplegfx-vulkan',        # ← add this
  filebase : 'libapplegfx-vulkan',    # ← and this
  description : 'Linux impl of Apple PVG framework (Vulkan backend)',
  url : 'https://github.com/MattJackson/libapplegfx-vulkan',
)
```
**OR** change the QEMU overlay meson.build L73:
```meson
libapplegfx_vulkan = dependency('applegfx-vulkan', required: false)
```
The former is cleaner (library name stays `applegfx-vulkan`, pkg
file becomes `libapplegfx-vulkan.pc` aligning with project name and
consumer expectation). Pick one and stay consistent.

**P0-3 — drop `static` from the six shell callbacks** in
`/Users/mjackson/Developer/qemu-mos15/hw/display/apple-gfx-common-linux.c`:
```
L102: static lagfx_task_t * → lagfx_task_t *
L135: static void           → void
L195: static bool           → bool
L265: static bool           → bool
L281: static bool           → bool
L315: static void           → void
```
And add forward declarations to `apple-gfx-linux.h` so `pci-linux.c`
compiles. Without this the link fails with "undefined reference to
`apple_gfx_create_task`".

**P0-4 — add trace events.** Either (a) overlay
`hw/display/trace-events` adding just the two missing lines:
```
apple_gfx_pci_realize(void) ""
apple_gfx_pci_reset(void) ""
```
or (b) remove the two `trace_apple_gfx_pci_*()` calls from
`apple-gfx-pci-linux.c` (L104, L116) — they're diagnostic-only. (a)
is cleaner if we want observability; (b) is one-line-each deletion.

### P1 — will break on first run, easy fix

**P1-1 — add `-device apple-gfx-pci` and `-vga none` combo check to
launch.sh.** Currently launch.sh always uses `-device vmware-svga`
as the display. Even if M1 succeeds at build time, runtime won't
exercise apple-gfx-pci without a launch.sh update. Suggested gating:
```
APPLE_GFX=${APPLE_GFX:-no}
if [ "$APPLE_GFX" = "yes" ]; then
  exec qemu-system-x86_64 ... -device apple-gfx-pci,id=gpu0 ...
else
  exec qemu-system-x86_64 ... -device vmware-svga,vgamem_mb=512 ...
fi
```
Default to `no` for M1 so current VMware path keeps working, flip
to `yes` in smoke tests.

**P1-2 — verify `lvp_icd.x86_64.json` path inside runtime stage.**
Add a cheap builder-side `RUN vulkaninfo --summary | grep -q lavapipe
|| (echo 'lavapipe missing' && false)` to catch this.

### P2 — soft issues, can defer post-M1

- G3 — launch.sh currently has no knob to toggle apple-gfx-pci.
- H2 — runtime doorbell / ring geometry are stubbed; any guest kext
  trying to submit real work will see no drain happen. M1 only
  targets "kext probe doesn't crash", not "kext submits commands
  and frames render".
- Library version drift / ABI bumps. Tag `v0.0.1` now, pin in
  Dockerfile via `git clone --branch v0.0.1`. Avoids the "latest
  main regressed at 3 am" class.

## 4. Expected first-run failure mode

Assuming P0-1 through P0-4 all land cleanly and the team kicks off
`docker build`:

**Most likely first blocker: P0-4 was fixed by deleting the two
trace calls, not by adding a trace-events overlay** — build succeeds
through QEMU compile, link-time finds all symbols (P0-1 + P0-3 did
their job), `make install` drops binaries under
`/tmp/qemu-install/`, runtime stage assembles, container starts.

**Second likely blocker: pkg-config fix was applied on the wrong
side.** If P0-2 was done by changing QEMU's meson.build to use
`dependency('applegfx-vulkan')` but the pkg.generate change in
libapplegfx-vulkan was reverted by a later push of an older tree,
the dependency lookup silently fails again and `apple-gfx-pci`
drops from the binary. The container starts fine; everything *looks*
good; `qemu-system-x86_64 -device help | grep apple` returns
nothing. This is why the test assertion (§6) matters.

**Third plausible blocker: PCI option-ROM alignment.** The installed
ROM file is 16896 bytes (= 16.5 KiB). QEMU's PCI core rounds ROM
BARs to power of 2 ≥ 2 KiB — 16.5 KiB rounds to 32 KiB. The guest's
AppleParavirtGPU.kext reads the ROM via a PCI BAR of a specific size
Apple hard-coded — if our size (32 KiB after rounding) differs from
what Apple emits natively (needs capture — Phase 1.E), the kext may
print a ROM mismatch warning and skip loading. This is soft — kext
probe still succeeds, just without ROM-provided firmware personality.

**Fourth realistic: Alpine 3.21 Mesa lavapipe ICD mismatched
Vulkan-loader ABI.** Happened in Alpine 3.19 era; not observed in
3.21 but worth checking with `vulkaninfo` at build time.

My money is on #1 (everyone forgets trace-events the first time) or
#2 (pkg-config name fix applied inconsistently across repos).

## 5. Post-build runtime risks

Assuming `docker build` succeeds and `docker run` brings up the
container:

- **Launch.sh doesn't add `-device apple-gfx-pci`.** Container boots
  and runs but the new device is never exercised — M1 is trivially
  satisfied at build time but nothing validates end-to-end. Covered
  by P1-1.
- **AppleParavirtGPU.kext probes the device and writes to MMIO
  0x1000..0x103F.** Current scaffold responds with register-shadow
  reads + `fifo_drain` no-op (fifo.c L109–149). The kext will write
  ring-base, ring-length, and doorbell setter values; shadow
  captures them; nothing happens beyond that. Expected: kext logs
  "no frame produced within timeout" and may fall back to software
  cursor, but **should not panic**. There's a residual risk that
  kext asserts on a write response that our scaffold returns 0 for —
  per Phase 0.B dylib RE, some reads are expected to return non-
  zero (e.g. status/capability bits). `src/protocol/protocol.c` L50
  sets `p->reg[0] = 0x3u;` ("present + ready"). If the kext probes
  offset != 0x1000, we return 0, which may trip a KASSERT.
- **MSI-X vectors 0..63 allocated but no interrupts ever raised by
  the scaffold.** Kext likely relies on interrupt-driven frame
  completion; absence is benign (kext times out), not a panic.
- **Vulkan init not yet wired.** `lagfx_device_new` at Phase 1.A.1
  doesn't create a VkInstance. First actual rendering attempt will
  return `LAGFX_ERR_NO_FRAME`. Kext sees blank display. Acceptable
  for M1.
- **OVMF_VARS.fd reset race.** launch.sh `cp OVMF_VARS.clean.fd
  OVMF_VARS.fd` happens in the container's read-only-ish /usr/share
  — may fail on a read-only filesystem mount. Check docker image
  filesystem permissions.
- **macvtap requires CAP_NET_ADMIN + /dev/tap<N> access.** Dockerfile
  uses `privileged: true` in compose, fine; but if someone runs it
  without privileged (or via a non-root orchestrator), `ip link add`
  fails. Unrelated to M1 but a common gotcha.

The single highest-probability runtime blocker is "kext probe
returns non-zero from an offset we didn't model, kext KASSERTs". The
current Phase 1.A.2 scaffold at local HEAD handles reads to
known-bit-zero offsets but the RE of each register's bits is still
incomplete (per phase-1a2-decoder-plan.md §7.2). Probability of
first-boot kext panic on unmodeled register: ~40%. This is why M1
is "doesn't crash", not "renders a frame".

## 6. Recommended test assertion

Any CI or runbook that claims M1 green must assert both:

```bash
# Build-time: device must be in the binary.
docker run --rm mos:sequoia qemu-system-x86_64 -device help 2>&1 \
  | grep -q '^name "apple-gfx-pci"' \
  || { echo "FAIL: apple-gfx-pci not in binary"; exit 1; }

# Runtime: lavapipe Vulkan driver is reachable.
docker run --rm --device /dev/dri mos:sequoia \
  sh -c 'apk add --no-cache vulkan-tools > /dev/null && \
    vulkaninfo --summary 2>&1 | grep -qi lavapipe' \
  || { echo "FAIL: lavapipe not reachable"; exit 1; }
```

If either fails, M1 is not green — even if the image builds.

## 7. Summary table — what to tell the team

Before the first serious docker build, four patches are required:

1. `git push` both mos-qemu and libapplegfx-vulkan to origin/main.
2. Either (a) pin pkg.generate filename to `libapplegfx-vulkan` in
   libapplegfx-vulkan/meson.build, or (b) change the QEMU overlay
   meson.build to use `dependency('applegfx-vulkan', ...)`.
3. Drop `static` from the six shell-callback functions in
   qemu-mos15/hw/display/apple-gfx-common-linux.c and forward-declare
   them in apple-gfx-linux.h.
4. Either (a) overlay hw/display/trace-events to add
   `apple_gfx_pci_realize` and `apple_gfx_pci_reset`, or (b) delete
   the two `trace_apple_gfx_pci_*()` calls from apple-gfx-pci-linux.c.

With those four patches, P(first successful docker build) rises from
~5% to ~70%. Add P1-1 (launch.sh wiring) and the test assertions
above, and P(meaningful M1 green with `-device apple-gfx-pci`
exercised) reaches ~55%. Everything above 55% requires real runtime
iteration — the paper audit can't see interrupts, register-bit
semantics, or lavapipe ICD version skew.

## Appendix — references pulled live

- Upstream QEMU 10.2.2 `hw/display/trace-events`:
  https://github.com/qemu/qemu/raw/v10.2.2/hw/display/trace-events
  — verified via `curl` on 2026-04-20. All `apple_gfx_*` trace events
  referenced by our common-linux.c exist EXCEPT `apple_gfx_pci_realize`
  and `apple_gfx_pci_reset`.
- Alpine 3.21 mesa-vulkan-swrast contents:
  https://pkgs.alpinelinux.org/contents (branch v3.21, arch x86_64)
  — verified presence of `/usr/lib/libvulkan_lvp.so` and
  `/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`.
- meson pkg.generate behavior: reproduced locally with a minimal
  `library('foo-baz',...)` + `pkg.generate(lib)` on meson 1.11.0;
  output filename was `foo-baz.pc`. Same mechanism applied here
  predicts `applegfx-vulkan.pc`.
- Upstream QEMU meson.build pvg dependency:
  `pvg = dependency('appleframeworks', modules: ['ParavirtualizedGraphics',
  'Metal'], required: get_option('pvg'))` — Linux returns `not_found`,
  so `apple-gfx.m` / `apple-gfx-pci.m` source-set gate is false, no
  conflict with our new Linux-C device.
