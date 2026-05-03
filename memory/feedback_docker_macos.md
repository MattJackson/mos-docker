---
name: Docker macOS workflow rules
description: How Matt wants changes made to the macOS VM project — one at a time, documented, proven
type: feedback
originSessionId: 8c675b67-a9c6-46e5-9b0a-46a2684276fb
---
**One change at a time.** Change, test, prove it works, document why, move on. Never batch multiple changes — we can't tell what broke or fixed things.

**Why:** Multiple changes at once caused confusion about which SMBIOS was actually running and whether fixes worked.

**How to apply:**
- Make one config change per reboot
- Verify via SSH/serial that the change took effect
- Document the finding in DISCOVERY.md before moving to the next change

---

**Stop VM before pushing OpenCore.** QEMU holds the file open and writes to it. scp while running = corrupted checksums.

**Why:** Pushed images didn't match checksums, wasted multiple test cycles.

**How to apply:** Always `docker stop` → `scp` → verify md5 → `docker start`

---

**No `/tmp` for anything persistent.** Use the project directory or host volumes.

**Why:** Files in /tmp are lost on reboot. Lost a compiled VMsvga2 kext this way.

---

**Remove what's not used.** Don't leave disabled kexts on disk. If it's not in the build, delete it. Document why it was removed.

**Why:** Clean is clean. Carrying dead files causes confusion about what's active.

---

**Everything baked in, not patched on macOS.** Fixes should be in QEMU args, OpenCore config, or launch.sh — not `pmset` or `defaults write`. Fresh installs must work out of the box.

**Why:** macOS-side patches are lost on reinstall.

---

**Document every finding.** Every error gets tracked. Every fix attempt gets documented with the result, even failures. DISCOVERY.md is the source of truth.

**Why:** So we can roll back. "What did we try and what happened?" must always be answerable.

---

**Verify SMBIOS after every deploy.** Check from inside macOS (`system_profiler SPHardwareDataType`) not just the config file. NVRAM can cache stale values.

**Why:** Spent multiple cycles thinking we were on iMac20,2 when we were actually on iMacPro1,1.
