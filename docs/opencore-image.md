# OpenCore image

How to build / acquire `OpenCore.img` (~512 MB FAT32 EFI image).
Required by every mode that boots macOS. Persistent — stays in
`data/OpenCore.img` for the lifetime of the install.

## What it is

A bootable EFI volume that QEMU's OVMF firmware loads first. OpenCore
runs from this image, then chains to macOS:

```
OVMF (UEFI firmware)
    └── OpenCore.img → OpenCore.efi
           ├── load APFS driver
           ├── load Lilu + plugins (kext loader)
           ├── load kexts (VirtualSMC, AppleALC, ...)
           ├── load mos-patcher (per-instance vtable swap)
           └── chain → /System/Library/CoreServices/boot.efi (in macOS APFS volume)
```

Without OpenCore, OVMF doesn't know how to mount APFS or how to
identify itself as Apple hardware. macOS won't boot.

## Two paths

### Path A — Use a community-built image (easiest)

If you're using mos-docker as part of the broader `mos` ecosystem, the
OpenCore image is built by the
[mos-opencore](https://github.com/MattJackson/mos-opencore) build
script on a macOS host. See its README for the recipe.

Drop the resulting image at `~/mos-docker/data/OpenCore.img`.

### Path B — Build your own

Outside mos-docker's scope, but the high-level recipe:

1. **Download OpenCore release** (ships as binary):
   <https://github.com/acidanthera/OpenCorePkg/releases>
   We pin to **1.0.7** — newer is fine but untested.

2. **Lay out the EFI tree:**
   ```
   EFI/
   ├── BOOT/
   │   └── BOOTx64.efi              # OpenCore's loader, copied as-is
   └── OC/
       ├── OpenCore.efi              # main loader
       ├── config.plist              # the tunable config (most important file)
       ├── ACPI/                     # ACPI overlays (SSDT-PLUG-* etc.)
       ├── Drivers/                  # EFI drivers loaded at boot
       │   ├── OpenRuntime.efi       # required (OpenCore's runtime patches)
       │   ├── ResetNvramEntry.efi   # optional
       │   ├── OpenCanopy.efi        # graphical picker UI
       │   ├── ApfsDriverLoader.efi  # CRITICAL: APFS support
       │   └── ...
       ├── Kexts/                    # macOS kernel extensions
       │   ├── Lilu.kext             # plugin loader (required)
       │   ├── VirtualSMC.kext       # SMC simulation (required for Hackintosh)
       │   ├── AppleALC.kext         # audio
       │   ├── WhateverGreen.kext    # GPU patches
       │   └── ...
       ├── Resources/                # OpenCanopy theme, fonts
       └── Tools/                    # OpenShell.efi, etc.
   ```

3. **config.plist** — the bulk of the work. Configure:
   - **PlatformInfo → Generic** → SystemProductName=`iMac20,1`,
     SystemSerialNumber=(generated), MLB=(generated), ROM=(generated)
   - **Kernel → Add** → list of kexts in load order
   - **NVRAM → boot-args** → e.g. `-v keepsyms=1 debug=0x100`
   - **UEFI → Drivers** → list of EFI drivers
   - Use [acidanthera/Sample.plist](https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Sample.plist)
     as a starting point + the [Configuration manual](https://dortania.github.io/OpenCore-Install-Guide/)

4. **Pack into a 512 MB FAT32 image:**
   ```bash
   dd if=/dev/zero of=OpenCore.img bs=1M count=512
   mkfs.vfat -n "OPENCORE" OpenCore.img
   sudo mount -o loop OpenCore.img /mnt/oc
   sudo cp -r EFI /mnt/oc/
   sudo umount /mnt/oc
   ```

5. **Drop at `~/mos-docker/data/OpenCore.img`**.

## What's in our community-built OpenCore.img

If you got the prebuilt image from `mos-opencore`, it contains:

- OpenCore 1.0.7 (vanilla acidanthera, not a fork)
- ApfsDriverLoader.efi (loads Apple's signed apfs.efi at boot — needed
  for APFS support in OpenCore's pre-boot env)
- OpenCanopy.efi (graphical picker)
- Lilu.kext + VirtualSMC.kext (standard Hackintosh stack)
- mos-patcher.kext (our Lilu-style plugin that does per-instance
  vtable swaps for IOFramebuffer methods — replaces the retired
  QEMUDisplayPatcher)
- config.plist tuned for iMac20,1 SMBIOS

## Validating the image

```bash
file ~/mos-docker/data/OpenCore.img
# Expected: DOS/MBR boot sector ... FAT (32 bit) ... label: "OPENCORE"

ls -lh ~/mos-docker/data/OpenCore.img    # ~512 MB

# Mount + inspect
sudo mount -o loop ~/mos-docker/data/OpenCore.img /mnt/oc
ls /mnt/oc/EFI/OC/                       # should show config.plist, OpenCore.efi, etc.
ls /mnt/oc/EFI/OC/Drivers/               # MUST include ApfsDriverLoader.efi
ls /mnt/oc/EFI/OC/Kexts/                 # SHOULD include Lilu.kext + VirtualSMC.kext
sudo umount /mnt/oc
```

If `ApfsDriverLoader.efi` is missing, OpenCore can't see APFS volumes —
the macOS install won't boot, and recovery's "boot from internal disk"
won't see anything either.

## When to rebuild

OpenCore.img is rebuilt when:

- You add or update kexts (rebuild required)
- config.plist changes (in-place edit OK if you can mount + remount;
  rebuild cleaner)
- OpenCore version bump (rebuild)
- macOS minor version requires new APFS driver bytes (rebuild)

In practice, rebuild on every kext change during development; for a
working install, you might go months without rebuilding.

## Why we don't ship this in the docker image

Same reasons as `recovery.img`: it changes per macOS version, per kext
set, and bloats `docker pull`. Bind-mount decouples version cadence.

Also: OpenCore.img content depends on which kexts you want. Different
users want different stacks (audio support yes/no, GPU type, etc.).
Bundling forces one config on everyone.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `OCJS: PartitionInfo is Not Found` | OpenCore's APFS driver missing | Add `ApfsDriverLoader.efi` to `EFI/OC/Drivers/`, rebuild |
| OpenCore picker shows only "UEFI Shell" | macOS volume not detected (APFS unlock fail) | See APFS driver above + verify Apple identity (SMC) is provided by QEMU |
| Boot hangs at OpenCore logo | config.plist syntax error | Mount image, validate plist with `plutil -lint /mnt/oc/EFI/OC/config.plist` |
| Boot hangs at Apple logo | Wrong SMBIOS or missing kext | Check serial log (`data/logs/serial-*.log`) for kernel panic |
| Picker shows but immediately reboots | OpenCore Misc → BootProtect = `Bootstrap` enabled but EFI volume NVRAM borked | Reset NVRAM via `data/.reset-nvram` marker file |

## Reference

- OpenCore manual: <https://dortania.github.io/OpenCore-Install-Guide/>
- Sample config: <https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Sample.plist>
- mos-opencore (our build): <https://github.com/MattJackson/mos-opencore>
