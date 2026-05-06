# mos-docker library

Curated documentation for [mos-docker](https://github.com/MattJackson/mos-docker)
specifically — this is the *runtime* repo's local docs. For
**project-wide vision, architecture, and whitepapers**, see
[**mos-docs**](https://github.com/MattJackson/mos-docs) — that's the
canonical project library covering all 5 sibling repos.

This local library covers what's specific to running mos-docker:
operational topics, the regression test infrastructure, and the
historical record of incidents in this repo.

## How to navigate

If you're trying to **run macOS for the first time**, read in order:

1. [README.md](../README.md) — quickstart (5 min read)
2. [SETUP.md](../SETUP.md) — full first-time setup (~15 min read; ~1 hr of doing)
3. [Recovery image](recovery-image.md) — how to acquire `recovery.img`
4. [OpenCore image](opencore-image.md) — how to build `OpenCore.img`

If you're **operating an installed VM**:

- [Networking](networking.md) — macvtap auto-detect, HOST_IFACE pinning, troubleshooting
- [Troubleshooting](troubleshooting.md) — common runtime issues + fixes
- [Architecture](architecture.md) — what each script + container does

If you're a **contributor / debugging the build**:

- [Architecture](architecture.md) — code layout, dispatcher, safety guarantees
- [QEMU build](qemu-build.md) — fast iteration on `mos-qemu` patches
- [Testing](testing.md) — 5-phase regression chain, gold workflow
- [Roadmap](roadmap.md) — open work items

If you want **historical context**:

- [Incidents](incidents/) — public post-mortems
- [Releases](releases/) — release notes
- [Archive](archive/) — superseded docs (M1-era)

## Docs by topic

### Reference (always-current)

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | Production image, dispatcher, safety guarantees, layout |
| [networking.md](networking.md) | macvtap default, HOST_IFACE, slirp fallback |
| [recovery-image.md](recovery-image.md) | How to acquire `recovery.img` via macrecovery.py |
| [opencore-image.md](opencore-image.md) | OpenCore EFI image build + config |
| [qemu-build.md](qemu-build.md) | Iterating on `mos-qemu` patches against the container |
| [testing.md](testing.md) | 5-phase regression chain + visual gold workflow |
| [troubleshooting.md](troubleshooting.md) | Common errors + recovery |

### Project state

| Doc | What it covers |
|---|---|
| [roadmap.md](roadmap.md) | Open SMC keys, ACPI tables, GPU work — backlog |
| [../CHANGELOG.md](../CHANGELOG.md) | Release-tagged change history |
| [releases/](releases/) | Per-release notes |

### Incidents (public post-mortems)

| Date | Incident | Doc |
|---|---|---|
| 2026-05-06 | Auto-install-mode wiped a 256 GB install | [2026-05-06-disk-wipe.md](incidents/2026-05-06-disk-wipe.md) |

### Archive

Superseded docs preserved for historical reference. Don't follow these
for current work — they describe the M1-era layered architecture that
was collapsed in the 2026-05-06 refactor.

| Doc | Replaced by |
|---|---|
| [archive/m1-operator-runbook.md](archive/m1-operator-runbook.md) | [SETUP.md](../SETUP.md) + [testing.md](testing.md) |
| [archive/m1-post-boot-quickref.md](archive/m1-post-boot-quickref.md) | [troubleshooting.md](troubleshooting.md) |
| [archive/m1-dry-run-prediction.md](archive/m1-dry-run-prediction.md) | (no longer relevant) |
| [archive/end-to-end-integration-guide.md](archive/end-to-end-integration-guide.md) | [SETUP.md](../SETUP.md) |
| [archive/test-runbook.md](archive/test-runbook.md) | [testing.md](testing.md) |

## Conventions

- Every doc starts with one paragraph: what it covers and who reads it.
- Code blocks have explicit languages (`bash`, `yaml`, `dockerfile`).
- Internal links are relative paths (`../README.md`, `incidents/X.md`).
- "Don't do X because Y" tables encode painful lessons — keep them.
- New incident? Add `incidents/YYYY-MM-DD-<short-name>.md` and link from this index.
- New release? Add `releases/<version>.md` and link from this index + CHANGELOG.
