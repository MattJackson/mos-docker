# mos15 display test runbook (v0.6)

Walk through this every time you deploy a new `mos15-patcher`, `QEMUDisplayPatcher`, or `qemu-mos15` build. Each step has a clear pass signal, a clear fail signal, and what to do when it fails.

---

## Milestone chain (M1 -> M8)

The project's "100% complete" bar is defined in
`~/mos/memory/project_100pct_target.md` — 1080p @ 30fps desktop useful
for real work, with fps scaling to host core count. M1..M8 are the
bisected milestones on the road to that bar. Every milestone has
one exit criterion and one verify script.

| #  | Milestone                   | Exit criterion                                                                         | Verify script                   | Status   | Key exit codes                                                        |
|----|-----------------------------|----------------------------------------------------------------------------------------|---------------------------------|----------|-----------------------------------------------------------------------|
| M1 | First end-to-end compile    | `docker build` succeeds, binary registers `apple-gfx-pci`, no panic                    | `tests/verify-m1.sh`            | REAL     | 10 build-fail / 20 container-fail / 30 device-missing / 40 boot-timeout / 50 panic / 60 baseline-regression |
| M2 | Guest kext attaches         | AppleParavirtGPU.kext binds to PCI IDs, MMIO reaches decoder, no panic                 | `tests/verify-m2.sh`            | REAL (MMIO soft-scaffold) | 1 ssh / 10 kext-not-attached / 20 pci-not-bound / 30 panic / 40 no-mmio |
| M3 | metal-no-op round-trip      | `MTLCopyAllDevices >= 1`, empty cmdbuf `commit + waitUntilCompleted` returns 0         | `tests/verify-m3.sh` (wraps `verify-phase1.sh`) | REAL     | 1 ssh / 10 phase1-failed / 20 mtl-count-zero / 30 decoder-errors    |
| M4 | First pixel                 | Metal clear-color → Vulkan clear → noVNC shows solid color                             | `tests/verify-m4.sh` + `tests/metal-clear-screen.m` | SCAFFOLD | 1 ssh / 10 novnc-unreachable / 20 capture-failed / 30 diff-exceeded |
| M5 | First shader                | One stock shader: AIR → LLVM → SPIR-V → lavapipe → visible triangle                    | `tests/verify-m5.sh` + `tests/metal-triangle.m`    | SCAFFOLD | 1 ssh / 10 catalog-missing / 20 cmdbuf-failed / 30 diff-exceeded    |
| M6 | Login screen renders        | loginwindow's CALayer compositing through our stack; Apple login visible at 1080p      | `tests/verify-login-screen.sh`  | SCAFFOLD | 10 loginwindow-not-running / 20 capture-failed / 30 diff-exceeded / 40 reference-missing |
| M7 | Static desktop correct      | Dock + menu bar + windows render without corruption at 1080p                           | `tests/verify-desktop-idle.sh`  | SCAFFOLD | 10 WindowServer-missing / 20 capture-failed / 30 diff-exceeded / 40 reference-missing |
| M8 | 30fps interactive (100%)    | Sustained 30fps at 1080p on common UI ops (drag, menu, cursor)                         | (benchmark TBD — Phase 5)       | —        | —                                                                     |

**Scaffold vs real:**
- `verify-m1.sh`, `verify-m2.sh`, `verify-m3.sh` (and its delegate
  `verify-phase1.sh`) are REAL gates — they make positive assertions
  about the plumbing that should be green today.
- `verify-m2.sh` has ONE soft-scaffolded sub-check: MMIO-activity on the
  decoder. Until `apple-gfx-pci-linux` publishes a counter property (or
  QEMU enables `apple_gfx_pci_mmio_*` trace events by default), this
  step warns rather than gates. Steps 1-3 of M2 still hard-gate.
- `verify-m4.sh`, `verify-m5.sh`, `verify-login-screen.sh`,
  `verify-desktop-idle.sh` are SCAFFOLDS. Their infrastructure
  (process checks, screenshot capture, diff harness) is real and
  tested; their pixel-diff assertion is gated behind `GATE_ON_DIFF=1`
  and will only be meaningful once Phase 3 (Metal->Vulkan translation)
  emits pixels through our stack and a reference image is captured.
  See `tests/screenshots/README.md` for the reference-capture workflow.
