---
title: "Report stored tuples that no longer match the schema"
type: Capability
description: "Scan a store against a candidate schema and report every orphaned tuple with the reason it no longer fits, as the preflight a schema change needs before it is activated."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-25
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-core
interface:
  - En.SchemaCheck
requires:
  - CAP-1
  - CAP-11
evidence:
  - kind: test
    resource: en-core/test/Main.hs
    proves: testValidateTuplesAgainstSchema covers checkTupleAgainstSchema and validateTuplesAgainstSchema across the orphan reasons.
  - kind: test
    resource: en-postgres/integration-test/Main.hs
    proves: runSchemaValidationScenario runs the scan against a real store.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: The "Changing the schema" section, where the report is the gate on a model change.
---

# Report stored tuples that no longer match the schema

`validateTuplesAgainstSchema` drains a store at a revision and returns an `OrphanReport`: every
`TupleOrphan` with its `OrphanReason` — an object type the candidate no longer declares, a
relation it dropped, a subject shape it no longer allows. `renderTupleOrphan` formats one for an
operator.

Nothing validates tuples on the [write path](relationship-writes.md), so this is the only place
drift is caught. It is what [schema reload](schema-reload-and-preflight.md) runs before it
activates a candidate, and what `en-server check-schema` runs offline.

## Usage

```haskell
revision <- TupleStore.headRevision
report   <- validateTuplesAgainstSchema candidate revision
traverse_ (putStrLn . renderTupleOrphan) report.orphans
```

## Limits

- It is a **full scan** at one revision. On a large store it is an operation to schedule, not a
  request-path call.
- The pass mints no token and presents none: it reads the head revision and drains it, so it is
  unaffected by whichever schema the interpreters are currently running.
- It reports drift; it does not repair it. Deciding whether to delete orphans or change the
  candidate is the operator's call.
