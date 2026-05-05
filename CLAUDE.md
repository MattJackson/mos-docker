# mos-docker

macOS VM in Docker on classe (Dell R730) for the mos paravirt-GPU project.
QEMU/KVM + OpenCore + libapplegfx-vulkan.

## Read this first

`memory/MEMORY.md` is the index of evergreen project facts and standing
rules. Dated logs in `memory/history/` are historical only.

## Layout — phased regression chain

Each phase image inherits from the previous. Phase 4 IS production.

| File | Adds vs previous |
|---|---|
| `Dockerfile.base` | alpine + OEM (unpatched) QEMU 10.2.2 + websockify/novnc + OVMF |
| `Dockerfile.phase0` | `launch_phase0.sh` (vanilla VNC test — empty disk + UEFI shell) |
| `Dockerfile.phase1` | `launch_phase1.sh` (mac_hdd_ng.img + OpenCore EFI on disk; OEM QEMU still) |
| `Dockerfile.phase2` | mos15-patched QEMU binary (applesmc/dev-hid/vmware_vga/apple-gfx-pci-linux) + `launch_phase2.sh` |
| `Dockerfile.phase3` | `launch_phase3.sh` adds `-device isa-applesmc` + apple-kbd/apple-tablet (Apple identity) |
| `Dockerfile.phase4` | libapplegfx-vulkan.so + production `launch.sh` (vga none + apple-gfx-pci as console 0). **Phase 4 = production.** |
| `Dockerfile.screenshot` | Removable test-only sidecar (chromium + xvfb) for visual regression capture |

## Build + run

```sh
# First time after clone, or after any phase Dockerfile change:
scripts/build-phases.sh           # builds base → phase0 → ... → phase4

# Production (= Phase 4):
docker compose up -d              # uses docker-compose.yml on port 6080

# Phased regression (each in its own port + container — no conflict with prod):
docker compose -f compose.phase0.yml up -d   # vanilla VNC test, port 6080
docker compose -f compose.phase1.yml up -d   # OpenCore picker,    port 6081
docker compose -f compose.phase2.yml up -d   # patched QEMU,       port 6082
docker compose -f compose.phase3.yml up -d   # +Apple identity,    port 6083
docker compose -f compose.phase4.yml up -d   # +apple-gfx-pci,     port 6084

# Phased regression with screenshot capture overlay:
PHASE=N docker compose -f compose.phaseN.yml -f compose.screenshot.yml up -d

# Capture + diff (laptop side):
scripts/capture-screenshot.sh N    # scp current PNG from classe to ./baselines/
scripts/compare-regression.sh N    # ImageMagick perceptual diff vs gold
```

## 100% dev on laptop — classe is pull-only

Every edit happens in this laptop checkout → commit → push → ssh classe
→ `git pull` → `scripts/build-phases.sh` (or `docker compose build`).

NEVER `ssh docker '... mv ...'`, `vim`, `cat > file`, `sed -i`, or
`git commit` on classe. Inspection, deploy invocation, log capture are
fine. If a laptop clone goes missing, **re-clone before doing
anything**.

This rule cost us ~30 dirty files of nearly-lost agent work on
2026-05-05.

## Workflow rules

- **One variable at a time.** Each phase adds exactly one. If you can't
  describe the delta in one sentence, the phase is too big — split it.
- **Stop the VM before mutating bind-mounted artifacts.** QEMU holds
  `volumes/disk.img`, `volumes/opencore.img`, etc. open. scp/cp into
  them while running corrupts checksums.
- **Don't bake test infrastructure into production.**
  `compose.screenshot.yml` is REMOVABLE — production `docker-compose.yml`
  doesn't include it. If a screenshot dep ends up in `Dockerfile.phaseN`,
  back it out into `Dockerfile.screenshot`.
- **Bootstrap golds with eyes-on inspection** before committing them.
  A wrong gold encodes a bug as "expected".
- **No `Co-Authored-By: Claude`** (or any AI attribution) in commits.

## Deploy cycle (laptop → classe)

```sh
# laptop:
git -C ~/Developer/mos-docker add -A
git -C ~/Developer/mos-docker commit -m "<msg>"
git -C ~/Developer/mos-docker push

# classe:
ssh docker '
  cd /home/matthew/mos-docker
  git pull
  bash scripts/build-phases.sh    # rebuild affected phases
  docker compose down
  docker compose up -d
'
```

## Where this fits

- **Host:** classe (Dell R730 in basement). Sole datacenter.
- **Laptop checkout:** `/Users/mjackson/Developer/mos-docker/` (this repo).
- **Classe checkout:** `/home/matthew/mos-docker/`.
- **Macos disk image:** `/data/macos/mac_hdd_ng.img` on classe (256 GB raw),
  symlinked into `volumes/disk.img` by `setup.sh`.
- **Memory:** `memory/` in this repo, in git. Conventions:
  `~/Developer/mos/memory/README.md`.