- `tests/metal-clear-screen.m` (M4) and `tests/metal-triangle.m` (M5)
  are standalone Objective-C stubs. Build on a Mac host, scp to the VM,
  run once the respective scaffold is graduating to real.

### Quick invocation reference

```bash
# Baseline (always run first — catches display-path regressions)
VM=user@vm-ip ./tests/verify-modes.sh

# M1 — end-to-end build + apple-gfx-pci registered
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-m1.sh

# M2 — guest kext attaches, MMIO reaches decoder, no panic
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-m2.sh

# M3 — Metal no-op (MTLCopyAllDevices >= 1 + empty cmdbuf round-trip)
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-m3.sh
# Or directly: VM=user@vm-ip ./tests/verify-phase1.sh

# M4 scaffold — first pixel (requires metal-clear-screen built + scp'd)
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-m4.sh

# M5 scaffold — first shader (requires metal-triangle built + scp'd)
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-m5.sh

# M6 — login screen scaffold
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-login-screen.sh

# M7 — desktop idle scaffold
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/verify-desktop-idle.sh

# Everything at once (skips M1 if SKIP_M1=1)
DOCKER_HOST=user@docker-host VM=user@vm-ip ./tests/run-all.sh
```

### Expected outputs per milestone

**M1** — last line on pass:
```
=== M1 gate: PASSED ===
  docker build: green
  apple-gfx-pci: registered in binary
  macOS: booted without panic
  display baseline: intact
```

**M2** — last line on pass:
```
=== M2 gate: PASSED ===
Next milestone: M3 — metal-no-op round-trip.
```
With a WARN line if MMIO-activity signal is not yet wired (soft-scaffolded
sub-check). Steps 1-3 of M2 still hard-gate.

**M3** — last line on pass:
```
=== M3 gate: PASSED ===
Next milestone: M4 — first pixel (Metal clear-color → noVNC solid color).
```
Delegates to `verify-phase1.sh` which prints `=== Phase 1 exit criterion MET ===`
before M3 adds its decoder-error check.

**M4 (scaffold mode)** — last line on pass:
```
=== verify-m4 scaffold: PASSED ===
```
With a WARN line noting the reference `tests/screenshots/reference/clear-color-red.png`
is missing until Phase 3 renders a red frame through the stack.

**M5 (scaffold mode)** — last line on pass:
```
=== verify-m5 scaffold: PASSED ===
```
With WARN lines for: shader catalog not deployed, `metal-triangle`
binary not built on host, reference `tests/screenshots/reference/triangle.png`
missing. All three clear once Phase 3 + `shader-catalog-plan.md` land.

**M6 (scaffold mode)** — last line on pass:
```
=== verify-login-screen scaffold: PASSED ===
```
With a warn that the reference image is missing until Phase 3 lands.

**M7 (scaffold mode)** — last line on pass:
```
=== verify-desktop-idle scaffold: PASSED ===
```
With the same reference-image warn.

---

## 0. Prerequisites (one-time setup)

- **Auto-login on the VM.** CoreGraphics APIs (the ones `list-modes` / `displayplacer` call) need a console-logged-in user bootstrap. Without it, `CGGetOnlineDisplayList` returns 0 and the whole observability layer goes dark.
  - Check: `ssh <vm-user>@<vm-ip> who` — expect `<vm-user> console <date>`
  - Enable: `sudo sysadminctl -autologin set -userName <user> -password <pw>` (run on the VM, once)
