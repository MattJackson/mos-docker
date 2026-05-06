# Recovery image

How to acquire `recovery.img` (~3.2 GB Apple recovery image). Required
for `install` mode only. Once macOS is installed you can delete it.

## What it is

An Apple-supplied "recovery" image containing the macOS installer plus
Disk Utility plus a minimal macOS environment. QEMU attaches it to the
VM as removable media; the user boots from it once to install macOS
into `disk.img`, then never again.

Apple does not redistribute this directly. The community-standard path
is to fetch via OpenCore's `macrecovery.py` utility, then convert from
DMG to raw.

## The recipe

On any Linux or macOS host with Python 3:

```bash
# Get OpenCore's utilities (only macrecovery.py is needed)
git clone --depth=1 https://github.com/acidanthera/OpenCorePkg
cd OpenCorePkg/Utilities/macrecovery

# Download the Sequoia recovery DMG. The board id (-b) selects which
# macOS variant. Mac-AA95B1DDAB278B95 = iMac20,1 — the SMBIOS that
# mos-docker advertises to macOS, so this is the right board id for us.
python3 macrecovery.py \
    -b Mac-AA95B1DDAB278B95 \
    -m 00000000000000000 \
    download

# Produces:
#   BaseSystem.dmg       ~3.2 GB — what we need
#   BaseSystem.chunklist
#   RecoveryHDMeta.dmg

# Convert DMG → raw. Apple's DMG format is unreadable to QEMU directly.
# Linux:   apt install dmg2img    (or your distro equivalent)
# macOS:   brew install dmg2img
dmg2img BaseSystem.dmg recovery.img

# Drop into the data dir mos-docker bind-mounts:
mv recovery.img ~/mos-docker/data/recovery.img
```

That's it. Verify:

```bash
ls -lh ~/mos-docker/data/recovery.img    # should be ~3.2 GB
file ~/mos-docker/data/recovery.img      # should say "DOS/MBR boot sector" or similar
```

## Other macOS versions

`-b` is the board id; `-m` is the model serial number prefix (00... = wildcard).

Common board ids for QEMU-friendly Macs:

| Board id | Mac model | macOS versions |
|---|---|---|
| `Mac-AA95B1DDAB278B95` | iMac20,1 | Sequoia (15) — what we use |
| `Mac-7BA5B2D9E42DDD94` | iMacPro1,1 | Big Sur–Sonoma |
| `Mac-CFF7D910A743CAAF` | MacBookPro15,1 | older, less compatible |

For Sequoia stick with iMac20,1 unless you have a specific reason to
deviate. Other board ids may pair with different SMBIOS than what
mos-docker advertises, causing recovery's IDP/iCloud activation to
fail.

## What `macrecovery.py -m` actually does

The "model serial number" field is a wildcard probe — Apple's recovery
endpoint expects a serial that matches the board id's model line.
`00000000000000000` is the universal "any" placeholder; the endpoint
returns the latest signed recovery DMG for the requested board.

You can pass a real serial too if you have one — it's used purely for
pairing the recovery DMG with the board id. `00...` works fine.

## Validating the download

Apple signs the DMG and `BaseSystem.chunklist` contains the chunks'
SHA-256s. The `chunklist` itself is signed. Validation is built into
`macrecovery.py` — if the script completes without error, the
download is authentic.

For paranoid use, manually:

```bash
shasum -a 256 BaseSystem.dmg
# Compare against what's in BaseSystem.chunklist (binary format — use
# `python3 -c "..."` to decode if you really want to)
```

In practice, just trust `macrecovery.py`'s exit code.

## Storage budget

- BaseSystem.dmg: ~3.2 GB (delete after conversion)
- BaseSystem.chunklist: a few KB (delete after conversion)
- RecoveryHDMeta.dmg: a few MB (delete after conversion)
- recovery.img: ~3.2 GB (keep — this is what mos-docker wants)

Total transient: ~7 GB during conversion. Long-term: 3.2 GB until you
delete it post-install.

## Once macOS is installed

`recovery.img` is no longer needed. mos-docker's `run` mode does
**not** mount it. You can either:

```bash
# Delete and reclaim the 3.2 GB
rm ~/mos-docker/data/recovery.img

# Or keep it around for future reinstalls
# (it's good for the macOS version you fetched; refresh to get newer)
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `macrecovery.py: command not found` | Wrong directory | Make sure you `cd OpenCorePkg/Utilities/macrecovery` first |
| `urllib.error.URLError: SSL: ...` | python3 SSL config issue | `pip3 install certifi`, re-run |
| `dmg2img: command not found` | Not installed | apt/brew install dmg2img |
| `dmg2img: ... no support for compressed DMG` | DMG was a different format | Re-run macrecovery; verify you have `BaseSystem.dmg` not `BaseSystem.lzma.dmg` |
| Install boots but recovery shows "Installation failed" | The DMG matches a different board id than the SMBIOS we advertise | Use `-b Mac-AA95B1DDAB278B95` exactly |
| Install boots but says "no internet" | Networking issue, unrelated to the recovery image | See [networking.md](networking.md) |

## Why we don't ship this in the docker image

- It's ~3.2 GB. Bloats every `docker pull`.
- It's per-macOS-version. Each new macOS release would require a new image.
- Apple's redistribution policy is unclear; bundling is a legal gray area.
- The bind-mount + one-time fetch model decouples macOS version from container version.

The setup cost is paid once per host. After install, `recovery.img` can
be deleted entirely.
