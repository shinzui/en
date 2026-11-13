---
type: Friction Entry
title: "macOS SysV shared memory limit fails parallel ephemeral PostgreSQL"
description: "macOS allows 32 System V shared memory segments system-wide (kern.sysv.shmmni); each ephemeral-pg instance holds one, so a test suite running a case per core with two instances each fails initdb with 'could not create shared memory segment: No space left on device'."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T19:44:59Z"
frictionId: FRIC-3
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/en"
affects: "mori://shinzui/ephemeral-pg"
plan: "docs/plans/74-give-each-tenant-an-independent-lifecycle-and-contain-its-storage-faults.md"
workaround: "TenantSpec's main sets TASTY_NUM_THREADS=3 unless the caller sets it; all 17 cases pass"
resolution: "A platform limit of macOS (kern.sysv.shmmni = 32), not a defect of ephemeral-pg; the tenant suite bounds its concurrency with TASTY_NUM_THREADS=3 by default, and a caller can override it."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-13T19:46:04Z"
    change: "Status set to accepted."
---
# macOS SysV shared memory limit fails parallel ephemeral PostgreSQL

## Attempted

cabal test en-server-tenant-tests after the suite grew to 17 cases, each starting two PostgreSQL instances

## Encountered

4-5 cases failed at random with initdb FATAL could not create shared memory segment (shmget size=56), or timed out waiting for PostgreSQL; -with-rtsopts=-N4 did not bound tasty's concurrency

```text
FATAL:  could not create shared memory segment: No space left on device
DETAIL:  Failed system call was shmget(key=498112042, size=56, 03600).
kern.sysv.shmmni: 32
```

## Workaround

TenantSpec's main sets TASTY_NUM_THREADS=3 unless the caller sets it; all 17 cases pass
