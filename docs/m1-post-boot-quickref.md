# M1 post-boot quick reference

One-page cheat sheet for operators running the M1 -> M2 -> M3
verification pipeline after `docker compose build` has landed green
on the docker host.

**Sibling docs (read them when this page is not enough):**

- `docs/m1-operator-runbook.md` — the full M1 walkthrough with
  pre-flight checklist, triage matrix, and known dry-run predictions.
- `docs/test-runbook.md` — the M1..M8 milestone overview and the
  verify-*.sh inventory.
- `docs/end-to-end-integration-guide.md` — why the pieces exist.
- `/Users/mjackson/Developer/mos/paravirt-re/re-followup-spec-gaps.md` §1 —
  doorbell spec that the capture tool references.

---

## One command

```bash
DOCKER_HOST=matthew@portainer-1 VM_HOST=matthew@mos15-vm \
    ./tests/m1-m3-pipeline.sh
```

That single invocation:

1. SSH's the docker host (exit 6 if unreachable).
2. `docker compose up -d` (exit 7 if compose fails outright).
3. Waits up to 60 s for the container to reach state=running (exit 1).
4. Waits up to 5 min for the guest to answer SSH (exit 2).
5. Runs `tests/verify-m1.sh` — hard M1 gate (exit 3 on fail).
6. Runs `tests/verify-modes.sh` — display baseline sanity (exit 5 on
   regression, but only after M1 has already passed).
7. Runs `tests/verify-phase1.sh` — M3 gate; graceful-fails (exit 4)
   today because the apple-gfx-pci hot path isn't lit yet.
8. Runs `tests/vm-health-report.sh` on the way out — **always**, even
   on failure — to leave a tarball artefact for later inspection.

### Knobs

| env var          | default                      | purpose                                                |
|------------------|------------------------------|--------------------------------------------------------|
| `DOCKER_HOST`    | (required)                   | ssh target for the docker host                         |
| `VM_HOST`        | (required)                   | ssh target for the macOS guest                         |
| `CONTAINER`      | `macos-macos-1`              | docker container name                                  |
| `REPO_DIR`       | `~/mos/docker-macos`         | path to docker-compose.yml on the host                 |
| `CONTAINER_WAIT` | `60`                         | seconds to wait for container state=running            |
| `SSH_WAIT`       | `300`                        | seconds to wait for guest SSH                          |
| `SKIP_M3`        | `0`                          | set to 1 to skip verify-phase1 entirely                |
| `HEALTH_OUT_DIR` | `tests/vm-health-reports`    | where the vm-health tarball lands                      |

### Exit codes at a glance

| code | meaning                                               | next action                                               |
|-----:|-------------------------------------------------------|-----------------------------------------------------------|
| 0    | all gates green, or M1+baseline green with M3 skipped | done                                                      |
| 1    | container never reached running state                 | read docker logs; see Step 2 triage below                 |
| 2    | VM SSH never came up                                  | see Step 3 triage below                                   |
| 3    | verify-m1.sh failed                                   | see Step 4 triage; consult `docs/m1-operator-runbook.md`  |
| 4    | M1 green but M3 (verify-phase1) failed                | expected today — see Step 6 triage                        |
| 5    | M1 green but display baseline regressed               | see Step 5 triage                                         |
| 6    | docker host unreachable                               | check SSH key, hostname, network                          |
| 7    | `docker compose up -d` failed outright                | read the last-20 lines in the pipeline output             |

---

## Per-step triage — what to do when a step fails

### Step 1 — `docker compose up -d` failed (exit 7)

- Read `docker compose up` output printed above the FAIL line. Common
  causes: image missing (you rebuilt the host's image but `compose`
  is still pointed at the old tag), port already in use (noVNC 6080
  collision), bind-mount target missing (`./run` or `./logs` not
  created yet — create them before first boot).
- See `docs/m1-operator-runbook.md` section "Step 3 — compose up".

### Step 2 — container never reached running (exit 1)

