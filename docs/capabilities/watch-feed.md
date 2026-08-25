---
title: "Poll a windowed watch feed of tuple changes"
type: Capability
description: "Subscribe to relationship changes from now, from a cursor, or from an ordinary consistency token, and drain each revision window across polls with a cursor that pins both window edges."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-17
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
  - en-postgres
interface:
  - En.Watch
  - En.Postgres.Watch
  - POST /v1/watch
requires:
  - CAP-12
evidence:
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: runWatchWindowScenario and runWatchFeedScenario drive the feed against a real PostgreSQL, covering window draining and resumption.
  - kind: test
    resource: en-postgres/test/Main.hs
    proves: testWatchCursorCodec round-trips and validates the watch cursor encoding.
  - kind: test
    resource: en-servant/test/Main.hs
    proves: The /v1/watch wire contract, including that cursor and startToken are mutually exclusive.
---

# Poll a windowed watch feed of tuple changes

A poll returns the [tuple changes](relationship-writes.md) in a revision window, a cursor to
resume from, and the `checkedAt` token of the revision the window ended at. A subscription
starts in one of three ways:

- `StartFromNow` — first poll returns no changes, only a cursor.
- `StartFromCursor` — resume a previous poll.
- `StartFromToken` — start from the revision an ordinary
  [consistency token](consistency-tokens-and-snapshot-reads.md) pins, so "every change since my
  write" is one call.

The cursor carries **both window edges plus a position**, which a token cannot hold. That is why
a resuming poll re-resolves nothing: a window with more changes than one page must be drained
across several polls that all read the *same* window, or the batch stops being the set
difference between two snapshots and becomes a smear across several.

## Usage

```http
POST /v1/watch
{"startToken": "en1.…", "limit": 500}
```

## Limits

- It is **polling, not streaming**. There is no long-lived connection and no push.
- A cursor is always returned, including for an empty batch, so a caught-up consumer can keep
  polling. Absence of changes is not a signal to stop.
- The feed is a PostgreSQL capability. An embedded host with no store supplies
  `watchUnsupported`, which fails loudly rather than reporting a permanently empty feed.
