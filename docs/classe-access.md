# Classe Access & Build Deploy Guide

## SSH Connection

**Host:** `matthew@10.1.7.11` (Dell R730 in basement)  
**Auth:** Key-based via `~/.ssh/id_ed25519` (pre-configured with agent forwarding)

```bash
# Direct SSH to classe
ssh matthew@10.1.7.11

# Or as docker user (if in docker group on host)
ssh -o StrictHostKeyChecking=no docker@classe
```

## Build & Deploy Workflow

### From your laptop:

```bash
# 1. Push changes to GitHub
git -C ~/Developer/qemu-mos15 add -A && git -C ~/Developer/qemu-mos15 commit -m "<msg>"
git -C ~/Developer/qemu-mos15 push origin main

git -C ~/Developer/libapplegfx-vulkan add -A && git -C ~/Developer/libapplegfx-vulkan commit -m "<msg>"
git -C ~/Developer/libapplegfx-vulkan push origin main

# 2. Wait for CI to build (optional but recommended)
gh run list --repo MattJackson/mos-qemu --workflow=build-image.yml | head -3
gh run watch <run-id> --repo MattJackson/mos-qemu --exit-status

# 3. SSH to classe and deploy
ssh matthew@10.1.7.11 'cd /home/matthew/mos-docker && git pull && sudo ./mos build'
```

### From inside classe:

```bash
cd /home/matthew/mos-docker
git pull
sudo ./mos build          # Rebuild production image (uses cached GHCR layers)
sudo ./mos stop           # Stop running container if any
sudo ./mos run            # Start fresh with new image
```

## Uncached Rebuilds (rare, when Docker layers are stale)

When `gh workflow run` shows `CACHED` for all steps:

```bash
# 1. Trigger uncached build on GitHub
gh workflow run build-image.yml -R MattJackson/mos-qemu --field 'force_no_cache=true'

# 2. Wait for completion (~3-5 min full rebuild)
gh run watch <run-id> --repo MattJackson/mos-qemu --exit-status

# 3. Deploy on classe (normal flow, no special handling needed)
ssh matthew@10.1.7.11 'cd /home/matthew/mos-docker && git pull && sudo ./mos build'
```

## Testing Phases

After deploying new image:

```bash
# Phase 4 (production with apple-gfx-pci, libapplegfx-vulkan)
ssh matthew@10.1.7.11 'sudo ./mos test 4'

# Check logs
ssh matthew@10.1.7.11 'docker logs mos-test-phase4-* 2>&1 | grep -v display_tick_vblank | tail -60'

# Serial log for lagfx traces
ssh matthew@10.1.7.11 'tail -100 /mnt/docker/mos-data/logs/serial-phase4-*.log'
```

## noVNC Access

After starting a test:
- Phase 3: http://10.1.7.11:6083
- Phase 4: http://10.1.7.11:6084

Or via the reverse proxy: http://docker.internal.pq.io:608<phase>

## Key Commands Summary

```bash
# Laptop → GitHub
cd ~/Developer/qemu-mos15 && git add -A && git commit -m "<msg>" && git push origin main
cd ~/Developer/libapplegfx-vulkan && git add -A && git commit -m "<msg>" && git push origin main

# Trigger CI (if needed)
gh workflow run build-image.yml -R MattJackson/mos-qemu

# Deploy to classe
ssh matthew@10.1.7.11 'cd /home/matthew/mos-docker && git pull && sudo ./mos build'

# Test Phase 4
ssh matthew@10.1.7.11 'sudo ./mos test 4'

# Verify lagfx_timer_tick_vblank fires (look for vblank_tick in logs)
ssh matthew@10.1.7.11 'tail -f /mnt/docker/mos-data/logs/serial-phase4-*.log | grep vblank_tick'
```

## Notes

- classe is **pull-only** — never `cd && git commit` on classe
- Production image uses cached GHCR layers (~30-60s warm path)
- Uncached rebuilds take ~3-5 min but are only needed when Docker cache is stale
- All edits happen in local laptop checkout → commit → push → deploy
