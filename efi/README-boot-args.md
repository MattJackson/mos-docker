# macOS boot-args — what each flag does and why

OpenCore writes the `boot-args` value in `EFI/OC/config.plist` into NVRAM
(`7C436110-AB2A-4BBB-A880-FE41995C9F82`) at boot. xnu reads it from NVRAM
during platform-expert init and passes recognized flags to subsystems.

This file is a parallel reference to the plist; the plist itself can't
contain comments without risking OpenCore's strict parser. Edit
`config.plist` and update this file together.

## Tag scheme

- **[macOS]** — mandatory or recommended for any KVM-hosted macOS. Apply
  to other QEMU-on-Linux setups verbatim.
- **[project]** — our dev/debug stack. Other projects would substitute
  their own observability conventions.

## Current boot-args

```
keepsyms=1 kext-dev-mode=1 serial=3 -liludbgall amfi_get_out_of_my_way=1
debug=0x44 kdp_match_name=en0 -v tlbto_us=0 vti=9
```

| Flag | Tag | Purpose |
|---|---|---|
| `keepsyms=1` | [project] | Keep kernel symbol table in panic backtraces — `_foo+0xN` resolves to a function name instead of a raw address. |
| `kext-dev-mode=1` | [project] | Allow loading non-Apple-signed kexts during dev. No-op now that we ship zero injected kexts; safe to remove on a clean stock-only run. |
| `serial=3` | [project] | Redirect kernel `printf` to COM1. QEMU's `-serial file:` captures it into `serial-phaseN.log` for post-mortem analysis. |
| `-liludbgall` | [project] | Verbose [Lilu](https://github.com/acidanthera/Lilu) logging when Lilu is loaded. No-op without Lilu in the kext chain (current state). |
| `amfi_get_out_of_my_way=1` | [macOS] | Bypass legacy AMFI codesign enforcement. **Does NOT cover macOS 13+ Launch Constraints** — that's a separate gating layer (`_proc_check_launch_constraints`) which `amfi_get_out_of_my_way` does not disable. |
| `debug=0x44` | [macOS] | `DB_KPRINTF \| DB_NMI` — enables kprintf-to-serial and NMI-triggered debugger entry. Useful when kernel hangs without panicking. |
| `kdp_match_name=en0` | [project] | Bind kernel debugger (kdp) to interface `en0`. Harmless when no remote debugger is attached; useful when one is. |
| `-v` | [macOS] | Verbose boot. **Side effect:** hides Recovery's graphical UI, so don't use during initial install (use `-no_compat_check` and remove `-v` if installing). |
| `tlbto_us=0` | [macOS] | Disable TLB-flush IPI timeout. xnu's default (~5 ms) is too tight under KVM — cross-socket TLB shootdowns can exceed it on contended hosts, firing spurious "TLB shootdown timeout" panics. Setting to 0 disables the timeout entirely. Mitigates the `pmap_remove_range "corrupt list"` and `pmap_query_page_info` panic class observed 2026-05-10. |
| `vti=9` | [macOS] | Inflate kernel timer-interrupt timeout 8× (default 1, max 9). Closes race windows on slow virt hosts where IPI delivery + processing exceeds the default. Sherlock's QEMU/KVM stability set, applied alongside `tlbto_us=0`. |

## Why we don't use `amfi_enforce_launch_constraints=0`

The deep-research agent suggested adding `amfi_enforce_launch_constraints=0
amfi_allow_3p_launch_constraints=1 ipc_control_port_options=0` to disable
macOS 13+ Launch Constraints (the `_proc_check_launch_constraints` layer
that fires the AMFI 245 "unable to accelerate context" line for
loginwindow + 20 other system services).

We have **not** added these because:

1. Direct evidence from phase 9 (2026-05-10): loginwindow respawns once,
   stabilizes, the login picker renders, and login proceeds normally.
   The 245 spam is genuinely "non-fatal" as Apple labels it — the
   constraint check fails but the service runs anyway.
2. The respawn loop diagnosis from phase 4 was a measurement artifact:
   `test.sh`'s phase 4 supervisor sent `system_powerdown` after ~2 min
   when the PASS regex matched, before loginwindow had a chance to
   stabilize.
3. Skipping these flags keeps the config closer to a real Mac's NVRAM
   for OEM-install testing (the project goal).

If a real Launch Constraints failure surfaces (loginwindow truly cannot
launch, or a specific service we need fails its constraint), revisit
this.

## What we changed and when

- **2026-05-10**: Added `tlbto_us=0 vti=9` to fix xnu pmap panics
  (`pmap_remove_range`, `pmap_query_page_info`) on dual-socket
  Haswell-EP host. Layered on top of NUMA pinning (`MOS_NUMA_NODE=0`
  in `scripts/test.sh`) which alone reduced panic frequency from 3-5
  min to 12+ min uptime but didn't fully eliminate.
