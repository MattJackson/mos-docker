# End-to-end integration guide (M1 → M8)

Single operator-facing flow for bringing the full mos stack up from a
fresh clone and verifying every milestone from M1 (docker build green)
through M8 (1080p @ 30fps interactive). This is the master walkthrough
that ties together what already exists in this repo and the peer repos.

---

## 1. What this guide is

The authoritative "given a fresh clone, how do I verify every
milestone" runbook. Cross-links to the deeper docs rather than
restating them.

- **M1 specifics** — see `docs/m1-operator-runbook.md`. That doc is
  the 60-minute first-light walkthrough. This guide references it
  rather than duplicating its content.
- **Milestone test matrix + script quick-reference** — see
  `docs/test-runbook.md`. Canonical per-milestone exit-criterion
  table.
- **Screenshot / reference-image workflow** — see
  `tests/screenshots/README.md`. Canonical capture + diff
  procedure.
- **QEMU build internals** — see `docs/qemu-mos15-build.md`. Used
  during triage of build-stage failures.

Use this guide when you want the entire M1..M8 sequence in one
scrollable page with timing, triage pointers, and performance
expectations. Use the sibling docs when you've narrowed to a single
milestone or subsystem.

---

## 2. Prerequisites

All must be true before starting. First-run setup details are in
`docs/m1-operator-runbook.md` §0 and `docs/test-runbook.md` §0; this
is the summary.

- **SSH access to the docker host.** `ssh matthew@portainer-1 true`
  succeeds. Set once: `export DOCKER_HOST_SSH="matthew@portainer-1"`.
- **SSH access to the macOS guest.** Once the VM is up, you'll
  discover its IP from the docker host's ARP table and set
  `VM_SSH="matthew@<vm-ip>"`. First-boot one-time setup
  (auto-login, `sudo systemsetup -setremotelogin on`) is documented
  in `SETUP.md` and `docs/test-runbook.md` §0.
- **Host-side tools (on `$DOCKER_HOST_SSH`):** docker + compose,
  `arp`, `curl`, `socat` or `nc`. Optional but strongly
  recommended: `vulkaninfo` (for baseline capability diff),
  `imagemagick` (for screenshot diff).
- **Dev-machine tools (on your laptop):** `imagemagick` (`brew
  install imagemagick`) for the pixel-diff scripts, `xcrun` +
  `clang` for compiling the `metal-*.m` test binaries on a real Mac
  host.
- **Git state — all five repos pushed to origin.** The Dockerfile
  fetches tarballs from GitHub, not local trees. Run:
  ```bash
  git -C /Users/mjackson/libapplegfx-vulkan push
  git -C /Users/mjackson/qemu-mos15       push
  git -C /Users/mjackson/docker-macos     push
  git -C /Users/mjackson/mos              push   # private
  git -C /Users/mjackson/mos-opencore     push 2>/dev/null || true
  ```
  If any of these are behind origin, M1 will silently build against
  stale tarballs and triage gets messy. `m1-operator-runbook.md` §0
  has the same checklist in copy-paste form.
- **Guest-side one-time:** auto-login enabled (`sudo sysadminctl
  -autologin set ...`), Admin.plist patched (one-liner in
  `test-runbook.md` §0). Without auto-login, CoreGraphics +
  WindowServer APIs return empty and everything from M4 onward is
  untestable.

---

## 3. Milestone chain

Summary of every gate. One row per milestone. The verify scripts
embed the canonical exit codes in their headers; this is a
cross-reference.

