# Setup

End-to-end guide from blank Linux host to running macOS in a container. Read top-to-bottom — order matters.

## 1. Host prerequisites

```bash
# CPU virtualization — should print VMX (Intel) or SVM (AMD)
grep -Eo 'vmx|svm' /proc/cpuinfo | head -1

# /dev/kvm exists and is accessible
ls -l /dev/kvm                                   # should be crw-rw---- root:kvm
sudo usermod -aG kvm "$USER" && newgrp kvm       # if you weren't already in kvm

# Docker installed, version recent enough for compose v2
docker --version                                 # ≥ 20.10
docker compose version                           # ≥ 2.x

# Disk space — recommend ≥ 300 GB free where ./data/ will live
df -h .
```

If any of these fail, fix them before proceeding.

## 2. Get the repo (or skip and use the published image)

You can use the published image without cloning. Skip this section if you only want to run macOS — the README's two-command quickstart works directly. Clone only if you want to build locally or contribute:

```bash
git clone https://github.com/MattJackson/mos-docker
cd mos-docker
```

## 3. Acquire the macOS recovery image

The container can't install macOS without an Apple recovery image (~3.2 GB). Apple doesn't distribute these directly, but `macrecovery.py` from OpenCore's utilities fetches them.

On any Linux or macOS host with python3:

```bash
# Get OpenCore's utilities (only macrecovery.py is needed)
git clone --depth=1 https://github.com/acidanthera/OpenCorePkg
cd OpenCorePkg/Utilities/macrecovery

# Download the Sequoia recovery DMG. The board id (-b) selects which OS;
# Mac-AA95B1DDAB278B95 = iMac20,1 (which is the SMBIOS this stack advertises).
python3 macrecovery.py -b Mac-AA95B1DDAB278B95 -m 00000000000000000 download

# This produces: BaseSystem.dmg + BaseSystem.chunklist + RecoveryHDMeta.dmg

# Convert DMG to raw (Apple's DMG format is unreadable to QEMU)
# Linux:   apt install dmg2img    (or your distro's equivalent)
# macOS:   brew install dmg2img
dmg2img BaseSystem.dmg recovery.img

# Drop the result where mos-docker will see it
mkdir -p ~/mos-docker/data
mv recovery.img ~/mos-docker/data/recovery.img
```