- **Compile the helpers** on the host mac (VM doesn't ship Xcode CLT):
  ```bash
  cd tests
  clang -arch x86_64 -mmacosx-version-min=10.15 \
      -framework Foundation -framework CoreGraphics -framework CoreVideo \
      list-modes.m -o list-modes
  clang -arch x86_64 -mmacosx-version-min=10.15 \
      -framework Foundation -framework Metal -framework CoreGraphics \
      metal-probe.m -o metal-probe
  ```
- **One-time Admin.plist patch** (macOS first-boot bug — not ours, but blocks until patched):
  ```bash
  ssh <vm-user>@<vm-ip> 'sudo plutil -replace trustList -array /var/protected/trustd/private/Admin.plist; sudo killall trustd'
  ```
  Without this, trustd burns ~62% CPU forever on "Malformed anchor records" looping. This persists across reboots until the file is patched. Tracked as task #26 to make it permanent in the image.

---

## 1. Build + deploy

Always from `~/mos/docker-macos`:
```bash
# (if mos15-patcher changed)
cd ~/mos/mos15-patcher && rm -f build/*.o && \
    KERN_SDK=$HOME/mos/docker-macos/kexts/deps/MacKernelSDK ./build.sh
cp -R build/mos15-patcher.kext $HOME/mos/docker-macos/kexts/deps/

# always
cd ~/mos/docker-macos/kexts/QEMUDisplayPatcher && rm -rf build && ./build.sh
cd ~/mos/docker-macos && ./build-mos15-img.sh && ./deploy.sh
```

Expected: `==> Starting macos-macos-1` and an image md5 printed.

**If build fails:** check the build.sh output for `error:` lines — compile errors are almost always in `patcher.cpp` or the macro expansion from `mos15_patcher.h`.

---

## 2. Boot reaches login / desktop

```bash
ssh docker "sudo docker logs --tail 500 macos-macos-1 2>&1" | grep -E "loginwindow|panic"
```

**Pass:** at least one line matching `loginwindow`, no `panic`.
**Fail modes:**
- `panic` — kernel trap during boot. Full backtrace earlier in the log. Most common cause: bad paramSig in a route, or vtable offset math wrong. Revert last change and bisect.
- no `loginwindow` line after 3+ minutes — hang during kext matching or userspace init. Scan for the last service to report start to find where it stuck.

---

## 3. mos15-patcher + QDP loaded

```bash
ssh docker "sudo docker logs --tail 3000 macos-macos-1 2>&1" | grep -E "^(mp:|QDP:)"
```

**Expected:**
```
mp:start: mos15-patcher starting
mp:start: cached N already-loaded kexts
QDP: starting (mos15-patcher edition)
mp:notify: registered publish notification for IONDRVFramebuffer (36 routes pending)
QDP: mp_route_on_publish returned 0 (n=36 routes)
```

If `mp:start` missing: kext didn't load. Check `kextload` errors in docker logs, and that `kexts/deps/mos15-patcher.kext` made it into the image (`build-mos15-img.sh` logs `Copying built kexts`).

If `QDP: starting` missing but mp:start ran: QDP.kext didn't load. Usually `OSBundleLibraries` version mismatch in Info.plist.

---

## 4. Hook coverage — 24/24 methods patched, 0 gaps

```bash
ssh <vm-user>@<vm-ip> "ioreg -c IONDRVFramebuffer -l 2>/dev/null" | grep -E '"MP[A-Z]'
```

**Expected (today, as of 2026-04-19 — post connectFlags fix):**
```
"MPMethodsHooked"    = 24
"MPMethodsMissing"   = 0
"MPMethodGaps"       = ()
"MPMethodsTotal"     = 24
"MPStatus"           = "Pf Pf Pf Pf Pf Pf PX PX PX PX PX PX PX Pf PX Pf Pf Pf Pf Pf Pf Pf Pf Pu "
"MPRoutesPatched"    = 24
```

The 24 method pairs covered (first = IONDRVFramebuffer override, second = IOFramebuffer base): enableController, hasDDCConnect, getDDCBlock, setGammaTable, getVRAMRange, setAttributeForConnection, getApertureRange, getPixelFormats, getDisplayModeCount, getDisplayModes, getInformationForDisplayMode, getPixelInformation, getCurrentDisplayMode, setDisplayMode, getPixelFormatsForDisplayMode, getTimingInfoForDisplayMode, getConnectionCount, setupForCurrentConfig, **getAttribute, getAttributeForConnection, registerForInterruptType, unregisterInterrupt, setInterruptState, connectFlags**.

**Status-char legend** (`MPStatus`, one pair per method, derived/base):
| char | meaning |
|------|---------|
| `P` | Primary kext resolved, vtable slot patched ✓ |
| `F` | Fallback kext (IOGraphicsFamily) resolved, patched ✓ |
| `u` | Primary resolved but slot already taken — harmless, other pair won |
| `f` | Fallback resolved but slot taken — harmless |
| `X` | Not resolved anywhere — intentional for pure-virtual base methods |

**A method pair is "hooked" if at least one of its two routes is `P` or `F`.** A gap is when both are `u/f/X`.

**If `MPMethodsMissing > 0`:** look at `MPMethodGaps` for the mangled names. Common causes:
- Typedef mis-mangle (param type is a typedef for something that mangles differently) — use `MP_ROUTE_PAIR_SIG` with explicit sig instead
- Method is overloaded — use `MP_ROUTE_PAIR_SIG` to disambiguate
- Symbol stripped from the kext — verify via `nm | grep <mangled>` on the kext binary

---

## 5. EDID identity — real iMac20,1 bytes in IOKit

```bash
ssh <vm-user>@<vm-ip> "ioreg -l 2>/dev/null" | grep -E '"DisplayProductID"|"DisplayVendorID"|"IODisplayEDID"' | head -3
```

**Expected:**
```
"DisplayProductID" = 44593      (0xAE31 — iMac20,1)
"DisplayVendorID"  = 1552       (0x0610 — Apple PnP "APP")
"IODisplayEDID"    = <00ffffffffffff00061031ae... 256 bytes ...44>
```

EDID length is 256 bytes (2 blocks). If only 128 bytes: `patchedGetDDCBlock`'s multi-block dispatch broke.

If VendorID != 1552: the old fabricated EDID is being served — our `imac20_edid_block0` didn't get compiled in. Rebuild QDP and redeploy.

---

## 6. Every patched hook actually fires

```bash
ssh docker "sudo docker logs --tail 3000 macos-macos-1 2>&1" | grep "^QDP:.*called" | sort -u
```

**Expected (at minimum):**
```
QDP: enableController -> 0x0 (SMC+VRAM=256MB)
QDP: hasDDCConnect called -> true
QDP: getDDCBlock called bn=1 bt=0
QDP: getDisplayModeCount called -> 8
QDP: getDisplayModes called (n=8)
QDP: getInformationForDisplayMode called mode=1
```

These prove the vtable swap is effective — macOS calls into our replacements.

**If any hook above is missing:** our swap happens too late for that call path, OR macOS reaches that functionality via a different IOKit class. **This is the fingerprint we check.**

Hooks that commonly don't fire (still not a failure — they're for post-init state changes):
- `setupForCurrentConfig` — only runs on reconfig events; may not fire on a clean boot
- `setDisplayMode` — only when user changes resolution
- `getTimingInfoForDisplayMode`, `getPixelInformation` — may or may not be consulted depending on framebuffer init path

