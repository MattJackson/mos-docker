# Build pipeline — how the mos-docker image gets made

As of 2026-05-10, the QEMU compile and the runtime image are split.
QEMU + libapplegfx-vulkan are pre-built once per push to mos-qemu via
GitHub Actions and published as artifact images on GHCR. The
`mos-docker` runtime image just `COPY --from=`s those binaries into a
slim alpine layer.

End-to-end timing for a typical iteration (script-only edit):

| Step | Time |
|---|---|
| Pull `mos-qemu-patched` from GHCR | ~7s (cached: ~1s) |
| Pull `mos-qemu-oem` from GHCR | ~7s (cached: ~1s) |
| Runtime apk + scripts + OpenCore.img | ~30s |
| Image export | ~14s |
| **Total** | **~50s** |

Pre-split, this was ~5 min (compile QEMU twice + larger export). 6×
faster, deterministic, and survives `docker system prune` because the
heavy artifacts live on GHCR.

## Repository roles

| Repo | Role |
|---|---|
| **github.com/MattJackson/mos-qemu** | Patched QEMU 11.0 source overlay + OEM Dockerfile + GHCR build workflow. Pushes to GHCR on each main push. |
| **github.com/MattJackson/libapplegfx-vulkan** | Host-side Metal→Vulkan library (built into the patched image). |
| **github.com/MattJackson/mos-docker** | Runtime image + scripts + OpenCore EFI source. Pulls from GHCR. |
| **ghcr.io/mattjackson** | Pre-built artifact images: `mos-qemu-patched:<tag>`, `mos-qemu-oem:<version>`. |

## GHCR images

### `ghcr.io/mattjackson/mos-qemu-patched`

`FROM scratch` artifact image — only `/usr/*` (binaries, libs,
keymaps, BIOS blobs). Not runnable on its own; consumed via
`COPY --from=`.

Tags published per push:

| Tag | Pinning |
|---|---|
| `:main` | Always points at latest mos-qemu main. **Default in `mos-docker/Dockerfile`.** |
| `:<commit-sha>` | Pinned to a specific mos-qemu commit. Use for reproducible builds. |
| `:<commit-sha>-lagfx-<sha>` | Pinned to a specific (mos-qemu, libapplegfx-vulkan) pair. Strictest reproducibility. |

### `ghcr.io/mattjackson/mos-qemu-oem`

Vanilla upstream QEMU 11.0.0, also `FROM scratch`. Used as the
phase 1 OEM-bisect binary. Only one tag — the QEMU release version:

| Tag | Pinning |
|---|---|
| `:11.0.0` | Vanilla upstream QEMU release. Bumped only when QEMU upstream releases a new version we care about. |

## When does each image rebuild?

**`mos-qemu-patched` rebuilds on pushes that touch:**

- `hw/**` (overlay C source)
- `pc-bios/**` (overlay ROM blobs)
- `Dockerfile.patched`
- `.github/workflows/build-image.yml`

If only fork-internal docs (e.g. `upstream-pr/**`) change, no rebuild.

**`mos-qemu-oem` rebuilds on pushes that touch:**

- `Dockerfile.oem`
- `.github/workflows/build-image.yml` (most likely a `QEMU_VERSION` env bump)
- Manual `workflow_dispatch` with `build_oem=true`

OEM rarely needs to rebuild — that's the design. A push that only
touches `hw/**` (patched-only territory) leaves OEM alone.

**`mos-docker:latest` rebuilds whenever you run `./mos build`.**
Layer cache makes script-only iterations fast (~30s); QEMU artifact
layers come from GHCR pull.

## The build flow

### Day-to-day: edit + build + run

