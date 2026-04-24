# Security Policy

## Supported versions

Security fixes are developed against the latest minor release line. Older
releases receive fixes only on a best-effort basis.

| Version | Supported          |
| ------- | ------------------ |
| 0.5.x   | Yes                |
| < 0.5   | No                 |

## Reporting a vulnerability

Please **do not** file public GitHub issues for security problems.

Report vulnerabilities privately through GitHub Security Advisories:

- https://github.com/MattJackson/mos-docker/security/advisories/new

Include, where possible:

- A clear description of the issue and its impact.
- The affected version (commit SHA or release tag).
- Reproduction steps, proof-of-concept, or a minimal test case.
- Any known mitigations or workarounds.

## Response expectations

This is a small, best-effort project. Response times are measured in days to
weeks rather than hours. We will:

1. Acknowledge receipt of the report.
2. Investigate and confirm the issue, requesting additional information if
   needed.
3. Develop a fix and coordinate a disclosure timeline with the reporter.
4. Publish the fix and credit the reporter (if desired) in the release notes.

CVE assignment is **not** guaranteed at this project's scale. Advisories may
be published via GitHub's advisory database without a CVE ID.

## Scope

In-scope: code, build scripts, container configuration, and kext sources
maintained in this repository.

Out-of-scope: upstream projects (QEMU, OpenCore, Mesa, macOS itself, etc.) —
please report those to their respective maintainers. Issues in the companion
`mos` repositories (`mos15-patcher`, `qemu-mos15`, `opencore-mos15`) should be
reported to each repository's own advisory tracker.
