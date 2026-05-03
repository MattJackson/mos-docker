---
name: No broad sed changes
description: Never use broad sed/find-replace across multiple files. Fix files individually.
type: feedback
---

Never do broad sed changes across multiple files. Too risky — breaks syntax, mismatches braces, wastes time debugging.

**Why:** Multiple sessions of broken builds from sed replacing patterns that matched unexpectedly.

**How to apply:** Edit files one at a time with targeted changes. Read the file first, understand the context, make the specific edit.
