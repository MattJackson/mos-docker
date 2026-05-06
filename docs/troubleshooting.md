# Troubleshooting

Common runtime issues + recovery. If you hit something not in this
list, file an issue with the relevant `data/logs/serial-*.log`
attached.

## Container won't start

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: /dev/kvm not present` | Host kernel missing KVM module, or container not privileged | `sudo modprobe kvm_intel` (or `kvm_amd`); pass `--privileged --device /dev/kvm` |
| `ERROR: /dev/kvm exists but not writable` | Container user not in kvm group | `--privileged` (runs as root, ignores group check) |
| `ERROR: /data is not mounted` | Forgot `-v PATH:/data` | Add the bind mount |
| `ERROR: /data is not writable` | Host bind-mount path owned by root, container running as user | Make host dir owned by container user, or pass `--user 0:0` |
| `ERROR: $DISK does not exist` | Ran `run` before `install` | Run `mos install` first |
| `ERROR: $DISK is only N bytes` | Aborted install left a corrupt disk | `rm ~/mos-docker/data/disk.img` and re-run install |
| `ERROR: $OPENCORE missing` | Forgot to drop `OpenCore.img` in `data/` | See [opencore-image.md](opencore-image.md) |
| Container exits with 141 immediately | Port 6080 collision (websockify can't bind) | Stop conflicting container; verify with `ss -tlnp \| grep 6080` |

## Install fails

| Symptom | Cause | Fix |
|---|---|---|
| `Recovery image not found at /data/recovery.img` | Forgot to drop `recovery.img` | See [recovery-image.md](recovery-image.md) |
| `disk.img already exists (>1 MiB) — looks installed` | Refusing to overwrite | `rm ~/mos-docker/data/disk.img` then re-run install — this is the explicit consent gesture |
| OpenCore picker shows but no macOS entry | Disk wasn't formatted; or APFS driver missing in OpenCore.img | In Disk Utility → erase as APFS first; if persists, see [opencore-image.md](opencore-image.md) APFS troubleshooting |
| Install hangs at Apple logo | SMBIOS / kext mismatch | Check `data/logs/serial-*.log` for panic messages; usually iMac20,1 SMBIOS + correct kext bundle fixes this |
| "You're not connected to the internet" in recovery | macvtap not active OR host iface wrong | See [networking.md](networking.md) |
| Keyboard / mouse don't respond in recovery | Was using `apple-kbd`/`apple-tablet`; recovery doesn't bind those | Use `usb-kbd`/`usb-tablet` — see `feedback_apple_hid_breaks_recovery.md` in the mos memory; current `run.sh` already does this |

## Display / VNC issues

| Symptom | Cause | Fix |
|---|---|---|
| noVNC connects but shows "Guest has not initialized the display (yet)" | apple-gfx-pci device active without working backend (M5 not shipped) | Default `run.sh` uses `-vga std` which works. Don't set `MOS_USE_APPLE_GFX_PCI=1` until libapplegfx-vulkan opcode handlers ship |
| noVNC connects briefly then disconnects | QEMU crashed | Check `docker logs <container>` and `data/logs/serial-*.log` |
| noVNC shows "Failed to connect to server" red bar | QEMU's VNC server not bound, or websockify died | `docker logs` will show; usually a port conflict on 6080 |
| Resolution stuck at 800x600 | OpenCore set 1920x1080 in pre-boot but macOS reverted | macOS needs the right framebuffer kext (whatevergreen, etc.) — see [opencore-image.md](opencore-image.md) |

## Network issues

| Symptom | Cause | Fix |
|---|---|---|
| VM gets `169.254.x.x` (link-local) | Host NIC has no real DHCP | macvtap inherits whatever the host NIC sees; if host is on Wi-Fi or isolated, fix host first |
| `ERROR: HOST_IFACE='X' not found inside container` | Specified NIC doesn't exist | Unset `HOST_IFACE` to auto-detect, or set to a valid name |
| Auto-detect picks wrong NIC (multi-NIC host) | First-UP non-virtual NIC isn't the internet-facing one | Set `HOST_IFACE=<correct iface>` explicitly |
| `Failed to add macvtap0` | Host kernel missing macvtap module | `sudo modprobe macvtap` on the host |
| Wi-Fi host: macvtap unreliable | Wi-Fi drivers refuse to bridge promiscuous frames | Wired Ethernet, or fall back to user-mode (unset HOST_IFACE) |

See [networking.md](networking.md) for details.

## Inside macOS, post-install

| Symptom | Cause | Fix |
|---|---|---|
| `trustd` burns 60% CPU forever | macOS first-boot bug (well-known, not VM-specific) | `sudo plutil -replace trustList -array /var/protected/trustd/private/Admin.plist; sudo killall trustd` (one-time) |
| `WindowServer` crashes / respawns | Display kext not loaded or wrong GPU device | `kextstat \| grep -i graphics`; check `OpenCore.img` includes WhateverGreen.kext (or equivalent for the display device used) |
| Wallpaper white / dynamic wallpaper broken | `WallpaperAgent` memory limit hit (no GPU acceleration) | Static wallpaper for now; full fix requires real GPU |
| Audio dead | AppleALC missing or wrong codec | Add `AppleALC.kext` to OpenCore.img + `boot-args alcid=N` matching your audio device |
| Setup Assistant won't connect to Apple ID | Network OK but Apple ID activation needs valid SMBIOS serials | Use a proper iMac20,1 serial / MLB / ROM triplet (genSMBIOS tool) — random ones fail activation |

## Build issues

| Symptom | Cause | Fix |
|---|---|---|
| Build fails: `Dependency "libapplegfx-vulkan" not found, tried pkgconfig` | Build cache from a multi-builder Dockerfile attempt | `docker builder prune -a -f`, rebuild |
| `failed to compute cache key: ... /tmp/qemu-install/usr/bin/qemu-system-x86_64: not found` | Builder stage cached as broken | Same fix: prune builder cache |
| Build hangs at "Configuring with meson" | Network fetch of QEMU/mos-qemu/libapplegfx-vulkan tarballs slow | Wait; 10-20 min cold-cache is normal |
| `OSError: [Errno 98] Address in use` (websockify) | Stale container holding port 6080 | `docker ps -a`, stop/remove stale containers |

## Debugging tools

```bash
# Live container logs
docker logs -f mos-docker-install

# QEMU monitor (HMP) — interactive QEMU console from host
sudo socat - unix:~/mos-docker/data/run/qemu-monitor.sock
# (qemu) info qtree              # device tree
# (qemu) screendump /data/run/X.ppm    # framebuffer dump
# (qemu) quit                    # graceful shutdown

# Serial log (per-boot timestamped)
tail -f ~/mos-docker/data/logs/serial-$(ls ~/mos-docker/data/logs | sort | tail -1)

# QMP socket (structured JSON, scriptable)
sudo socat - unix:~/mos-docker/data/run/qemu-qmp.sock
# > {"execute": "qmp_capabilities"}
# > {"execute": "query-status"}
```

## When all else fails

1. Stop the container: `docker stop mos-docker-install`
2. Capture state: `tar czf debug-$(date +%Y%m%d).tar.gz ~/mos-docker/data/logs ~/mos-docker/data/run/*.sock 2>/dev/null`
3. File an issue at <https://github.com/MattJackson/mos-docker/issues> with:
   - Host info (`uname -a`, `lscpu | head`, kernel KVM module, docker version)
   - Container logs (`docker logs <container>` since last start)
   - Latest 200 lines of `data/logs/serial-*.log`
   - The exact `docker run` command you used