```bash
# 1. Edit scripts/test.sh, scripts/run.sh, efi/EFI/OC/config.plist, etc
# 2. Commit + push from laptop (CLAUDE.md rule #13)
git -C ~/Developer/mos-docker add ... && git -C ~/Developer/mos-docker commit -m "..." && git -C ~/Developer/mos-docker push

# 3. Pull on classe + rebuild + relaunch
ssh docker 'git -C /home/matthew/mos-docker pull --ff-only && cd /home/matthew/mos-docker && sudo ./mos build && sudo ./mos test 9'
```

`./mos build` does:

1. Resolves `MOSQEMU_IMAGE` (default `:main`) and `OEM_QEMU_IMAGE`
   (default `:11.0.0`)
2. `docker pull` both — fails fast if GHCR is down or tag missing
3. `docker compose build` — assembles runtime image from those bases
   plus runtime apk + scripts + OpenCore.img

### Editing patched QEMU C source

```bash
# 1. Edit ~/Developer/qemu-mos15/hw/display/apple-gfx-pci-linux.c (etc)
# 2. Commit + push to qemu-mos15
git -C ~/Developer/qemu-mos15 add ... && git -C ~/Developer/qemu-mos15 commit -m "..." && git -C ~/Developer/qemu-mos15 push

# 3. GitHub Actions automatically builds + pushes new mos-qemu-patched:<sha>
#    Watch progress (run id from `gh run list --workflow=build-image.yml --limit 1 -R MattJackson/mos-qemu`):
gh run watch <id> --repo MattJackson/mos-qemu --exit-status

# 4. Once green (~1-2 min warm Layer C; ~11-13 min cold), rebuild on classe — picks up new :main tag
ssh docker 'cd /home/matthew/mos-docker && ./mos build && ./mos test 4'
```

Layer C is an incremental re-link, not a full QEMU recompile —
stage1 has the vanilla QEMU build + build system + a lagfx stub
cached, so a `hw/**` change only re-runs `meson compile` against
the delta. **Best observed warm: 1m19s (`8df84fb`).** The
pre-2026-05-11 monolithic 17-min QEMU rebuild is gone.

`./mos build` is ~50s. `./mos test 4` launches the container — `./mos
build` alone does NOT restart anything, you must follow with `./mos
test N`.

### Editing libapplegfx-vulkan only (M5 lane's most common iteration)

**Gotcha:** `libapplegfx-vulkan`'s own CI is tests-only. It does NOT
push to GHCR. A push to libapplegfx-vulkan does NOT auto-trigger
`mos-qemu-patched:main` to rebuild. If you only `./mos build` after
a lagfx push, classe pulls the *old* `:main` and runs against
yesterday's lagfx.

The correct flow:

```bash
# 1. Push lagfx
git -C ~/Developer/libapplegfx-vulkan add <files> \
  && git -C ~/Developer/libapplegfx-vulkan commit -m "..." \
  && git -C ~/Developer/libapplegfx-vulkan push

# 2. (Recommended) wait for lagfx CI green — proves it compiles+tests pass
gh run watch --repo MattJackson/libapplegfx-vulkan --exit-status

# 3. Manually trigger the GHCR rebuild — resolves libapplegfx-vulkan:main to current HEAD
gh workflow run build-image.yml -R MattJackson/mos-qemu

# 4. Watch (~1-2 min warm Layer C)
gh run list --workflow=build-image.yml --limit 1 -R MattJackson/mos-qemu
gh run watch <id> -R MattJackson/mos-qemu --exit-status

# 5. Deploy on classe
ssh docker 'cd /home/matthew/mos-docker && ./mos build && ./mos test 4'
```

**Do NOT use empty commits on qemu-mos15** as a "trigger". The
workflow's `paths:` filter sees zero changed files and skips
silently. `gh workflow run` is the canonical refresh-trigger when
only lagfx changed.

If you edited BOTH lagfx and qemu-mos15: push lagfx first (so its
`:main` is current), then push qemu-mos15 — the patched workflow
auto-fires on `hw/**` and resolves `libapplegfx-vulkan:main` HEAD
automatically. No separate dispatch needed.

### Bumping QEMU version

