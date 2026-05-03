---
name: Docker macOS Project
description: macOS 15 VM in Docker — Lilu plugin patches IONDRVFramebuffer. EDID works when hooks fire. Consistency fix needs Xcode to build Lilu from source.
type: project
originSessionId: 8c675b67-a9c6-46e5-9b0a-46a2684276fb
---
**Status (2026-04-18):** Lilu plugin approach. When hooks fire: EDID + gamma + enableController all work, display shows as "iMac". Consistency issue requires building Lilu from source with a one-line fix. Installing Xcode.

**Current approach:** QEMUDisplayPatcher — Lilu plugin in Boot KC patches IONDRVFramebuffer via `routeMultiple`. No System KC dependency.

**What works (when onKextLoad fires):**
- 4/4 methods routed: enableController, hasDDCConnect, getDDCBlock, setGammaTable
- Display shows as Apple iMac (VendorID 0x610, ProductID 0x9CC3)
- Login screen works, no crashes (without calling orgEnableController)
- Correct mangled names: `__ZN17IONDRVFramebuffer...` (17 chars)

**Two blockers:**
1. **Consistency (~60% of boots):** Lilu's `onOSKextSaveLoadedKextPanicList` returns early when `activated=false` (kern_patcher.cpp:849). System KC kexts load before `activate()`. Fix: one line in Lilu source — set `waitingForAlreadyLoadedKexts=true` instead of returning. **Need Xcode to build Lilu properly** (manual clang build crashed due to DriverKit symbols, plist variables, missing deps).
2. **Trampoline crash:** `orgEnableController` trampoline to System KC function causes page fault. Workaround: return 0 without calling original. OEM NDRV init skipped, display works via VGA fallback.

**Lilu fix location:** `kexts/deps/Lilu-src/Lilu/Sources/kern_patcher.cpp` line 849 — change from early return to setting waitingForAlreadyLoadedKexts flag.

**Key files:**
- `kexts/QEMUDisplayPatcher/` — plugin source + build.sh
- `kexts/QEMUDisplay/` — proven display driver (reference)
- `kexts/deps/Lilu-src/` — Lilu source with fix (needs Xcode build)
- `kexts/deps/Lilu-1.7.2-DEBUG/` — official binary (currently deployed)
- `DISCOVERY.md` — findings #1-56

**Deploy cycle:**
1. Build: `cd kexts/QEMUDisplayPatcher && bash build.sh`
2. Copy: `tar cf - build/QEMUDisplayPatcher.kext | ssh docker 'cat > /tmp/qdp.tar'`
3. Stop VM, mount opencore15.img, replace in EFI/OC/Kexts/, unmount, start
4. Login detection: `loginwindow` in serial logs

**Next steps:**
1. Install Xcode, build Lilu from source with consistency fix
2. Run 20-boot test — must be 20/20
3. Then add features one at a time: VRAM property, SMC keys
4. Then fix trampoline crash (or replicate NDRV init ourselves)