---

## 7. CoreGraphics sees every mode we advertise

```bash
./tests/verify-modes.sh
```

**Expected:**
```
✓ mode visible in CoreGraphics: 1920x1080
✓ mode visible in CoreGraphics: 2560x1440
✓ mode visible in CoreGraphics: 5120x2880
✓ mode visible in CoreGraphics: 3840x2160
✓ mode visible in CoreGraphics: 3008x1692
✓ mode visible in CoreGraphics: 2048x1152
✓ mode visible in CoreGraphics: 1680x945
✓ mode visible in CoreGraphics: 1280x720
```

**State as of 2026-04-19 (post connectFlags fix): 7/8 visible.** The 5120×2880 mode is blocked upstream by QEMU's vmware-svga device model (max resolution is ~3840×2160) — not fixable in QDP. `tests/verify-modes.sh` tracks this as `EXPECTED_MODES_UPSTREAM_BLOCKED` and flags if the upstream block ever lifts.

Root cause of the earlier filtering (fixed): IONDRVFramebuffer's default `connectFlags(ci, modeID, *flags)` delegates to the NDRV driver. NDRV didn't recognize our custom mode IDs and returned `0`/`NeverShow`, so macOS hid them. Patched to return `kDisplayModeValidFlag | kDisplayModeSafeFlag` for every advertised mode.

---

## 8. VRAM + current display state

```bash
ssh <vm-user>@<vm-ip> "system_profiler SPDisplaysDataType"
ssh <vm-user>@<vm-ip> "ioreg -c IONDRVFramebuffer -l | grep -E 'IOFBCurrentPixelCount|IOFBMemorySize'"
```

**Expected:**
```
VRAM (Total): 256 MB
Vendor ID: 0x15ad    (VMware SVGA — this is the underlying device, not the EDID)

"IOFBMemorySize"        = 268435456     (256 MB)
"IOFBCurrentPixelCount" = 2073600       (1920×1080)
```

If VRAM shows 7 MB: `patchedEnableController`/`patchedSetupForCurrentConfig`'s `setProperty("IOFBMemorySize", ...)` isn't landing. Verify `kIOPCIConfigBaseAddress1` read is returning the 256 MB BAR.

---

## 9. 20-boot consistency (ship gate)

```bash
./kexts/QEMUDisplayPatcher/test-20.sh
```

