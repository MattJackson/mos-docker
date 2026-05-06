# Phase regression baselines

Golden screenshots for the phased VNC regression chain. Each phase has
an expected visual outcome; tests pass when the captured frame matches
the gold within an ImageMagick perceptual-diff threshold.

## Files

| File | Phase outcome |
|---|---|
| `phase-0-gold.png` | UEFI shell (sanity — bare QEMU + OVMF + std-vga, no macOS) |
| `phase-1-gold.png` | macOS Sequoia login screen on **OEM** stock-QEMU bare-min stack (std-vga + isa-applesmc + ICH9 globals + usb-kbd) **[TRANSIENT]** |
| `phase-2-gold.png` | Same login as phase-1 (patched binary swap, proves patches don't regress) |
| `phase-3-gold.png` | Same login as phase-2 (+ apple-kbd / apple-tablet HID swap) |
| `phase-4-gold-black.png` | **BLACK SCREEN + cursor** (apple-gfx-pci paravirt — opcode handlers unimplemented; visible pixels here = M5 stage 20% gate) |

**[TRANSIENT]** phases retire as patches land upstream:
- Phase 1 dropped when our QEMU patches upstream — OEM and patched then converge.
- End state: 0 sanity, 1 patched-baseline-login, 2 + apple-kbd, 3 apple-gfx-pci product.

## Bare-min stack (Phase 1+)

The minimum config that reaches macOS login on stock QEMU 10.2.2:

- pflash OVMF + OpenCore.img + macOS HD (virtio-blk-pci)
- `-device VGA,xres=1920,yres=1080,vgamem_mb=64,edid=on` (std-vga + EDID)
- `-device isa-applesmc,osk=...`  ← **required** (otherwise AppleACPICPU hangs)
- `-global ICH9-LPC.disable_s3=1`
- `-global ICH9-LPC.disable_s4=1`
- `-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off`
- `-device qemu-xhci` + `usb-kbd` + `usb-tablet`
- e1000 / virtio-net networking

Without `isa-applesmc` + ICH9 globals, macOS hangs in `busy timeout[N]: 'AppleACPICPU'` backoff (60s → 60s → 60s → 240s → ...) and never reaches login.

## Workflow

### Bootstrap (first pass per phase)

1. Run the phase: `./mos test N`
2. User visually verifies via noVNC at `http://localhost:608N/vnc.html?autoconnect=1`
3. Capture via QMP screendump (pixel-perfect, no noVNC chrome) into `baselines/phase-N-current.png`
4. Promote on visual confirm: `cp baselines/phase-N-current.png baselines/phase-N-gold.png`

### Regression check (subsequent runs)

1. Run the phase + capture as above.
2. Compare current vs gold via ImageMagick perceptual diff.
3. Drift FAIL: visual inspection. Real regression → investigate. Just
   noise (clock pixels, cursor blink) → tune the threshold. Don't update
   the gold to mask a bug.

## What's committed vs not

- ✅ `phase-N-gold.png` — committed (canonical).
- ❌ `phase-N-current.png` — transient, regenerated each run. Excluded by `.gitignore`.
- ❌ `phase-N-diff.png` — diff overlay, transient. Excluded.
