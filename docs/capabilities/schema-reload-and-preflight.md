---
title: "Reload and preflight a schema without restarting"
type: Capability
description: "Signal a running server to re-read its schema file and swap the active model atomically, refusing any candidate that would orphan stored tuples, and preflight the same check offline with a check-schema subcommand."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-21
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-server
interface:
  - en-server check-schema
  - GET /v1/schema
requires:
  - CAP-3
  - CAP-20
  - CAP-25
evidence:
  - kind: module
    resource: en-server/app/Main.hs
    proves: reloadSchema — every failure mode (unreadable file, parse error, validation error, orphan refusal) leaves the previous ActiveSchema untouched; an unchanged hash skips the swap and its token-invalidation warning; the swap is a single atomicWriteIORef that in-flight requests never observe mid-change.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: Reading the schema a server is running, changing the schema, and reloading it without a restart.
---

# Reload and preflight a schema without restarting

On `SIGHUP` the server re-reads `EN_SCHEMA_PATH`, parses and validates the candidate, scans the
store for tuples the candidate would orphan, and only then swaps the active model.

Two decisions make this safe to run against production:

1. **Every failure keeps serving.** An unreadable file, a parse error, a validation error, and an
   orphan refusal each log and return with the previous schema intact. This is the one place the
   server diverges from its fail-closed startup path, where exiting *is* the safe move because
   nothing is being served yet.
2. **An unchanged file is not a reload.** If the candidate's
   [schema hash](reachability-compilation.md) equals the active one's, the swap is skipped — and
   so is the token-invalidation warning, so an operator who signals twice is not falsely told
   they just invalidated every token in flight.

The swap is one `atomicWriteIORef`. A request took its snapshot at its start and holds it, so no
in-flight request sees a half-changed model.

`en-server check-schema` runs the same candidate-versus-store check offline, and
`GET /v1/schema` reports the model a server is actually running.

## Limits

- Reload needs `EN_SCHEMA_PATH`. A server on the built-in demo schema has nothing to re-read and
  says so.
- An orphaning candidate is refused unless `EN_SCHEMA_RELOAD_FORCE=true`, which **activates it
  anyway** — the orphaned tuples stay in the store and stop matching the model.
- A schema whose hash changed invalidates every outstanding
  [consistency token](consistency-tokens-and-snapshot-reads.md), by design.