- Pipeline dumps the last 50 lines of `docker logs` automatically.
- `launch.sh`'s first `qemu-system-x86_64 -device help` sanity check
  failing is the canonical reason: image was built without
  apple-gfx-pci support. Rebuild. See
  `docs/m1-dry-run-prediction.md` rows P1-2 and P1-3.
- If you see `macvtap0 already exists`, ignore — launch.sh cleans it.

### Step 3 — VM SSH never came up (exit 2)

- Pipeline prints the last 80 lines of docker logs.
- Most common cause today: OpenCore stage hangs waiting for boot
  picker. Check: `ssh $DOCKER_HOST 'curl http://localhost:6080/'`
  and look at the noVNC picture — is it stuck at the OC picker?
- If the serial log shows a kernel panic during auto-mount, check
  `panic_info` section.
- See `docs/m1-operator-runbook.md` section "Step 4 — watch boot".
- Deeper introspection: re-run with CAPTURE_BOOT=1 through `run-all.sh`.

### Step 4 — verify-m1.sh failed (exit 3)

- The pipeline forwards verify-m1's own exit code in its output
  (lines starting with `verify-m1 exited N`). Specific codes:
  - 10 build failure (shouldn't happen post-build — means compose
    snuck a rebuild in on `up -d`)
  - 20 container wait (should have been caught by Step 2)
  - 30 apple-gfx-pci NOT in `qemu -device help` — rebuild image
  - 40 boot timeout (already handled by Step 3)
  - 50 panic in serial log — tarball it, file a bug
  - 60 verify-modes regressed INSIDE verify-m1 — see Step 5
- Full triage matrix: `docs/m1-operator-runbook.md` section "Step 5".

### Step 5 — verify-modes.sh regressed (exit 5)

- The display patcher stack changed semantics. Run it by hand:
  `VM=$VM_HOST ./tests/verify-modes.sh` for the full breakdown.
- Exit 2 = hook coverage hole; exit 3 = EDID identity mismatch;
  exit 4 = a previously-visible mode disappeared; exit 5 = a hook
  never fired.
- See `docs/test-runbook.md` section "M-baseline triage".

### Step 6 — verify-phase1.sh failed (exit 4)

- **Expected today.** Until libapplegfx-vulkan publishes as
  IOAccelerator on the guest, `MTLCopyAllDevices` returns 0 and
  phase1 exits 2.
- Specific phase1 codes:
  - 2 MTLCopyAllDevices = 0 — kext not publishing; no action for
    operators, this is a driver-side phase gap.
  - 3 metal-no-op binary missing on the host — build it:
    `(cd tests && clang -framework Foundation -framework Metal metal-no-op.m -o metal-no-op)`.
  - 4 metal-no-op returned non-zero — phase1 prints the sub-code;
    map via the phase1 script header.
- Collect a doorbell trace NEXT — see the section below.

---

## Collecting the doorbell capture

Once the VM is reachable over SSH (i.e. Step 3 passed), capture a
runtime trace of MMIO writes into the `apple-gfx-pci` BAR0 window.
This is the data the Phase 1.A.2 decoder needs to close the R1
doorbell-offset gap in `re-followup-spec-gaps.md` §1.5.

```bash
DOCKER_HOST=matthew@portainer-1 ./tests/capture-doorbell-mmio.sh
```

**Requirements:**

- Container must be running (Step 2 green).
- `launch.sh` must have created `/data/run/qemu-qmp.sock` — present
  on any build after commit b96604e.