| # | Exit criterion | Verify script | Expected duration | What to do if red | Artifacts produced | Depends on |
|---|---|---|---|---|---|---|
| M1 | `docker compose build` exits 0; binary registers `apple-gfx-pci`; macOS boots with no panic | `tests/verify-m1.sh` | 25–30m cold (build dominates), 8–10m warm | `docs/m1-operator-runbook.md` §2 triage; exit-code map in script header (10/20/30/40/50/60) | `/tmp/build.log`, docker container, no screenshots yet | none |
| M2 | AppleParavirtGPU.kext binds; `apple-gfx-pci` in IOService; no panic; MMIO activity signal | `tests/verify-m2.sh` | 2–3m | Exit-code map in header (10/20/30/40). Most common: kext didn't bind — check `vendor-id 0x106b` in `ioreg -p IOPCI`; see `test-runbook.md` §3 | ioreg snapshot in stdout | M1 |
| M3 | `tests/metal-no-op.m` exit 0; `MTLCopyAllDevices >= 1`; empty cmdbuf round-trip | `tests/verify-m3.sh` (wraps `verify-phase1.sh`) | 1–2m | Exit-code map (10 phase1-failed / 20 mtl-count-zero / 30 decoder-errors). If phase1 failed, drop to `verify-phase1.sh` directly for a narrower signal | none | M2 |
| M4 | **SCAFFOLD TODAY.** Real once Phase 2.B lands booted-VM output: Metal clear-color → Vulkan clear → noVNC shows solid red | `tests/verify-m4.sh` + `tests/metal-clear-screen.m` | 1–2m (scaffold), 3–5m once real | Scaffold fails only on infrastructure: 10 novnc-unreachable, 20 capture-failed, 30 diff-exceeded. Once real, `GATE_ON_DIFF=1` flips — red frame diff against reference | `tests/screenshots/<stamp>-clear-color.png`, reference `tests/screenshots/reference/clear-color-red.png` (captured on first green) | M3 + Phase 2.B pixel path |
| M5 | **SCAFFOLD TODAY.** One stock shader: AIR → LLVM → SPIR-V → lavapipe → visible triangle | `tests/verify-m5.sh` + `tests/metal-triangle.m` | 2–3m (scaffold), 4–6m once real | Exit-code map (10 catalog-missing / 20 cmdbuf-failed / 30 diff-exceeded). Today every sub-check WARNs because catalog + translator + reference are all deferred | `tests/screenshots/<stamp>-triangle.png`, reference `tests/screenshots/reference/triangle.png` | M4 + Phase 3.C/3.D (catalog + shaders) |
| M6 | **SCAFFOLD TODAY.** loginwindow's CALayer compositing through our stack; Apple login visible at 1080p | `tests/verify-login-screen.sh` | 1–2m (scaffold) | 10 loginwindow-not-running / 20 capture-failed / 30 diff-exceeded / 40 reference-missing. Today: only steps 1–2 hard-gate (loginwindow up, capture works) | `tests/screenshots/<stamp>-login.png`, reference `tests/screenshots/reference/login.png` | M4 + M5 + Phase 3 complete |
| M7 | **SCAFFOLD TODAY.** Dock + menu bar + windows render without corruption at 1080p | `tests/verify-desktop-idle.sh` | 2–3m (scaffold; includes 10s idle wait) | 10 WindowServer-missing / 20 capture-failed / 30 diff-exceeded / 40 reference-missing | `tests/screenshots/<stamp>-desktop-idle.png`, reference `tests/screenshots/reference/desktop-idle.png` | M6 + Phase 3 complete |
| M8 | Sustained 30 fps at 1080p on common UI ops (drag, menu, cursor) | Benchmark TBD — Phase 5 | n/a (not yet built) | n/a (harness is Phase 5) | Perf log, fps curve | M7 + `gpu_cores` tunable calibrated |

All scaffold verify scripts pass today with WARNs. That is
intentional — see `tests/screenshots/README.md` and §9 below.

---

## 4. Full execution flow

Numbered sequence the operator runs start-to-finish. Each step lists
its time budget, the exact commands, what to expect on green, and
what to do on red. If a step is green, move to the next. If red,
follow the triage pointer; don't skip ahead.

### Step 1 — Pull + build (M1)

