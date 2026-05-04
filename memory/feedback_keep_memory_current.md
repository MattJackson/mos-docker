---
name: Keep CLAUDE.md and memory current after every milestone — no catch-up tax
description: CLAUDE.md and the memory/ entries must reflect current reality so any new agent session can start work immediately. After every meaningful milestone (bug fix, version bump, design change, infra change, new rule learned), update memory + CLAUDE.md before moving on.
type: feedback
date: 2026-05-03
---

`CLAUDE.md` and the entries under `memory/` are the agent onboarding
contract. A new session should be productive from the first turn — no
30-minute recovery archaeology, no rereading old commits to figure
out where things stand.

**Why:** Stale memory wastes the most expensive resource in the loop —
the operator's attention. Past sessions have shown agents reasoning
from stale claims (versions, removed APIs, superseded designs) and
producing wrong recommendations. The fix is at the write site, not
the read site: keep memory current.

**How to apply:**

After any of these milestones, update memory + CLAUDE.md *in the same
session* before declaring the milestone closed:

- Bug fix that changes load-bearing behavior (the bug, the fix, the
  guard test) → either a new `project_<topic>.md` or update the
  existing one; cross-reference in `MEMORY.md`.
- Version bump → update overview entries; update the "Currently vX.Y.Z"
  line in `CLAUDE.md` if present.
- Architecture / algorithm change (data model, transport flow,
  dispatcher logic, deployment topology) → replace or supersede the
  relevant `project_*.md`; move the predecessor into `memory/history/`.
- Infra/rig change (new test target, new host, new credential
  rotation) → update the relevant `reference_*.md`.
- Standing rule learned from a correction → new `feedback_*.md`,
  indexed in `MEMORY.md`.

When superseding a memory entry, follow `memory/README.md` —
`history/` for forensics, drop from `MEMORY.md` index, and add a
SUPERSEDED note at the top if leaving the body intact.

**The simple test:** after the milestone, can a brand-new agent open
the workspace, read `CLAUDE.md` + `MEMORY.md` + the linked project
entries, and pick up the work without asking "where are we?" If no,
memory is stale.
