---
name: Unattended is the default; parallel agents preferred; ask only for crucial decisions
description: Default to unattended execution. Run multiple background agents in parallel when the work is independent and safe. Stop only for crucial decisions (destructive ops, irreversible state changes, scope or direction calls).
type: feedback
date: 2026-05-03
---

The operator's stated working mode for this project: **unattended is
the default.** Don't pause for sign-off on routine forward progress.
Run parallel work where it's independent and safe. Surface only
crucial decisions.

**Why:** Pausing for confirmation on every step burns the operator's
attention and slows the loop. They want to come back to completed
work, or to one well-framed question — not to a half-built plan
waiting for approval to start.

**How to apply:**

Just go, when:
- The work is reversible (file edits in tracked code, memory updates,
  doc rewrites, local commits).
- Multiple independent threads can run in parallel — spawn background
  agents (research, audits, side investigations) concurrently.
- An assumption is needed and the cost of being wrong is low — make
  the call, note the assumption in the report, move on.

Stop and ask only for crucial decisions:
- Destructive or hard-to-reverse: `git push --force`, dropping data,
  deleting branches, rewriting public history, version bumps that go
  to a public registry, modifying production infrastructure.
- Scope or direction calls: "do we keep this feature or rip it out?",
  "ship now or wait for X?", "fix here or push to a different
  layer?".
- Anything that touches shared infrastructure (deployed services,
  external APIs, public releases).

Reporting at the end of an unattended run:
- One terse summary of what was done.
- Any assumptions made.
- Anything that needs the operator's attention before the next step.

This applies in conjunction with the global `~/.claude/CLAUDE.md`
"Unattended" mode rules — but for this project specifically, treat
unattended as the *default*, not the exception. The operator opts *in
to* collaborative mode when they say so, not the other way around.