**Time:** 25–30m cold / 8–10m warm.
**Commands:**
```bash
export DOCKER_HOST_SSH="matthew@portainer-1"
export REPO_DIR="~/mos/docker-macos"
ssh "${DOCKER_HOST_SSH}" "git -C ${REPO_DIR} pull --ff-only origin main"
ssh "${DOCKER_HOST_SSH}" "cd ${REPO_DIR} && sudo docker compose build 2>&1 | tee /tmp/build.log"
```
**Green signal:** `=> => naming to docker.io/library/docker-macos-macos`
and exit 0.
**Red signal:** any non-zero exit; map to
`docs/m1-operator-runbook.md` §1 Step 3 triage table (six common
causes, six fixes). Do not proceed until green.

### Step 2 — Boot + SSH baseline (pre-M2)

**Time:** 2–4m first boot, 1–2m subsequent.
**Commands:**
```bash
ssh "${DOCKER_HOST_SSH}" "cd ${REPO_DIR} && sudo docker compose up -d"
ssh "${DOCKER_HOST_SSH}" "sudo docker logs -f macos-macos-1" | head -200
# Once loginwindow appears in logs, discover the VM IP:
ssh "${DOCKER_HOST_SSH}" \
    "arp -a | grep -i \$(sudo docker exec macos-macos-1 \
                        cat /sys/class/net/macvtap0/address)"
export VM_SSH="matthew@<vm-ip-from-arp>"
ssh "${VM_SSH}" true
```
**Green signal:** `loginwindow` lines in docker logs; `ssh "$VM_SSH"
true` exits 0; no `panic(cpu` line.
**Red signal:** VM panics mid-boot → escalate (see §6). Silent
without SSH reach after 5m → `m1-operator-runbook.md` §2 "SSH to VM
fails".

Run the M1 verify as the gate:
```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m1.sh
```
Expected last line: `=== M1 gate: PASSED ===`. Any earlier FAIL
names the step; compare exit code against the script preamble.

### Step 3 — Attach device + verify binding (M2)

**Time:** 2–3m.
**Commands:**
```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m2.sh
```
**Green signal:** `=== M2 gate: PASSED ===`. Optional WARN about
MMIO-activity signal is expected today (soft-scaffolded per
`test-runbook.md` §M2; steps 1–3 still hard-gate).
**Red signal:** exit 10 (kext not attached) or 20 (node not bound)
— verify QEMU cmdline actually passes `-device apple-gfx-pci` on
the running process:
```bash
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 sh -c \
     'cat /proc/1/cmdline | tr \"\\0\" \" \"'" \
   | grep -o 'apple-gfx-pci[^ ]*'
```
Empty output → relaunch with `APPLE_GFX=yes sudo -E docker compose
up -d --force-recreate` (per `verify-m1.sh` step 4 WARN).

### Step 4 — Run metal-no-op (M3)

**Time:** 1–2m.
**Prerequisite:** `tests/metal-no-op` compiled on a macOS dev
machine and scp'd to the VM. Build invocation is in
`tests/metal-no-op.m` header; copy to the VM at `/tmp/metal-no-op`.
**Commands:**
```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m3.sh
```
**Green signal:** `=== M3 gate: PASSED ===`, decoder-error count 0.
**Red signal:** exit 10 (phase1 failed) → drop to
`tests/verify-phase1.sh` directly for a tighter signal. Exit 20
(`MTLCopyAllDevices < 1`) is the kext-not-attached fingerprint and
means M2 was actually red; re-run M2. Exit 30 (decoder errors) →
inspect `docker logs --tail 2000 macos-macos-1 | grep -i
'applegfx.*error'`.

### Step 5 — Run metal-clear-screen + capture reference (M4)

**Time:** 3–5m once Phase 2.B is live; 1–2m in scaffold mode today.
**Scaffold mode (2026-04):** the script validates infrastructure
(noVNC reachable, capture pipeline works). Real mode requires
`tests/metal-clear-screen.m` compiled, scp'd, and executed on the
VM after M3 is green.

