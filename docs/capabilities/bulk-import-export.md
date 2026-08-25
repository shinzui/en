---
title: "Bulk import and export of relationships"
type: Capability
description: "Stream every live relationship to stdout as JSON lines, and read them back in bounded transactions, as en-server subcommands for seeding, migration, and backup."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-22
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-server
interface:
  - en-server export
  - en-server import
requires:
  - CAP-11
  - CAP-13
evidence:
  - kind: module
    resource: en-server/app/Main.hs
    proves: runExport drains every live relationship to stdout and runImport reads JSON lines back in transactions of a configurable --batch-size (default 1000).
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: runReadAllTuplesScenario proves the full-store drain the export path depends on.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: The bulk import and export section, with the exact command lines.
---

# Bulk import and export of relationships

Two subcommands on the same binary as [the server](standalone-authorization-server.md):

```bash
# Write every live relationship to stdout, one JSON object per line.
en-server export > relationships.jsonl

# Read them back, in transactions of 5000 relationships.
en-server import relationships.jsonl --batch-size 5000
```

Line-oriented JSON so the output composes with ordinary shell tooling — `grep`, `split`, `jq` —
rather than requiring a bespoke reader.

## Limits

- Export emits **live** relationships only. Tombstoned rows and history are not included, so an
  export/import round trip is not a snapshot-preserving backup — it produces a fresh datastore
  identity and invalidates outstanding
  [consistency tokens](consistency-tokens-and-snapshot-reads.md).
- Import is batched, not transactional as a whole: a failure partway leaves earlier batches
  applied.
- Neither subcommand validates tuples against the active schema; run
  [the drift report](tuple-schema-drift-report.md) after a large import.
