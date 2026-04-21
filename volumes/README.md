# ./volumes/ — per-deployment runtime artifacts

Everything in this directory is operator-supplied, gitignored, and bind-mounted
into the container at runtime. Nothing here is baked into the image. A fresh
clone of the repo must stage these files before `docker compose up -d` will
work; `../setup.sh` does this end-to-end.

## Files

| File | Size | Container path | Source | Purpose |
|---|---|---|---|---|
| `disk.img` | up to ~256 GB | `/image` | `setup.sh` creates empty | macOS install/runtime disk. Empty/tiny file triggers install mode. |
| `recovery.img` | ~3.2 GB | `/opt/macos/recovery.img` | Apple recovery (see below) | Install-mode boot source. |
| `opencore.img` | ~512 MB | `/opt/macos/OpenCore.img` | `../build-mos15-img.sh` | Bootable EFI image containing OpenCore + our kexts. |

## How to produce each file

### `disk.img`

Created empty on first setup; `launch.sh` sizes it up to `DISK_SIZE` (compose
default `256G`) via `qemu-img` when it sees a <1 MiB file.

```sh
./setup.sh            # among other things: touch volumes/disk.img
```

You can also bind-mount a pre-existing `.img` here (e.g. a previously installed
VM's disk from another host) — as long as the file is larger than 1 MiB
`launch.sh` treats it as "boot mode".

### `recovery.img`

Apple doesn't distribute these directly. The reliable path:

1. On any macOS host, fetch the recovery DMG via
   [`macrecovery.py`](https://github.com/acidanthera/OpenCorePkg/blob/master/Utilities/macrecovery/macrecovery.py)
   from the OpenCorePkg Utilities:

   ```sh
   cd /path/to/OpenCorePkg/Utilities/macrecovery
   python3 macrecovery.py -b Mac-AA95B1DDAB278B95 -m 00000000000000000 download
   ```

   Adjust the board id (`-b`) for the macOS version you want. `Mac-AA95B1DDAB278B95`
   corresponds to iMac20,1 which is the SMBIOS we advertise.

2. Convert the downloaded `BaseSystem.dmg` to raw:

   ```sh
   dmg2img BaseSystem.dmg volumes/recovery.img
   ```

   On Linux install `dmg2img` from your distro. On macOS:
   `brew install dmg2img`.

3. Drop the result at `volumes/recovery.img`. Expected size: ~3.2 GB.

`setup.sh` automates steps 1-3 if `RECOVERY_URL` is set to a pre-staged
location (internal artifact store, S3 bucket, etc) — see `../setup.sh`.

### `opencore.img`

Build on a macOS host (needs `hdiutil`, `newfs_msdos`, Apple's mount tools):

```sh
# On a macOS dev host, in this repo:
./build-mos15-img.sh              # produces builds/mos15_<ts>.img
cp builds/mos15_<ts>.img volumes/opencore.img
```

The build script wants:
- `kexts/deps/mos15-patcher.kext` (built from the `mos-patcher` repo)
- `kexts/QEMUDisplayPatcher/build/QEMUDisplayPatcher.kext` (built in-repo)
- `$SYSTEM_KC` (macOS 15.7.5 System KC, 349 MB; default
  `~/mos-staging/SystemKernelExtensions.kc`)

See `../SETUP.md` for the full first-time walk-through.

## Why these aren't in the image

Bake-into-image vs bind-mount-at-runtime decision:

| Property | disk.img | recovery.img | opencore.img |
|---|---|---|---|
| Size | up to 256 GB | 3.2 GB | 512 MB |
| Changes per-deploy | yes (accumulates VM state) | no (Apple artifact) | yes (new kext build) |
| Operator can regenerate | no (lossy) | yes (macrecovery) | yes (build-mos15-img.sh) |
| Needs to be in image? | no | no | no |

Keeping them out of the image means:
- `docker build` is fast and cacheable (no 4 GB COPY per iteration)
- Swapping an opencore build doesn't require a rebuild + push
- The image is ~50 MB instead of ~4 GB
- A CI pipeline publishing the image doesn't have to carry Apple artifacts

## gitignore

`volumes/*.img` is gitignored in `../.gitignore`. Don't check any of these in.
This `README.md` is tracked.
