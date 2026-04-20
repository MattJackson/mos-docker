## What this PR does

<!-- 1-2 sentences describing the change. -->

## Why

<!-- Context / motivation. Link any issue or verify-* regression that
     motivated the change. -->

## Test plan

<!-- Reproducible steps a reviewer can run. Prefer invoking
     `docker compose build` and the relevant `verify-m1`/`verify-m2`/
     `verify-m3` script. -->

```
docker compose build
./scripts/verify-m1.sh
```

## Verification

- [ ] I ran `docker compose build` locally and it succeeded.
- [ ] The relevant `verify-m1` / `verify-m2` / `verify-m3` check passed.
- [ ] No secrets, tokens, or machine-specific paths were committed.

## Linked issues

<!-- Fixes #..., Refs #... -->
