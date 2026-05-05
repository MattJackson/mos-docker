# Phase regression baselines

Golden screenshots for the phased VNC regression chain. Each phase has
an expected visual outcome; tests pass when the captured frame matches
the gold within an ImageMagick perceptual-diff threshold.

## Files

| File | Phase outcome |
|---|---|
| `phase-0-gold.png` | UEFI shell (vanilla VNC test — no macOS) |
| `phase-1-gold.png` | OpenCore picker (OEM 10.2.2 + OpenCore EFI) |
| `phase-2-gold.png` | OpenCore picker — must match phase-1 (proves patches don't regress) |
| `phase-3-gold.png` | macOS login screen (vmware-vga path) |
| `phase-4-gold-black.png` | **BLACK SCREEN** (apple-gfx-pci, opcode handlers unimplemented — expected) |

## Workflow

### Bootstrap (first pass per phase)

1. Run the phase: `ssh docker 'cd /home/matthew/mos-docker && sudo docker compose -f compose.phaseN.yml -f compose.screenshot.yml up -d'`
2. Wait for boot + screenshot capture: `sleep 90`
3. Pull capture: `scripts/capture-screenshot.sh N`
4. Inspect `baselines/phase-N-current.png`. If it's correct, promote:
   ```
   cp baselines/phase-N-current.png baselines/phase-N-gold.png
   git add baselines/phase-N-gold.png
   git commit -m "phase N gold: <description>"
   ```

### Regression check (subsequent runs)

1. Run the phase + capture as above.
2. `scripts/compare-regression.sh N` — exits 0 on match, 1 on drift.
3. Drift FAIL: visual inspection. Real regression → investigate. Just
   noise (clock pixels, cursor blink) → tune the threshold in
   `scripts/compare-regression.sh`. Don't update the gold to mask a bug.

## What's committed vs not

- ✅ `phase-N-gold.png` — committed (canonical).
- ❌ `phase-N-current.png` — transient, regenerated each run. Excluded by `.gitignore`.
- ❌ `phase-N-diff.png` — diff overlay, transient. Excluded.