**Resulting size:** ~3.2 GB. This file is needed only for `install`. After macOS is installed you can delete it (the container won't try to read it).

## 4. Acquire the OpenCore EFI image

OpenCore is the bootloader that lets QEMU + OVMF chain to macOS. You need a bootable EFI image (`OpenCore.img`) with:

- `EFI/OC/OpenCore.efi`
- `EFI/BOOT/BOOTx64.efi`
- `EFI/OC/Drivers/` (must include an APFS driver such as `ApfsDriverLoader.efi`)
- `EFI/OC/Kexts/` (Lilu, VirtualSMC, AppleALC, etc — depends on what you need)
- `EFI/OC/config.plist` (reasonable Sequoia-targeted config)

Two paths to get this image:

### 4a. Use a prebuilt image from the mos project

If you're using mos-docker as part of the broader `mos` ecosystem, the OpenCore image is built by `mos-opencore`'s build script. See <https://github.com/MattJackson/mos-opencore> for instructions.

### 4b. Build your own

Outside mos-docker's scope, but the typical recipe is:

1. Download OpenCore release: <https://github.com/acidanthera/OpenCorePkg/releases>
2. Lay out an EFI partition: `EFI/OC/`, `EFI/BOOT/`, with required drivers + kexts
3. Edit `config.plist` for SMBIOS = iMac20,1 (matches what mos-docker's launcher tells QEMU)
4. Pack into a 512 MB FAT32 image:
   ```bash
   dd if=/dev/zero of=OpenCore.img bs=1M count=512
   mkfs.vfat -n "OPENCORE" OpenCore.img
   sudo mount -o loop OpenCore.img /mnt/oc
   sudo cp -r EFI /mnt/oc/
   sudo umount /mnt/oc
   ```

Drop the resulting `OpenCore.img` at `~/mos-docker/data/OpenCore.img`.

## 5. Build the container image (skip if using ghcr.io)

```bash
cd mos-docker
./mos build
```

Builds:
- `mos-docker:latest` (production) — alpine + patched QEMU + libapplegfx-vulkan + OVMF + scripts

First build takes ~10–20 minutes (compiles QEMU 11.0.0 from source + libapplegfx-vulkan). Subsequent builds use BuildKit cache + ccache and rebuild affected layers in ~30 s to ~2 min.

## 6. Install macOS

```bash
./mos install
```

Or directly:

```bash
docker run -it --rm --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/data:/data" mos-docker:latest install
```

What happens:

1. Container checks `data/disk.img` doesn't already exist as a real install (refuses to overwrite if it does)
2. Creates a fresh 256 GB sparse `data/disk.img`
3. Boots QEMU with `recovery.img` attached as install media + bundled noVNC on port 6080
4. **Connect with your browser:** http://localhost:6080/vnc.html?autoconnect=1
5. In the recovery installer:
   - Disk Utility → erase the virtio disk as APFS (name doesn't matter)
   - Quit Disk Utility → choose "Reinstall macOS Sequoia" → continue
   - Wait ~30–60 minutes for the install to complete
   - VM auto-reboots into the installed system; finish Setup Assistant
6. **Shut down the VM** from inside macOS (Apple menu → Shut Down)
7. Container exits cleanly

## 7. Run macOS

```bash
./mos run
```

Or:

```bash
docker run -d --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/data:/data" mos-docker:latest
```

Notes:

- This container has no bundled noVNC on the production path by default. Run with `MOS_QEMU_BUNDLED_NOVNC=1` if you want one (the compose.yml in the repo sets it on for convenience). Otherwise expect to point your existing noVNC service at the QEMU VNC unix socket inside the container.
- Container `restart: unless-stopped` — survives host reboot.
- Logs (per boot, timestamped serial dumps): `./data/logs/serial-*.log`
- QEMU monitor + QMP unix sockets in `./data/run/` for live introspection (`socat - unix:./data/run/qemu-monitor.sock`).

## 8. Verify it's working

```bash
./mos logs                  # watch boot
curl -sI http://localhost:6080/vnc.html | head -1   # 200 OK = noVNC alive
ssh user@<vm-ip>            # if you set up SSH inside macOS
```

## Networking

Two modes, controlled by `HOST_IFACE`:

- **`HOST_IFACE` unset (default):** user-mode networking via QEMU's slirp. Works everywhere, no host config needed. NAT'd; macOS gets a private IP, host can reach it via `hostfwd` rules but not the LAN.
- **`HOST_IFACE=enp1s0` (or whatever your physical NIC is):** macvtap bridge mode. macOS gets its own MAC + IP on your LAN, behaves like a separate machine. Requires the named interface to exist + be up.

Set in compose.yml or via `HOST_IFACE=eth0 docker run ...`.

## Tuning

Performance knobs in compose.yml or via `-e`:

| Var | Default | Purpose |
|---|---|---|
| `RAM` | 16 (production), 4 (test) | GB of guest memory. Install needs ≥ 16, steady-state can drop. |
| `SMP` / `CORES` | 16 / 16 | Guest vCPU sockets / cores per socket. |
| `GPU_CORES` | 8 | Lavapipe worker threads for apple-gfx-pci. 4 = low-end, 8 = sweet spot, 16 = headroom. |
| `LAGFX_LOG_LEVEL` | warn | Logging verbosity for libapplegfx-vulkan: warn / info / trace |

## Reinstalling

```bash
docker compose down
rm -f data/disk.img            # the only state that pinpoints "an install"
./mos install                  # fresh install
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: /dev/kvm not present` | KVM not loaded or container not privileged | Ensure host has `kvm_intel`/`kvm_amd` loaded; pass `--privileged` and `--device /dev/kvm` |
| `ERROR: /data is not mounted` | Forgot the bind mount | Add `-v $PWD/data:/data` |
| `ERROR: $DISK does not exist` | Ran `run` before `install` | Run `install` first |
| `ERROR: $DISK is only N bytes` | Aborted install left a corrupt disk | Delete `data/disk.img`, re-run `install` |
| `recovery.img` missing | First-time install needs Apple recovery | See section 3 |
| `OpenCore.img` missing | First-time install needs OpenCore EFI | See section 4 |
| Boot hangs at Apple logo | Usually missing kexts in OpenCore.img or wrong SMBIOS | Check `data/logs/serial-*.log` for kernel panic; fix OpenCore config |
| trustd at 60% CPU after install | macOS first-boot bug | `sudo plutil -replace trustList -array /var/protected/trustd/private/Admin.plist; sudo killall trustd` (one-time) |
| Container restart loop | Look at the log | `docker compose logs macos` |

## Regression testing (developer / contributor)

The repo ships a 5-phase regression chain that bisects which component breaks display rendering:

| Phase | Stack | Expected outcome |
|---|---|---|
| 0 | Vanilla QEMU + OVMF, empty disk | UEFI shell visible (sanity check that VNC works at all) |
| 1 | + OpenCore + macOS image (OEM unpatched QEMU) | OpenCore picker visible |
| 2 | Same as 1 with patched QEMU binary | Same as Phase 1 (proves binary swap is benign) |
| 3 | + Apple SMC + apple-kbd/tablet | macOS boots (if APFS unlocks) or same picker |
| 4 | + apple-gfx-pci (= production) | Black screen until libapplegfx-vulkan opcode handlers ship (M5) |

```bash
./mos build-test            # one-time: build mos-docker:test
./mos test 0                # capture phase 0
./mos test 1                # ...etc through 4
```

Each phase opens noVNC on `http://localhost:608<phase>`. Compare what you see to `baselines/phase-<phase>-gold.png` for pass/fail.

## Architecture (one paragraph)

A single Dockerfile builds the production image. A second Dockerfile (`Dockerfile.test`) extends it with the OEM (unpatched) QEMU binary alongside the patched one and headless screenshot tools. The dispatcher script `/scripts/entrypoint.sh` routes `install` / `run` / `test` to dedicated sub-scripts. Persistent state is bind-mounted at `/data`; the container is otherwise stateless. There is exactly one launch script for production (`run.sh`) — bug fixes happen in one place. The test runner (`test.sh`) configures QEMU args per phase based on a single `phase` arg.