```bash
# 1. Edit BOTH the workflow env and any version-specific Dockerfile bits.
#    (As of 2026-05-10, QEMU_VERSION lives in build-image.yml's env block.)
$EDITOR ~/Developer/qemu-mos15/.github/workflows/build-image.yml  # bump env: QEMU_VERSION
$EDITOR ~/Developer/qemu-mos15/Dockerfile.oem                     # bump ARG QEMU_VERSION
$EDITOR ~/Developer/qemu-mos15/Dockerfile.patched                 # bump ARG QEMU_VERSION
# 2. Push. Both jobs (patched + OEM) rebuild because build-image.yml changed.
# 3. Update mos-docker/mos build wrapper if OEM_QEMU_IMAGE default needs to change tag.
```

### Pinning a specific QEMU SHA on classe (e.g. for bisecting)

```bash
ssh docker 'cd /home/matthew/mos-docker && \
  MOSQEMU_IMAGE=ghcr.io/mattjackson/mos-qemu-patched:<sha> sudo -E ./mos build'
```

## Authentication

GHCR images are **public** — anonymous `docker pull` works without
`docker login`. No PAT or token needed on classe.

The CI workflow pushes via the auto-provided `GITHUB_TOKEN` (with
`packages: write` permission set in the workflow YAML). No long-lived
PAT to manage.

## Disaster recovery

### "I broke the GHCR image"

Tags are immutable — once `:main` advances, the old SHA-tagged image
is still there. Roll back:

```bash
MOSQEMU_IMAGE=ghcr.io/mattjackson/mos-qemu-patched:<good-sha> ./mos build
```

### "GHCR is down / I'm offline"

The previously-pulled image stays in your local docker daemon. As long
as `docker images | grep mos-qemu-patched` shows a copy, builds work
without GHCR.

### "QEMU C source edit must be tested NOW, can't wait for CI"

Two options:

1. **Build the image locally** with the same Dockerfile.patched the CI
   workflow uses:
   ```bash
   docker build \
     -f ~/Developer/qemu-mos15/Dockerfile.patched \
     --build-arg QEMU_VERSION=11.0.0 \
     --build-arg LIBAPPLEGFX_SHA=$(git -C ~/Developer/libapplegfx-vulkan rev-parse main) \
     -t ghcr.io/mattjackson/mos-qemu-patched:dev \
     ~/Developer/qemu-mos15/
   ```
   Then `MOSQEMU_IMAGE=ghcr.io/mattjackson/mos-qemu-patched:dev ./mos build`.

2. **Trigger CI manually** from a feature branch:
   ```bash
   git -C ~/Developer/qemu-mos15 push origin HEAD:test-build
   gh workflow run build-image.yml --ref test-build --repo MattJackson/mos-qemu
   ```

## What this replaced (do not resurrect)

The pre-2026-05-10 flow had a single mos-docker Dockerfile with three
builder stages compiling everything inline:

- `FROM alpine:3.21 AS builder` — built libapplegfx + patched QEMU
- `FROM alpine:3.21 AS oem-builder` — built vanilla QEMU
- `FROM alpine:3.21 AS opencore-builder` — built OpenCore.img (kept)
- `FROM alpine:3.21` — final runtime, COPY-ing from the above

Symptoms of that flow:

- Every `./mos build` recompiled QEMU from source if cache missed
  (every Dockerfile edit, every `docker system prune`, every host reboot)
- 4-5 min total per iteration; build cache grew to 12+ GB
- Dual builds with no cross-machine sharing (every dev / CI run paid
  the full cost)

If you find yourself in a Dockerfile with `meson setup`, `make -j`, or
`ADD https://download.qemu.org/...` you're in the wrong file. The
right place for QEMU compile changes is
`qemu-mos15/Dockerfile.patched` (or `Dockerfile.oem`), and the change
gets published to GHCR by the CI workflow there — not by anything in
`mos-docker`.