Runs the whole stack 20 times in a row. Counts pass/fail.

**Ship gate:** 20/20 pass. Anything less = flakiness = do not archive `lilu-mos15` yet.

---

## Boot-log capture + analyze + VM health report

Three scripts for observing a boot rather than just gating on it:

- **`tests/capture-boot-log.sh`** — kicks a fresh boot and captures
  QEMU serial / `docker logs` into
  `tests/capture-boot-logs/<timestamp>/`. Stops at the first of:
  SSH reachable (exit 0), panic regex matched (exit 10), timeout
  (exit 20). Set `VM=` to enable the SSH-up trigger; unset to run
  capture-only. `--timeout N` overrides the default 300s. Artefacts
  written: `serial.log`, `docker.log`, `trigger.txt`, `status.txt`,
  `duration-sec.txt`, `panic-line.txt` (on panic), `analysis.json`
  (after analyze runs).
- **`tests/analyze-boot-log.sh <capture-dir>`** — pattern-matches a
  capture against `tests/patterns/*.patterns` and emits a JSON
  summary. Exit 0 if expected milestones (M1-M3) marked or capture
  ended with SSH-up; exit 1 on panic; exit 2 on missing milestones.
  JSON shape documented in the script header.
- **`tests/vm-health-report.sh <output-dir>`** — post-boot-success
  introspection. Gathers `ioreg`, `dmesg`, `log show` (kernel
  subsystem, last 5m), `system_profiler`, `ps auxc`, `docker ps`,
  `docker logs --tail 500`, repo SHAs, and bundles as a tar.gz.
  The file operators attach to bug reports.

**Pattern library:** `tests/patterns/panic.patterns`,
`tests/patterns/milestone-signals.patterns`,
`tests/patterns/hang-indicators.patterns`. Tab-separated 4-column
format. See `tests/patterns/README.md` for authoring guide.

**run-all integration:** opt-in via env flags.
`CAPTURE_BOOT=1 DOCKER_HOST=... ./tests/run-all.sh` captures + analyzes
the boot first. `VM_HEALTH_REPORT=1 VM=... ./tests/run-all.sh`
produces a health-report tar.gz at the end of the run. Neither is on
by default to keep run-all fast for iteration.

**Signals detected per milestone (non-exhaustive):**

- M1: OpenCore banner, `EB|#LOG:EXITBS:START`, `AppleSMC registered`,
  `hfs: mounted`, `loginwindow`, `WindowServer`.
- M2: `AppleParavirtGPU::start`, `apple-gfx-pci.*matched`,
  `apple_gfx_pci_realize`, `vendor-id.*0x106b`, `kextd.*AppleParavirtGPU`.
- M3: `MTLCreateSystemDefaultDevice returned non-null`,
  `lagfx_device_new`, `lagfx_cmdbuf_submit`, `lagfx_cmdbuf_complete`,
  `applegfx.*commit`.

**Panic signatures:** `panic(cpu N caller`, `Kernel trap at`,
`Kernel panic`, `Backtrace (CPU N)`, `AppleParavirtGPU.*assert`,
`apple-gfx-pci.*panic`, `qemu: fatal:`, `out of memory`,
`page fault in kernel mode`, etc. See
`tests/patterns/panic.patterns` for the full list.

---

## Quick reference — where each signal comes from

| Signal | Source | Read with |
|--------|--------|-----------|
| Kext loaded | serial console (docker logs) | `grep "mp:start\|QDP: starting"` |
| Routes registered | serial console | `grep "mp_route_on_publish"` |
| Per-method coverage | kernel ioreg property | `ioreg \| grep MPMethod` |
| Per-route status | kernel ioreg property | `ioreg \| grep MPStatus` |
| Hook fire evidence | serial console + ioreg counters | `grep "QDP:.*called"` + `QDPCallCounts` |
| Mode list as userspace sees it | CoreGraphics via `list-modes` | `launchctl asuser 501 /tmp/list-modes` |
| Current resolution | kernel ioreg | `ioreg \| grep IOFBCurrentPixelCount` |
| EDID bytes as delivered | kernel ioreg | `ioreg \| grep IODisplayEDID` |
| EDID vendor/product | kernel ioreg | `ioreg \| grep DisplayVendorID` |

Three independent observation points (serial log, kernel ioreg, userspace CG) — if a signal only shows in one of the three, that's itself informative (tells you which layer the breakdown is at).