**Commands:**
```bash
# On your Mac dev machine:
cd ~/mos/docker-macos/tests
clang -arch x86_64 -mmacosx-version-min=10.15 \
    -framework Foundation -framework Metal -framework QuartzCore \
    metal-clear-screen.m -o metal-clear-screen
scp metal-clear-screen "${VM_SSH}:/tmp/metal-clear-screen"

# On the VM:
ssh "${VM_SSH}" "sudo -n launchctl asuser 501 /tmp/metal-clear-screen"

# Run the verify:
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m4.sh
```

**Green signal (scaffold today):** `=== verify-m4 scaffold:
PASSED ===` with a WARN about the reference image being missing.
**Green signal (real, post-Phase-2.B):** `GATE_ON_DIFF=1` ./verify-m4.sh
passes; delta ≤ 30 against `tests/screenshots/reference/clear-color-red.png`.

**Reference-capture workflow on first green:** per
`tests/screenshots/README.md` §"End-to-end workflow":
1. Verify visually via noVNC that the frame is solid red.
2. `./tests/screenshots/capture-reference.sh clear-color-red "first
   red frame via apple-gfx-pci + lavapipe"`.
3. Commit the PNG + metadata.
4. Flip `GATE_ON_DIFF` default in `verify-m4.sh` from 0 to 1.

**Red signal:** exit 10 (noVNC unreachable) → check compose port
mapping; exit 20 (capture failed) → run
`tests/screenshots/check-prereqs.sh` for missing tools; exit 30
(diff exceeded) → inspect the timestamped capture vs reference.

### Step 6 — Run metal-triangle (M5)

