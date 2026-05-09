# Regression testing

Visual regression chain that bisects which component broke display
rendering. Five phases, each isolating exactly one variable on top of
the previous. Captures gold screenshots; future runs compare against
them with ImageMagick.

Used for development; not needed for normal end-user runtime.

## The chain

| Phase | Stack | Expected outcome |
|---|---|---|
| 0 | Vanilla QEMU 11.0.0 + OVMF + empty disk + `-vga std` | UEFI Interactive Shell visible |
| 1 | + macOS image + OpenCore EFI on disk + OEM unpatched QEMU | OpenCore picker visible |
| 2 | Same as 1 with mos-qemu patched binary | Identical to Phase 1 (binary swap is benign) |
| 3 | + Apple identity (`-device isa-applesmc` + `-device apple-kbd/tablet`) | macOS boots to login (if APFS unlocks) or same picker |
| 4 | + `-vga none -device apple-gfx-pci` (= production target) | **Black screen** until libapplegfx-vulkan opcode handlers ship (M5 stage 20%) |

Single-variable per phase. If something regresses, the chain pinpoints
which addition caused it.

## Running

```bash
# One-time: build the test image (extends production with OEM QEMU + chromium)
./mos build-test

# Run a phase (interactive — opens noVNC on port 6080+phase)
./mos test 0
./mos test 1
./mos test 2
./mos test 3
./mos test 4
```

Each phase opens noVNC on its own port (no conflict with production):

| Phase | URL |
|---|---|
| 0 | http://localhost:6080/vnc.html?autoconnect=1 |
| 1 | http://localhost:6081/vnc.html?autoconnect=1 |
| 2 | http://localhost:6082/vnc.html?autoconnect=1 |
| 3 | http://localhost:6083/vnc.html?autoconnect=1 |
| 4 | http://localhost:6084/vnc.html?autoconnect=1 |

## Visual regression

After each phase boots, capture and compare against the gold:

```bash
# From the host (the laptop dev workstation, not the docker host):
scripts/capture-screenshot.sh N      # scp current PNG into baselines/
scripts/compare-regression.sh N      # ImageMagick perceptual diff vs gold
# Exit 0 = match, exit 1 = drift, exit 2 = no gold yet (bootstrap)
```

If no gold exists yet for a phase, the comparison exits 2 with a hint:
inspect `baselines/phase-N-current.png` by eye. If it matches what the
phase should produce, promote it:

```bash
cp baselines/phase-N-current.png baselines/phase-N-gold.png
git add baselines/phase-N-gold.png
git commit -m "phase N gold: <what it shows>"
```

Future runs will diff against this gold and FAIL if drift exceeds
threshold.

## Capture pipelines

Two separate paths exist:

1. **Headless Chromium → noVNC HTML** (sidecar approach). Captures the
   noVNC viewer's view of the framebuffer. Includes noVNC's chrome
   (left sidebar, top status bar). Same dimensions across phases
   (1920×1080).

2. **QMP `screendump`** (direct framebuffer). Talks to QEMU's QMP
   socket, asks for a PPM dump of the actual framebuffer, converts to
   PNG. Pure framebuffer, no noVNC chrome. Resolution matches whatever
   QEMU is using (640×480 if QEMU never set higher mode; 1920×1080
   once OpenCore promotes it).

Phase 4 specifically uses QMP because the production launch path
doesn't run bundled noVNC — its display device (apple-gfx-pci) doesn't
even initialize a framebuffer until the M5 backend ships, so chromium
would just see "Failed to connect."

## What each gold means

| Gold | Captured via | What it shows |
|---|---|---|
| `phase-0-gold.png` | chromium noVNC | UEFI Interactive Shell text on black background |
| `phase-1-gold.png` | chromium noVNC | OpenCore boot picker — "UEFI Shell" entry visible |
| `phase-2-gold.png` | chromium noVNC | Same OpenCore picker as phase 1 (binary swap benign) |
| `phase-3-gold.png` | chromium noVNC | macOS login screen OR same picker (depends on APFS unlock state at the moment of capture) |
| `phase-4-gold-black.png` | QMP fb | 640×480 "Guest has not initialized the display (yet)" — QEMU stock no-init screen |

## Pass criteria

Each phase passes when ALL of:

1. Container is `Up` after 75s (didn't exit early)
2. noVNC `GET /vnc.html` returns 200 (or QMP socket exists for phase 4)
3. Capture exists at `baselines/phase-N-current.png`
4. Visual diff vs `baselines/phase-N-gold.png` is below threshold
5. Serial log shows expected markers (no kernel panic; phase 3+ shows
   "WindowServer started" if APFS unlocks)
6. Gold exists (committed to git)

If any criterion fails: stop and triage before advancing. Single-variable
bisection only works if the prior phase was a known pass.

## Phase 4 = M5 milestone gate

The interesting phase is 4. Today it produces a black screen because
the apple-gfx-pci device has no working host backend (libapplegfx-vulkan
opcode handlers `0x003c`, `0x0036`, etc. unimplemented). When those land
(M5 stage 20%), Phase 4's gold will need updating to whatever-macOS-
shows-via-paravirt-GPU.

That gold update IS the M5 milestone proof. Until then, the black
screen is the "expected" state.

## Don't

- Don't iterate single-variable on the display path while skipping the
  visual verification step. The whole point of this framework is "see
  what changed."
- Don't claim a phase passed without actually running
  `compare-regression.sh` and reading its exit code.
- Don't bake screenshot capture into the production Dockerfile. The
  test image is separate; production stays minimal.
- Don't update a gold to mask a real regression. If diff fails, find
  the cause first. Tune threshold only when drift is verifiably noise
  (clock pixels, cursor blink, anti-aliasing variation).

## Architecture

`Dockerfile.test` extends `Dockerfile` with:

- A second QEMU 11.0.0 build (no patches) at `/usr/bin/qemu-system-x86_64-oem`
- chromium + xvfb + py3-pillow for headless capture
- `scripts/test.sh` — per-phase QEMU arg builder

`scripts/test.sh` takes the phase number and configures:

- Which binary (`/usr/bin/qemu-system-x86_64-oem` for phase 1, otherwise patched)
- Which display device (`-vga std` for 0..3, `-vga none -device apple-gfx-pci` for 4)
- Which USB stack (`usb-kbd/tablet` for 0..2, `apple-kbd/tablet` for 3..4)
- SMC presence (none for 0..2, `isa-applesmc,osk=...` for 3..4)
- Networking (always user-mode in test — phases run alongside production)
- Bundled noVNC port (6080..6084)

That's all in one ~150-line script. Bug fixes happen in one place.

## Cross-references

- [architecture.md](architecture.md) — overall code layout
- [troubleshooting.md](troubleshooting.md) — what to do when a phase fails
- [incidents/2026-05-06-disk-wipe.md](incidents/2026-05-06-disk-wipe.md) — why the architecture collapsed to one Dockerfile + one launch script + one test runner
