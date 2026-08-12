# go-git reference pin

| Field | Value |
|-------|--------|
| Repository | https://github.com/go-git/go-git |
| Pin type | release tag |
| Pin | `v5.19.2` |
| Published | 2026-07-29 |
| Decision date | 2026-08-07 |
| Local path | Checkout the pin next to the bare repo / worktrees when refreshing goldens (path is machine-local; not required for builds) |

## Policy

Prefer the latest **release** if it is not older than 6 months.
If the latest release is older than 6 months, pin the latest commit on the default branch instead.

Record every pin change here (old pin, new pin, date).

## Decision notes (2026-08-07)

- Latest release at decision time: `v5.19.2` (published 2026-07-29).
- Age relative to decision date: under 6 months.
- Action: pin release tag `v5.19.2` (not floating main).
