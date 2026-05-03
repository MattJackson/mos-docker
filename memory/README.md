# memory/ — auto-memory conventions

Persistent facts, rules, and references that survive across sessions.
The harness reads `MEMORY.md` automatically each turn; individual
files are read on demand by the model when relevant.

Optimized for **small models** (qwen3 35B-A3B class via OpenCode):
small models can't reason their way out of a contradictory or bloated
context, so this directory is curated, not journaled.

## Layout

| Path | Purpose |
|---|---|
| `MEMORY.md` | Index of every active entry, one per line. Loaded each turn. |
| `README.md` | This file. Conventions only — not a memory entry. |
| `<type>_<topic>.md` | Individual memory entries. Frontmatter required. |
| `history/` | Archived dated session logs and superseded memos. **Not** indexed in `MEMORY.md`. |

**Memory lives in this directory, in git. Never under `~/.claude/projects/`** —
that location is auto-memory leftover and content there will not survive
session compaction or workstation moves. If you find anything in
`~/.claude/projects/<path>/memory/` for this project, migrate it here
and commit before doing further work.

## Entry types

Pick the type that fits; encoded in the filename prefix and the
frontmatter `type:` field.

- **`user_*`** — facts about the user: role, preferences, working
  style. Inform tone, depth, and framing of every response.
- **`feedback_*`** — standing rules for how to work. Corrections,
  preferences, lessons learned. Each: rule + **Why:** + **How to apply:**.
- **`project_*`** — durable project facts: architecture, milestone
  closures, the "what" and "why" behind ongoing work.
- **`reference_*`** — pointers to external systems, credentials
  (sanitized), or operational facts: SSH targets, build hosts,
  baseline images.

## File frontmatter (required)

```markdown
---
name: short title
description: one-line hook used to decide relevance in future sessions
type: feedback | project | reference
---

content body
```

## `MEMORY.md` index hygiene

- One entry per line. Format: `- [Title](file.md) — hook under 15 words.`
- Max ~35 entries. If you're adding a 36th, something else should leave.
- Entries are sorted implicitly by type (project facts → milestones →
  feedback rules → references), but no headers — small models don't
  need the section overhead.
- Cross-repo or out-of-dir links use relative paths (e.g.
  `../paravirt-re/library/foo.md`).

## What to save

- Architectural facts that aren't obvious from the code.
- Standing rules ("never use MSI-X", "don't add Co-Authored-By").
- Closed-milestone summaries — what landed and why.
- Pointers to where details live (RE library, secrets repo, dashboards).
- The "current state of play" *only* when it's the canonical entry
  point and gets updated as state changes.

## What NOT to save

- Things derivable from `git log`, `git blame`, or reading the code.
- Per-session journals ("today I tried X, it failed because Y"). Those
  go in `history/` if they need to live anywhere.
- The same fact restated five different ways across five files.
- Lists of recent commits with dates — `git log` is authoritative.
- Conclusions from in-progress investigations. Wait until it's settled.

## Milestone consolidation

Once a milestone (M3, M5, etc.) closes:

1. Write **one** `project_<milestone>_closed.md` capturing the load-bearing
   facts, fixes, and corrections that survive the closure.
2. Move every dated journey log for that milestone into `history/`.
3. Drop the journey-log entries from `MEMORY.md`. Add the single
   closure entry instead.

The journal is in `history/` for forensics; the index reflects
*current state*, not *history of state*.

## Annotate, don't rewrite

When a memory entry becomes partially stale (some facts still apply,
some are superseded by a later commit or RE finding):

1. Add a block at the top:
   ```
   > **SUPERSEDED YYYY-MM-DD:** <one-line correction + canonical source>
   ```
2. Leave the body intact. Stale reasoning is sometimes useful for
   forensics, and a small model that lands on the entry will see the
   override before reading the body.

Only delete content when it's flat-out wrong with no historical value.

## Cross-references

- Project root `CLAUDE.md` is the **airport map** — auto-loaded each
  turn, points into this directory and into the deep technical
  reference (`paravirt-re/library/` for mos).
- This directory holds **standing facts**.
- The deep technical reference holds **wire formats, class layouts,
  flow diagrams** — large body, narrow per-task reads.

`CLAUDE.md` and `MEMORY.md` together should fit under ~15 KB.