- `socat` OR `python3` inside the container image. (Alpine base has
  neither out of the box — add `socat` to the Dockerfile if Mode A
  isn't picking up.)

**Best to run RIGHT AFTER `docker compose restart`** — the
first-MMIO-write burst happens during `MTLCreateSystemDefaultDevice`
in the very first seconds after guest kernel load. Capturing a
mid-life VM will miss the FIFO setup.

**What it does:**

- Handshakes QMP (`qmp_capabilities`).
- Mode A (preferred): enables trace event `apple_gfx_pci_mmio_write`,
  tails docker logs for 30 s, greps for writes to the candidate set
  {0x1004, 0x1008, 0x1010, 0x101c, 0x1020, 0x1024, 0x1028, 0x1030,
  0x1034}, and calls the first write AFTER a non-zero write to
  0x1000 the doorbell.
- Mode B (fallback when the trace event isn't compiled in): polls
  `xp` at 10 Hz across the candidate window, deltas state, and
  nominates the offset that flips latest.

**Artefacts land in:**

```
tests/capture-boot-logs/doorbell-<timestamp>/
├── doorbell-candidates.json   <- our verdict (mode, offset, confidence)
├── capture.log                <- raw scrape (trace lines or xp dumps)
├── capture-meta.txt           <- environment parameters
├── qmp-handshake.log          <- QMP banner + trace-event state
├── mmio-hits.txt              <- (Mode A) filtered candidate-set writes
├── writes-ordered.txt         <- (Mode A) seq-numbered writes
├── per-offset-trace.txt       <- (Mode B) value-over-time per offset
└── info-pci.log               <- (Mode B) BAR0 discovery
```

**Exit codes:**

| code | meaning                                                     |
|-----:|-------------------------------------------------------------|
| 0    | doorbell identified (confidence=high for A, low for B)      |
| 1    | inconclusive — no writes in candidate window in 30 s        |
| 2    | QMP socket unreachable / handshake failed                   |
| 3    | pre-flight: docker host or container not ready              |

If exit is 1, re-run immediately after `docker compose restart` to
catch the first-MMIO-write burst. If still 1, the guest probably
isn't touching the device at all — cross-check with verify-m2.sh.

---

## Expected artefacts after a green pipeline run

```
tests/
├── vm-health-reports/
│   └── vm-health-report-YYYYMMDDTHHMMSSZ/
│       ├── dmesg-last1000.log
│       ├── ioreg-all.log                    <- full IOKit registry
│       ├── ioreg-appleparavirtgpu.log       <- our PCI nub
│       ├── ps-auxc.log
│       ├── log-show-kernel-5m.log
│       ├── system-profiler-displays.log
│       ├── kextstat.log                     <- cross-ref AppleParavirtGPU
│       ├── who.log                          <- console-user invariant
│       ├── metal-probe.log                  <- MTLCopyAllDevices count
│       ├── docker-ps.log                    <- host-side container state
│       ├── docker-logs-tail500.log          <- QEMU serial tail
│       ├── qemu-cmdline.txt                 <- proves -device apple-gfx-pci
│       ├── host-identity.log                <- vulkaninfo, uname -a
│       ├── repo-shas.txt                    <- SHAs of all mos-* repos
│       └── capture-meta.txt
│   └── vm-health-report-*.tar.gz            <- the shippable tarball
└── capture-boot-logs/                       <- (if doorbell capture run)
    └── doorbell-YYYYMMDDTHHMMSSZ/
        └── doorbell-candidates.json         <- the R1 verdict
```

**What each artefact means:**

- `vm-health-report-*.tar.gz` — the single attachment for any bug
  report. Contains everything needed to reconstruct guest + host
  state at the moment of the run.
- `ioreg-appleparavirtgpu.log` non-empty and containing an
  IOProbeScore line => M2 gate effectively green.
- `metal-probe.log` with `count: N>=1` => M3 preconditions met.
- `qemu-cmdline.txt` containing `apple-gfx-pci` => confirms launch.sh
  actually wired the device (can be subverted by fallback mode).
- `doorbell-candidates.json` with `"verdict_confidence": "high"` and
  a non-null `doorbell_offset` => the R1 gap is closed, update
  `re-followup-spec-gaps.md` §1.5 with the verdict.

---

## If the pipeline goes sideways

1. **Always** grab the vm-health tarball — it's produced even on
   failure, and it's the quickest way to hand off state to someone
   else.
2. Read `docs/m1-operator-runbook.md` for the authoritative
   operator walkthrough.
3. Read `docs/test-runbook.md` for the milestone-chain overview.
4. File a bug with the tarball attached + the pipeline's output,
   citing the step number and exit code from the summary footer.