**Time:** 4–6m once Phase 3.D ships the shader catalog; 2–3m in
scaffold mode.
**Commands:** Same shape as Step 5 with `metal-triangle.m`:
```bash
clang -arch x86_64 -mmacosx-version-min=10.15 \
    -framework Foundation -framework Metal -framework QuartzCore \
    tests/metal-triangle.m -o tests/metal-triangle
scp tests/metal-triangle "${VM_SSH}:/tmp/metal-triangle"
ssh "${VM_SSH}" "sudo -n launchctl asuser 501 /tmp/metal-triangle"

DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m5.sh
```
**Green signal (scaffold):** `=== verify-m5 scaffold: PASSED ===`
with WARNs for the three deferred sub-checks (catalog deployed,
binary built, reference captured).
**Green signal (real, post-Phase-3.D):** triangle frame matches
reference within tolerance 40.
**Red signal:** exit 10 (catalog missing) → shader catalog hasn't
been built into the Docker image; exit 20 (cmdbuf didn't complete)
→ likely panic or translator crash; exit 30 (diff) → inspect.

### Step 7 — Boot to login screen + capture reference (M6)

**Time:** 1–2m (scaffold), with the understanding that the VM must
already be booted from Step 2. No new artifacts need to be scp'd.
**Commands:**
```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-login-screen.sh
```
**Green signal (scaffold today):** `=== verify-login-screen
scaffold: PASSED ===` with a WARN about reference missing.
**Green signal (real, post-Phase-3):** visible login screen
matches `tests/screenshots/reference/login.png` within MAE 20.
**Red signal:** exit 10 (loginwindow not running) → macOS didn't
reach the login stage, check M2/M3 first. Exit 20 (capture
failed) → run `tests/screenshots/check-prereqs.sh`.

### Step 8 — Reach Dock + capture reference (M7)

**Time:** 2–3m (scaffold; includes 10s idle wait). Requires
auto-login enabled (Step 2 prerequisite).
**Commands:**
```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-desktop-idle.sh
```
**Green signal (scaffold):** `=== verify-desktop-idle scaffold:
PASSED ===`. WindowServer + Dock running, capture pipeline works.
**Green signal (real, post-Phase-3):** static desktop matches
`tests/screenshots/reference/desktop-idle.png` within MAE 30.
**Red signal:** exit 10 (WindowServer or Dock missing) → auto-login
bootstrap didn't run; check `ssh "$VM_SSH" who` shows console user.

### Step 9 — Run fps benchmark (M8)

**Time:** TBD (Phase 5 harness not yet built).
**Prerequisite:** Phase 5 lands; M7 green.
**Expected shape:** drive a known workload (window drag, menu open,
cursor move) for 60s at 1080p and measure wall-clock fps via
`CVDisplayLink` or a GPU query timeline in the guest. Target is
the scaling curve in §5, not a single fixed number.

### Running everything at once

```bash
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/run-all.sh
```
`run-all.sh` runs baseline → M1 → M2 → M3 → M4 → M5 → M6 → M7 in
order, continuing past failures and producing an aggregate
summary. Use `SKIP_M1=1` once M1 is known-green to iterate faster.

---

## 5. Performance expectations per phase

The project's bar is **1080p @ 30fps useful for real work, with fps
scaling by allocated host cores** (see
`~/mos/memory/project_100pct_target.md`). Per-phase expectations:

- **M1 (build + boot):** no perf signal. Black screen + no panic =
  green. Boot time end-to-end target: ≤ 4 min from
  `docker compose up -d` to SSH reach.
- **M2 (kext + MMIO):** no perf signal. Soft-scaffolded MMIO
  counter becomes a sanity signal later.
- **M3 (no-op round-trip):** one empty cmdbuf commit should
  complete in ms. The metric to watch is "doesn't hang" not "is
  fast".
- **M4 (first pixel):** fps doesn't matter yet. The one-shot clear
  exists to prove the pipeline, not to benchmark it.
- **M5 (first shader):** one-shot triangle draw. Still not a perf
  gate. If frame takes > 1s to render, something is wrong with
  lavapipe or translator, but ≤ 1s is fine.
- **M6 (login screen):** first useful perf signal. Login screen
  should appear within ~2s of loginwindow starting. 2–3 repaints
  per second under idle is fine — the UI is nearly static.
- **M7 (static desktop):** first perf gate. With 8 cores allocated
  to the device, idle desktop should sustain ≥ 30 fps (baseline
  measurement target).
- **M8 (interactive):** the scaling curve is the deliverable. Not a
  single fps number.

### The measured scaling curve (reference)

Measured on `portainer-1` docker host, Mesa lavapipe 25.2.8 / LLVM
20.1.2, `vkmark desktop:windows=5` at 1920×1080 (source:
`~/mos/memory/project_tunable_gpu_cores.md`):

| Cores (LP_NUM_THREADS) | 1080p fps | Scaling vs 1-core |
|---|---|---|
| 1  | 17  | 1.0× baseline |
| 4  | 65  | 3.8× |
| 8  | **125** | 7.4× — clears 30 fps bar with 4× headroom |
| 16 | 216 | 12.7× |

Scaling is ~linear to 8 cores, then memory-bandwidth plateaus (16
cores = 1.73× of 8). Expected CPU-Vulkan behaviour.

**Operator application:** set `gpu_cores` per VM to the point on
the curve that matches host budget + fps target. 8 cores is the
recommended default for a single VM on a 16-core host. 4 cores is
the minimum that still clears the bar with margin. 1 core is
supported (for testing / footprint) but below the bar.

**4K perf is not a v1 bar** — `project_100pct_target.md`
explicitly calls 4K HiDPI out of scope. 4K@60 is demonstrable with
32+ cores but not a supported contract; noVNC transport
bandwidth would be the bottleneck anyway.

---

## 6. When to escalate

Signals that are NOT triage-table items — file a bug and stop.

- **`docker build` fails with an error not in
  `docs/m1-dry-run-prediction.md`.** The dry-run doc enumerates
  the six most-likely-seen build failures. Anything outside that
  set means a regression we haven't predicted. Collect the full
  build log, last-10 SHAs of all five repos, and file the bug.
  Don't grind — the fix is almost certainly a missing push.
- **VM panics mid-boot.** Extract:
  - `sudo docker logs --tail 500 macos-macos-1` (the serial log).
  - The noVNC screenshot at the moment of panic (visually
    distinctive — either kernel panic gray screen, frozen Apple
    logo, or progress-bar stop).
  - Run `ssh "$VM_SSH" "sudo log show --last 10m --predicate
    'subsystem == \"com.apple.kernel\"'"` if the VM came back up
    long enough to gather a post-mortem log.
- **`IOServiceMatching` fails for `apple-gfx-pci` when the device IS
  in `ioreg -p IOPCI`.** The device is on the bus but the match
  dict isn't picking it up. This is a kext personality bug — hold
  on M2 until the R1 runtime-capture work lands and the observed
  match dict is updated accordingly. Don't patch blindly.
- **Lavapipe reports 0 fps at 1080p.** Confirm the memfd backend
  is active (`LP_NUM_THREADS` is honoured) and `gpu_cores` is set
  on the device line. 0 fps with thread count > 0 is not a
  lavapipe bug; it means the VkImage allocation failed or the
  render path isn't emitting commands. Capture the container's
  `docker logs`, host `vulkaninfo --summary`, and the lagfx log
  with `LAGFX_LOG` at info+ level.

Anything else — grind through the per-script triage tables.
Anything that crosses 3 hours without progress on any single
milestone: escalate and file a bug report (see §9 below).

---

## 7. Where things live (index)

Canonical locations for every artefact this guide references. Paths
are absolute; use `$REPO_DIR` on the docker host where noted.

**Docs (on your dev machine + docker host):**
- `docs/end-to-end-integration-guide.md` — this file. Master flow.
- `docs/m1-operator-runbook.md` — 60-min M1 first-light walkthrough.
- `docs/m1-dry-run-prediction.md` — paper audit of expected M1 failures.
- `docs/test-runbook.md` — multi-milestone test matrix overview.
- `docs/qemu-mos15-build.md` — QEMU build internals, fast-iterate path.
- `tests/screenshots/README.md` — reference-image capture workflow.

**Verify scripts (run on dev machine or docker host):**
- `tests/verify-m1.sh` — M1 CI-style gate.
- `tests/verify-m2.sh` — M2 kext-bind gate.
- `tests/verify-m3.sh` — M3 no-op gate (wraps `verify-phase1.sh`).
- `tests/verify-m4.sh` — M4 first-pixel gate (SCAFFOLD today).
- `tests/verify-m5.sh` — M5 first-shader gate (SCAFFOLD today).
- `tests/verify-login-screen.sh` — M6 login gate (SCAFFOLD today).
- `tests/verify-desktop-idle.sh` — M7 desktop-idle gate (SCAFFOLD today).
- `tests/verify-phase1.sh` — delegated by M3; Metal no-op runner.
- `tests/verify-modes.sh` — display baseline regression gate.
- `tests/run-all.sh` — top-level sequential runner.

**Screenshot workflow (shared between scripts):**
- `tests/screenshots/capture-reference.sh` — promote capture → reference.
- `tests/screenshots/diff-reference.sh` — ad-hoc diff tool.
- `tests/screenshots/check-prereqs.sh` — install-check for capture tools.
- `tests/screenshots/reference/` — committed ground-truth PNGs.

**Test binaries (Objective-C, build on Mac dev machine):**
- `tests/metal-no-op.m` — M3 minimal round-trip.
- `tests/metal-probe.m` — M3 device-enumeration probe.
- `tests/metal-clear-screen.m` — M4 red clear.
- `tests/metal-triangle.m` — M5 triangle draw.
- `tests/list-modes.m` — baseline CoreGraphics mode enumeration.

**Cross-repo dependencies (all must be pushed):**
- `~/libapplegfx-vulkan` (public) — paravirt lib; Phase 1/2/3 surface.
- `~/qemu-mos15` (public) — QEMU fork with `apple-gfx-pci-linux` overlay.
- `~/docker-macos` (public) — this repo. Compose + tests + docs.
- `~/mos` (private) — plans, memory, paravirt-re.
- `~/mos-opencore` (PR-only fork) — OpenCorePkg edits; Acidanthera
  PR #600 filed for System KC loading (not on critical path).

---

## 8. Artifacts produced + where they go

Each milestone produces artefacts used by later milestones or by
triage. Canonical retention:

- **Build logs:** `/tmp/build.log` on the docker host. Tail for
  `=> => naming to ...` as the success signal. Keep after a red
  run; delete after a green.
- **Container logs:** `sudo docker logs --tail 5000 macos-macos-1`.
  The serial console output of the VM lives here. Preserve to a
  file for any red run (`> ./macos-tail.log`).
- **VM `log show` dumps:** `ssh "$VM_SSH" "sudo log show --last
  30m ..."`. Expensive — only capture during triage.
- **Screenshots:** `tests/screenshots/<stamp>-<milestone>.png`.
  Per-run captures, not committed (`.gitignore`). References:
  `tests/screenshots/reference/<milestone>.png`, committed with a
  metadata side-car.
- **Diffs:** `tests/screenshots/diffs/<ref-name>-<stamp>.png`, only
  emitted on failure. Not committed.

---

## 9. Open items / known gaps

What's SCAFFOLD today and when it becomes REAL.

| Milestone | Scaffold item | Blocker | Real when |
|---|---|---|---|
| M2 | MMIO-activity counter | `apple-gfx-pci-linux` doesn't publish decoder-stats counter in ioreg yet; QEMU trace events not enabled by default | Add counter property or enable `apple_gfx_pci_mmio_{read,write}` trace events by default. Open. |
| M4 | Reference screenshot `clear-color-red.png` | Phase 2.B landed at `libapplegfx-vulkan@8edc43c` library-side; booted VM run still owed | After Phase 2.B booted-VM run emits first pixel; operator captures manually via `capture-reference.sh`. |
| M4 | `metal-clear-screen.m` running on VM | Requires M3 green + Mac build host to compile | Post-M3; compile step is ~1 min on a Mac |
| M5 | Shader catalog deployed at `/usr/share/applegfx/shader-catalog` | `shader-catalog-plan.md` authors 5 shaders; build-time step not yet in Dockerfile | Phase 3.D — stock shader inventory (~3 days authoring) + Dockerfile layer |
| M5 | `metal-triangle.m` binary built | Stub file exists; compile step waits on M4 | Post-M4 |
| M5 | Reference `triangle.png` | Phase 3 translator emits a real triangle | After Phase 3 complete; operator captures |
| M6 | Reference `login.png` | Phase 3 emits pixel output for CALayer composite | After Phase 3 complete |
| M7 | Reference `desktop-idle.png` | Same as M6 | After Phase 3 complete |
| M8 | Perf harness | Phase 5 work item (not yet scoped) | Phase 5, conditional on Phase 3 landing below 30fps at 1080p |

Until those gates flip from SCAFFOLD to REAL, the scaffolded
scripts pass with WARNs. That is by design — it means the
infrastructure (capture, diff, process detection) is tested and
won't be the bottleneck the day the real signal becomes available.

See `tests/screenshots/README.md` §"Status (Phase 0 snapshot)" for
the canonical status and the flip procedure.

---

## 10. Bug-report checklist

If you have to escalate (see §6), collect everything below BEFORE
filing. Without these, the report is unactionable.

```bash
# --- Git SHAs: proves which tree was actually built ---
ssh "${DOCKER_HOST_SSH}" "git -C ${REPO_DIR} rev-parse HEAD"
git -C /Users/mjackson/libapplegfx-vulkan rev-parse HEAD
git -C /Users/mjackson/qemu-mos15         rev-parse HEAD
git -C /Users/mjackson/docker-macos       rev-parse HEAD
git -C /Users/mjackson/mos                rev-parse HEAD
git -C /Users/mjackson/mos-opencore       rev-parse HEAD 2>/dev/null || echo n/a

# --- Compose + serial logs ---
ssh "${DOCKER_HOST_SSH}" "sudo docker logs --tail 500 macos-macos-1" \
    > ./macos-tail.log
ssh "${DOCKER_HOST_SSH}" "tail -500 /tmp/build.log" > ./build-tail.log

# --- Verify-script outputs ---
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m1.sh > ./verify-m1.log 2>&1 || true
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m2.sh > ./verify-m2.log 2>&1 || true
# ...repeat for the milestone that failed

# --- Host identity ---
ssh "${DOCKER_HOST_SSH}" "uname -a"
ssh "${DOCKER_HOST_SSH}" "vulkaninfo --summary 2>&1 | head -40" \
    > ./host-vulkan.log

# --- VM-side triage (if VM reachable) ---
ssh "${VM_SSH}" "ioreg -c AppleParavirtGPU -l 2>/dev/null" > ./vm-ioreg-agpu.log
ssh "${VM_SSH}" "sudo dmesg | tail -200" > ./vm-dmesg.log
ssh "${VM_SSH}" "sudo log show --last 10m \
    --predicate 'subsystem == \"com.apple.kernel\"' 2>/dev/null" \
    > ./vm-log-show.log

# --- Screenshot if we got that far ---
ssh "${DOCKER_HOST_SSH}" \
    "sudo docker exec macos-macos-1 vncsnapshot -quiet \
     127.0.0.1::5901 /tmp/shot.png && \
     sudo docker cp macos-macos-1:/tmp/shot.png /tmp/shot.png"
scp "${DOCKER_HOST_SSH}":/tmp/shot.png ./escalation-shot.png
```

Then attach everything to the bug report plus a one-paragraph
description of which step in §4 failed, what the log said, and
which triage steps from the relevant per-script table were
attempted.

The most common root cause for escalated reports is "origin was
behind local on one of the five repos." The SHAs in the first
block above catch this in 10 seconds.

---

## 11. Quick reference card

For operators who've done this before and just need the commands:

```bash
# Env
export DOCKER_HOST_SSH="matthew@portainer-1"
export REPO_DIR="~/mos/docker-macos"

# Build
ssh "${DOCKER_HOST_SSH}" "git -C ${REPO_DIR} pull --ff-only origin main && \
    cd ${REPO_DIR} && sudo docker compose build && sudo docker compose up -d"

# Get VM IP
ssh "${DOCKER_HOST_SSH}" \
    "arp -a | grep -i \$(sudo docker exec macos-macos-1 \
                        cat /sys/class/net/macvtap0/address)"
export VM_SSH="matthew@<vm-ip>"

# M1 → M7 in order
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/run-all.sh

# Or iterate on a single milestone:
DOCKER_HOST="${DOCKER_HOST_SSH}" VM="${VM_SSH}" \
    ~/mos/docker-macos/tests/verify-m3.sh

# noVNC quick view
open "http://${DOCKER_HOST_SSH#*@}:6080/vnc.html"

# Capture a reference once a milestone is real
DOCKER_HOST="${DOCKER_HOST_SSH}" \
    ~/mos/docker-macos/tests/screenshots/capture-reference.sh \
    clear-color-red "first red frame via apple-gfx-pci + lavapipe"
```

---

## 12. What this guide is NOT

- **Not a developer-side walkthrough for building Phase 2/3 code.**
  That lives in `~/mos/paravirt-re/phase-2-first-pixel-plan.md`,
  `~/mos/paravirt-re/phase-3-metal-vulkan-plan.md`, and
  `~/mos/metal-implementation-plan.md`.
- **Not a replacement for `m1-operator-runbook.md`.** That is the
  detailed 60-min walkthrough with per-failure triage rows. This
  guide cross-links rather than duplicating.
- **Not a spec for any wire-protocol or API surface.** Those live
  in `~/mos/paravirt-re/command-buffer-format.md` and
  `~/mos/paravirt-re/metal-api-surface-for-desktop.md`.
- **Not a perf-tuning guide.** Perf is Phase 5; the scaling curve
  in §5 is measured, not a tuning recipe. When M8 work starts, a
  sibling `docs/perf-tuning.md` will be produced.

---

**End of end-to-end integration guide.**
