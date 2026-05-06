# mos-docker

macOS VM in Docker on Linux + KVM. Production runtime for the
[mos](https://github.com/MattJackson/mos) paravirt-GPU project.

## Read this first

- `README.md` — 2-command quickstart for end users
- `SETUP.md` — full first-time setup guide (recovery image acquisition,
  OpenCore.img build, install workflow)
- `memory/MEMORY.md` — index of evergreen project facts and standing rules
- `docs/incidents/` — public post-mortems (read these before changing
  anything destructive)

## Architecture

ONE production image, ONE test image, ONE entrypoint with three modes.

```
Dockerfile          builds mos-docker:latest (production)
Dockerfile.test     extends prod with OEM QEMU + chromium for regression tests
compose.yml         docker compose up   (= production "run" mode)
compose.test.yml    docker compose -f ... run --rm test 0..4

scripts/
  entrypoint.sh     dispatcher (run | install | test) — first-arg branching
  install.sh        creates fresh disk + boots with recovery media
  run.sh            production launcher, NEVER touches disk.img
  test.sh           phase 0..4 regression runner (test image only)

mos                 thin CLI wrapper — ./mos install | run | test N | logs
```

End-user flow (no clone needed, image pulled from registry):
```sh
docker run -it --rm --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/mos-data:/data" ghcr.io/mattjackson/mos-docker install
docker run -d --privileged --device /dev/kvm -p 6080:6080 \
  -v "$PWD/mos-data:/data" ghcr.io/mattjackson/mos-docker
```

## Safety guarantees (encoded in code, NOT just convention)

- `run.sh` (production) **never** calls `qemu-img create` on the data
  disk. The destructive code path doesn't exist in production. Period.
- `install.sh` refuses to overwrite an existing `disk.img >1 MiB`.
  Operator must `rm` it manually first — that's the consent gesture.
- `entrypoint.sh` validates `/dev/kvm` access + `/data` writability up
  front; fails loud rather than racing into bad bind-mount state.

These rules are direct lessons from `docs/incidents/2026-05-06-disk-wipe.md`.
Don't undo them.

## 100% dev on laptop — classe is pull-only

Every edit happens in this laptop checkout → commit → push → ssh classe
→ `git pull` → `./mos build` → `./mos run`.

NEVER `ssh docker '... mv ...'`, `vim`, `cat > file`, `sed -i`, or
`git commit` on classe. Inspection, deploy invocation, log capture are
fine. If a laptop clone goes missing, **re-clone before doing
anything**.

## Workflow rules

- **Persistent state lives only in `/data/`.** Anything outside is
  ephemeral and disposable. The only files that matter for
  reproducibility are `data/disk.img`, `data/OpenCore.img`,
  `data/recovery.img`.
- **Stop the VM before mutating `data/disk.img` or `data/OpenCore.img`.**
  QEMU holds these files open. Modifying them while running corrupts
  checksums.
- **No `Co-Authored-By: Claude`** (or any AI attribution) in commits.
- **Public-consumption docs.** README + SETUP are written for someone
  who's never seen this codebase. Don't add internal jargon to them.

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
  sudo ./mos build         # rebuild production image
  sudo ./mos stop          # stop running container
  sudo ./mos run           # start fresh
'
```

(`sudo` because the host user is not in the `docker` group on classe.
Local-dev hosts where you ARE in the docker group can drop the `sudo`.)

## Where this fits

- **Host:** classe (Dell R730 in basement). Sole datacenter.
- **Laptop checkout:** `/Users/mjackson/Developer/mos-docker/` (this repo).
- **Classe checkout:** `/home/matthew/mos-docker/`.
- **Persistent state on classe:** `/home/matthew/mos-docker/data/`,
  containing the disk image (currently a symlink farm to `/data/macos/`).
- **Memory:** `memory/` in this repo, in git. Cross-references at
  `~/Developer/mos/memory/MEMORY.md`.

## Regression testing (developer / contributor)

The repo ships a 5-phase chain that bisects which component breaks
display rendering on a working install:

| Phase | Stack | Expected outcome |
|---|---|---|
| 0 | Vanilla QEMU + OVMF, empty disk | UEFI shell visible (sanity check) |
| 1 | + OpenCore + macOS image (OEM unpatched QEMU) | OpenCore picker visible |
| 2 | Same as 1 with patched QEMU binary | Same as Phase 1 (proves binary swap is benign) |
| 3 | + Apple SMC + apple-kbd/tablet | macOS boots to login (if APFS unlocks) or same picker |
| 4 | + apple-gfx-pci (= production) | Black screen until libapplegfx-vulkan opcode handlers ship (M5 stage 20%) |

```sh
./mos build-test            # build mos-docker:test
./mos test 0                # capture phase 0
./mos test 1                # ...etc through 4
```

Each phase opens noVNC on `http://localhost:608<phase>`. Compare what
you see to `baselines/phase-<phase>-gold.png` for pass/fail.
