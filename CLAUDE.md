# docker-macos

macOS VM running in Docker on a classed Linux host. QEMU/KVM with
OpenCore. Used to build and test the macOS IOKit transport layer of
the freemkv ecosystem and to keep a clean macOS environment outside
the daily-driver Mac.

## Read this first

`memory/MEMORY.md` is the index of evergreen project facts and
standing rules. Treat dated logs in `memory/history/` as historical
only. Conventions in `memory/README.md`.

## Layout

- `Dockerfile`, `docker-compose.yml` — build + run definition
- `efi/` — OpenCore EFI partition (ProperTree-edited config.plist)
- `kexts/` — Lilu, VirtualSMC, QEMUDisplay, QEMUDisplayPatcher
- `volumes/` — VM disk image + persistent state
- `build-mos15-img.sh`, `setup.sh`, `launch.sh`, `deploy.sh` — scripts
- `docs/`, `DISCOVERY.md` — running notebook of what works/doesn't
- `tests/`, `TESTING.md` — verification matrix
- `release-docker-macos.md` — release notes / changelog

## Current state

See `memory/project_docker_macos.md`. Lilu plugin approach
(QEMUDisplayPatcher) routes IONDRVFramebuffer methods. EDID + gamma
work when hooks fire. Two open blockers:

1. **Consistency (~60% of boots)** — needs Lilu source patched + built
   with Xcode (manual clang build crashes).
2. **Trampoline crash on `orgEnableController`** — workaround returns
   0, skipping OEM NDRV init; display works via VGA fallback.

## Workflow rules

See `memory/feedback_docker_macos.md`. The big ones:

- **One change at a time.** Change → test → prove → document → next.
- **Stop the VM before scp'ing OpenCore/kexts.** QEMU holds files
  open; scp while running corrupts checksums.
- **No `/tmp` for compiled kexts.** Lost a VMsvga2 build that way.
- **Document every finding in `DISCOVERY.md`** before the next change.
- **No broad `sed`.** See `memory/feedback_no_broad_sed.md`.

## Deploy cycle

```bash
ssh docker 'docker stop mos-docker-macos-1'      # VM holds files open
# rebuild kexts / edit config.plist locally
scp -r efi/ docker:/path/to/volumes/efi/         # verify md5 after copy
ssh docker 'docker start mos-docker-macos-1'
ssh docker 'docker logs mos-docker-macos-1 -f'   # watch boot
```

## Where this fits

- **Host:** classe (Dell R730), runs alongside the rest of the docker
  stack. NOT in `pq/docker-server` — this repo is the analogous
  out-of-stack project (cf. docker-server's "Outside the standard
  layout" section).
- **Code on Mac:** `/Users/mjackson/Developer/docker-macos/` (this repo).
- **Memory:** `memory/` in this repo. Conventions: see
  `/Users/mjackson/Developer/mos/memory/README.md`.

## Conventions

- Memory in `memory/`, in this repo, in git. Never under
  `~/.claude/projects/`.
- Use `git -C <path>` for cross-repo git ops; never
  `cd <path> && git ...`.
- No `Co-Authored-By: Claude` (or any AI attribution) in commits.
