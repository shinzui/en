---
id: 78
slug: refuse-writes-of-tuples-the-active-schema-cannot-interpret
title: "Refuse writes of tuples the active schema cannot interpret"
kind: exec-plan
created_at: 2026-11-13T19:26:30Z
intention: "intention_01m7b5zgyvetfasfhd735hxmz9"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-13T19:26:30Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-14T00:01:51Z
      mode: "implement"
      note: "Milestones 1-3 implemented: validator, HTTP and import wiring, docs and ADR"
---

# Refuse writes of tuples the active schema cannot interpret

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Today En stores any relationship tuple it is asked to write, whether or not the schema it is
serving can interpret it. A client that writes `document:d1#viewr@user:ann` (a misspelt
relation), `repo:r1#reader@user:ann` against a schema with no `repo` type, or a subject type
the relation does not accept gets `200` and a consistency token, and the grant then silently
never takes effect: no check, lookup or expand can ever reach it. The mistake surfaces only
later, as an "orphan" in the report of `en-server check-schema` or of a `SIGHUP` schema reload.

After this plan, a write is refused, whole and before anything is stored, when any tuple it
would write cannot be interpreted by the schema the request is served under. The response is
the existing `400` problem with code `schema_violation`, naming the first offending tuple and
why. `en-server import` refuses the same tuples, naming the file line. An application that
embeds `en-core` gets the same check through one exported function. Deletes are not checked, so
an operator can still delete orphans a schema change left behind.

To see it working: start `en-server` with the demo schema (`user`, `space` with relation
`viewer`), write `space:s1#viewr@user:ann`, and observe `400 schema_violation` mentioning
`viewr`; write `space:s1#viewer@user:ann` and observe `200`; delete `space:s1#viewr@user:ann`
and observe `200`.

This also makes acceptance criterion AC-2 of
[IR-2](../improvement-requests/serve-several-isolated-tenants-from-one-en-server.md) hold as
written ("a write of an object type that only B's schema defines is refused as unknown under
A's schema"); see Context and Orientation.


## Progress

- [x] Milestone 1: `en-core` exports a pure write validator and a validated write operation,
      with unit tests for every orphan reason and for "deletes are never checked".
      Done 2026-11-13: `validateTupleWrites`, `applyValidatedTupleWrites` and
      `renderWriteRefusal` in `En.SchemaCheck`; `testValidateTupleWrites` in
      `en-core/test/Main.hs` covers each reason, valid/empty writes, deletes-only and
      precondition orphans accepted, first-orphan-wins, and that a refused validated write
      never reaches the store. `cabal test en-core-interface-tests` passes.
- [ ] Milestone 2: HTTP writes (`POST /v1/relationships`) and `en-server import` refuse
      uninterpretable tuples with `400 schema_violation` / a named file line; existing suites
      pass; the tenant suite's cross-type step asserts `schema_violation` again; the `write`
      workload shows no throughput regression.
- [ ] Milestone 3: the user guide and OpenAPI description state the rule, the change is noted
      for clients, and IR-2's record points here.


## Surprises & Discoveries

- `en-example` (`en-example/src/En/Example/Host.hs`, `exampleActiveSchema`) is a second
  embedded host that builds an `ActiveSchema` by hand; adding `validSchema` broke its build,
  exactly the downstream break the Interfaces section predicted. It now validates its
  compiled-in schema for the field.
- The en-servant route test wrote `space:project-x#viewer@user:bob` against the kikan fixture
  schema, whose `space` has no `viewer`. It relied on the old behaviour; it now writes
  `space#member`, and the refusal and delete cases sit beside it.
- `en-servant/test/hurl/relationships.hurl` is format-checked by `just hurl` but not run by it
  (it mutates state and is opt-in; see `en-servant/test/hurl/README.md`). The new refusal and
  orphan-delete requests were added there and run explicitly against a disposable database.


## Decision Log

- Decision: Validate written tuples with the existing orphan rule,
  `En.SchemaCheck.checkTupleAgainstSchema`, rather than a new rule.
  Rationale: "what a write refuses" and "what `check-schema` and reload call an orphan" must be
  the same set, or a tuple could be accepted by one and flagged by the other. After this
  change, orphans can only arise from schema changes, which is exactly the case those tools
  exist for.
  Date: 2026-11-13

- Decision: Only written tuples are checked; deletes, and the delete half of a mixed write
  request, are not.
  Rationale: deleting an orphan is the remedy `check-schema` points operators to. Refusing to
  delete a tuple because the schema cannot interpret it would leave no way to remove it.
  Date: 2026-11-13

- Decision: The check is a pure function in `en-core` plus a thin validated write operation,
  not a change to the `TupleStore` effect or its interpreters.
  Rationale: the store is deliberately schema-agnostic (it stamps a schema hash, it does not
  interpret a schema), and both interpreters (PostgreSQL and in-memory) would otherwise need
  the same logic. A pure check is testable without a store and costs no database round trip.
  Date: 2026-11-13

- Decision: `applyValidatedTupleWrites` lives in `En.SchemaCheck`, not `En.Effect.TupleStore`.
  Rationale: `En.SchemaCheck` imports `En.Effect.TupleStore`, so the reverse import is a cycle.
  Date: 2026-11-13

- Decision: The HTTP handler calls the pure `validateTupleWrites` before `engine`, rather than
  running `applyValidatedTupleWrites` inside it.
  Rationale: same rule and same snapshot, but a refused write never enters the engine or
  acquires a pool connection, and the handler keeps its `TupleStore`-only constraint (adding
  `Error EnError` would have widened the `Env es` contract). Embedded hosts calling effects
  directly use `applyValidatedTupleWrites`.
  Date: 2026-11-13

- Decision: A refused write renders as `cannot write <tuple> — <reason> not in schema`
  (`renderWriteRefusal`), not with `renderTupleOrphan`'s `ORPHAN … not in candidate schema`.
  Rationale: a write is judged against the schema it is served under, not a candidate; the
  reasons themselves are shared (`renderReasonIn`), so the two texts cannot drift apart.
  Date: 2026-11-13

- Decision: No opt-out flag.
  Rationale: a client that writes tuples its schema cannot interpret already has grants that
  never take effect; there is no correct behaviour to preserve. The change is announced in
  the user guide instead.
  Date: 2026-11-13


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

En is a relationship-based authorization toolkit in Haskell (GHC 9.12.4, `cabal`; enter the
development shell with `nix develop` or `direnv allow`). A **tuple** (or relationship, or
grant) is `object#relation@subject`, for example `space:s1#viewer@user:ann`; its Haskell type
is `En.Tuple.Tuple` in `en-core/src/En/Tuple.hs`. A **schema** declares object types, their
relations and permissions, which subjects each relation accepts, and caveats; the validated
form is `En.Schema.ValidSchema` (`en-core/src/En/Schema.hs`, constructed only by
`validateSchema`). An **orphan** is a stored tuple that a schema cannot interpret.

The orphan rule already exists. `checkTupleAgainstSchema :: ValidSchema -> Tuple -> Maybe
TupleOrphan` in `en-core/src/En/SchemaCheck.hs` checks, in order: the object type exists; the
relation exists on it; the subject's type exists (and for a userset subject like
`group:eng#member`, that relation exists on that type); the relation accepts a subject of this
shape (a permission accepts none, so writing to a permission is an orphan); the caveat, if any,
is defined; and every key of the caveat payload is a declared parameter of the declared type.
It returns the tuple with an `OrphanReason`, rendered for people by `renderTupleOrphan`. Today
it is used only by `validateTuplesAgainstSchema`, which scans a whole store for
`en-server check-schema` and for `SIGHUP` reload (`reloadStack` in `en-server/app/Tenant.hs`).

How a write flows today:

- HTTP: `POST /v1/relationships` is served by `writeTuplesHandler` in
  `en-servant/src/En/Tuple/Api.hs`. It reads the request's schema snapshot
  (`active <- activeSchema env`), decodes the tuples with `tupleFromWire`, and runs
  `engine env active (applyTupleWrites TupleWriteRequest {preconditions, writes, deletes})`.
  `POST /v1/relationships/delete` (`deleteTuplesHandler`) is the same with no writes. Errors
  raised as `EnError` inside `engine` become problem responses; `SchemaViolation Text`
  (`en-core/src/En/Error.hs`) already maps to `400` with code `schema_violation`
  (`specSchemaViolation` in `en-servant/src/En/Servant/Problem.hs`, mapping in
  `en-servant/src/En/Servant/Seam.hs`).
- The schema snapshot is `En.Servant.Seam.ActiveSchema` (`en-servant/src/En/Servant/Seam.hs`):
  `graph :: ReachabilityGraph`, `source`, `origin`, `loadedAt`. It does **not** hold the
  `ValidSchema`, and the compiled `ReachabilityGraph` (`en-core/src/En/Reachability.hs`) keys
  relations by `(objectType, relation)`, so a type with no relations (`object user {}`) has no
  entry in it. `checkTupleAgainstSchema` needs the `ValidSchema` to know `user` is a type.
  `ActiveSchema` is built in `buildStack` and `reloadStack` (`en-server/app/Tenant.hs`), in
  `en-servant/test/Main.hs`, and possibly in other en-servant test helpers; find every
  construction with `grep -rn "ActiveSchema" en-servant en-server`.
- Bulk import: `en-server import --file PATH` (`runImport` in `en-server/app/Main.hs`) decodes
  newline-delimited JSON tuples and writes each batch with `TupleStore.writeTuples`. It already
  has the loaded schema (its `LoadedSchema` argument, with field `validSchema`), currently
  unused.
- Embedded hosts call the effect operations in `en-core/src/En/Effect/TupleStore.hs`
  (`applyTupleWrites`, `writeTuples`, `deleteTuples`) directly. These stay unchecked; the plan
  adds a checked operation beside them.

Why this plan exists now: the tenancy initiative
(`docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`) found that IR-2
AC-2's verification assumes a write of an undeclared type is refused, which En has never done
in any mode (`docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md`,
Surprises & Discoveries). The owner decided to fix the behaviour on its own, outside that
initiative. The tenancy suite `en-server/test/TenantSpec.hs` currently asserts the narrower
guarantee in the step "a type only the other tenant defines stays in the writer's store, under
the writer's schema"; this plan restores the original assertion.

Relevant ADRs. [ADR 7](../adr/0007-generic-lens-labels-are-en-s-record-access-idiom.md):
generic-lens labels are the record-access idiom, with a measured exception on lookup's hot
path; the validator runs once per written tuple, so prefer plain pattern matching there if a
benchmark shows label cost (the existing `checkTupleAgainstSchema` already uses labels and is
the baseline). [ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md): the
in-memory store is for tests; the check must not live in a store interpreter. No ADR covers
write validation; this plan adds one (Milestone 3).


## Plan of Work

### Milestone 1: the validator in `en-core`

In `en-core/src/En/SchemaCheck.hs`, add and export:

```haskell
-- | The first written tuple the schema cannot interpret, if any. Deletes are never checked.
validateTupleWrites :: ValidSchema -> TupleWriteRequest -> Either EnError ()
```

It applies `checkTupleAgainstSchema` to each tuple of the request's `writes` in order and
returns `Left (SchemaViolation message)` for the first orphan, where `message` is
`renderTupleOrphan` of it (for example `space:s1#viewr@user:ann: unknown relation space#viewr`;
use whatever `renderTupleOrphan` produces). `preconditions` and `deletes` are ignored.
`TupleWriteRequest` lives in `En.Effect.TupleStore`; check the import does not create a module
cycle (`En.SchemaCheck` already imports `En.Effect.TupleStore`).

In `en-core/src/En/Effect/TupleStore.hs` (or a small new module if a cycle forbids it), add:

```haskell
-- | 'applyTupleWrites', after refusing any written tuple the schema cannot interpret.
applyValidatedTupleWrites ::
  (TupleStore :> es, Error EnError :> es) =>
  ValidSchema -> TupleWriteRequest -> Eff es ConsistencyToken
```

Add tests to the `en-core` interface test suite (find it with
`grep -n "test-suite" en-core/en-core.cabal`; it holds the existing `SchemaCheck` tests, which
show how schemas are built in tests): one case per `OrphanReason` constructor producing
`Left (SchemaViolation _)` whose message names the tuple; a valid write passing; a request
whose only orphan is in `deletes` passing; and a mixed request failing on its first written
orphan.

### Milestone 2: wire it into every write path

Add `validSchema :: ValidSchema` to `ActiveSchema` in `en-servant/src/En/Servant/Seam.hs`, and
set it everywhere an `ActiveSchema` is built (`buildStack` and `reloadStack` in
`en-server/app/Tenant.hs` both have the `ValidSchema` at hand; the en-servant tests build theirs
from a schema they validate). Because `ActiveSchema` is swapped atomically on reload, the
snapshot a request holds carries the graph and the schema it was compiled from together; a
reload between a request's snapshot and its write cannot validate against one schema and
evaluate under another.

In `writeTuplesHandler` (`en-servant/src/En/Tuple/Api.hs`), replace `applyTupleWrites` with
`applyValidatedTupleWrites (active ^. #validSchema)`. Leave `deleteTuplesHandler` and
delete-by-filter unchanged.

In `runImport` (`en-server/app/Main.hs`), validate each decoded tuple with
`checkTupleAgainstSchema` against the loaded schema and fail with the existing `lineFailure`
naming the file line and `renderTupleOrphan`'s reason. Validate a batch before writing it, so a
bad line stops the import before that batch is stored; batches before it remain committed, as
for a malformed line today (re-running a corrected file is idempotent).

Restore the original assertion in `en-server/test/TenantSpec.hs`: in the isolation case, a write
of `repo:r9#reader@user:ann` under alpha's key and of `document:d9#viewer@user:bob` under beta's
key each answer `400` with code `schema_violation`, and neither tenant's relationship query
then mentions `r9` or `d9`. Update that step's comment and title.

Add an en-servant test (in `en-servant/test/Main.hs`, following its existing handler tests) for
`POST /v1/relationships` with an undeclared relation answering `400 schema_violation`, and for
`POST /v1/relationships/delete` of the same tuple answering `200`.

Then check the existing behaviour suites still pass, since any of them might write a tuple its
own schema does not declare: `cabal test all`, the Hurl suite (see Concrete Steps), and
`just loadbench-smoke` (its seed is written through `en-server import`). A failure there is
either a test that relied on the old behaviour (fix the test data and record it in Surprises &
Discoveries) or a real gap in `checkTupleAgainstSchema` (stop and record it).

Finally, measure the write path: run the A/B benchmark of the commit before this plan against
the new binary and confirm `write` (and every other workload) passes. See Concrete Steps.

### Milestone 3: documentation and records

In `docs/user/queries-and-writes.md`, under "Write semantics", state the rule: a write is
refused with `schema_violation` when any written tuple names an unknown object type or relation,
a subject type or userset the relation does not accept, a permission instead of a relation, or
an undefined caveat or ill-typed payload; deletes are never refused for this reason, so orphans
left by a schema change can be removed. Mention `en-server import` in
`docs/user/service-and-operations.md` ("Bulk import and export"). Add a sentence to the
description of `POST /v1/relationships` in the OpenAPI source if it lists its `400` causes, then
run `just openapi` and commit the regenerated `docs/api/openapi.json` if it changed.

Write `docs/adr/NNNN-writes-are-validated-against-the-active-schema.md` (next unused number, in
the format of the existing ADRs: front matter `title`, `status`, `date`, `authors`, `related`;
sections Context, Decision, Consequences) recording the rule, its reuse of the orphan rule, the
delete exception, and the placement outside the store.

In `docs/plans/76-prove-tenant-isolation-and-performance-then-document-tenant-operations.md`,
replace the deferred AC-2 question with a pointer to this plan's outcome, so IR-2's resolution
cites it.


## Concrete Steps

All commands run from the repository root inside the development shell.

Milestone 1:

```bash
cabal build en-core
cabal test en-core
```

Milestone 2:

```bash
cabal build all
cabal test all
cabal test en-server-tenant-tests
just loadbench-smoke
```

The Hurl suite needs a server on a free port (port 8080 may be taken; see friction entry
FRIC-2). With the local PostgreSQL from `just process-up` running:

```bash
just process-up && just run-migrations
EN_PORT=18181 EN_DATABASE_URL="$PG_CONNECTION_STRING" \
  EN_API_KEYS_READ_WRITE=dev:dev-secret-0123456789 \
  "$(cabal list-bin en-server:exe:en-server)" > .dev/hurl-server.log 2>&1 & echo $! > .dev/hurl-server.pid
EN_SERVER_URL=http://127.0.0.1:18181 just hurl
kill "$(cat .dev/hurl-server.pid)"
just process-down
```

The write-path benchmark (about 50 minutes; leave the machine alone while it runs). Build the
commit before this plan as the reference, then compare:

```bash
en-server/loadbench/build-baseline.sh <commit-before-this-plan>
cabal build -v0 en-server:exe:en-server
cp "$(cabal list-bin -v0 en-server:exe:en-server)" .dev/loadbench/en-server-validated
cabal run -v0 en-server-loadbench -- ab \
  --baseline .dev/loadbench/en-server-baseline \
  --candidate .dev/loadbench/en-server-validated \
  --rounds 3 --json .dev/loadbench/write-validation.json
```

`build-baseline.sh` replaces `.dev/loadbench/en-server-baseline`, the reference binary the
tenancy gates of `docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md`
use. Copy it aside first and restore it afterwards:

```bash
cp .dev/loadbench/en-server-baseline .dev/loadbench/en-server-baseline-tenancy
cp .dev/loadbench/baseline.sha .dev/loadbench/baseline-tenancy.sha
# ... build-baseline.sh and the A/B above ...
cp .dev/loadbench/en-server-baseline-tenancy .dev/loadbench/en-server-baseline
cp .dev/loadbench/baseline-tenancy.sha .dev/loadbench/baseline.sha
```

Expected last line:

```text
RESULT: PASS (7 workloads, 3 rounds)
```

Milestone 3:

```bash
just openapi
treefmt
```

Every commit carries:

```text
ExecPlan: docs/plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md
Intention: intention_01m7b5zgyvetfasfhd735hxmz9
```


## Validation and Acceptance

- `cabal test en-core` passes with the new validator cases: each orphan reason refused with
  `SchemaViolation` naming the tuple; a valid write accepted; an orphan only in `deletes`
  accepted; a mixed request refused on its first written orphan.
- Against a running server with the demo schema: `POST /v1/relationships` with
  `space:s1#viewr@user:ann` answers `400`, `code` `schema_violation`, and a following
  relationship query for `user:ann` does not return it; the same tuple through
  `POST /v1/relationships/delete` answers `200`; a valid tuple still answers `200` with a token.
- `en-server import --file` with a file whose third line is an undeclared relation exits 1 with
  a message naming line 3 and the reason; the batches before it are committed, and re-running
  the corrected file succeeds.
- `cabal test en-server-tenant-tests` passes with the restored `schema_violation` assertion.
- `cabal test all`, the Hurl suite and `just loadbench-smoke` pass.
- The write-path A/B ends with `RESULT: PASS (7 workloads, 3 rounds)`; paste its table into
  Progress.


## Idempotence and Recovery

Each milestone is an ordinary code change and can be reverted alone; no migration or stored
data changes. Existing orphans in a database are untouched: they remain readable by
`check-schema`, deletable, and harmless to checks. Benchmarks and tests create and remove their
own PostgreSQL instances. The only shared state is the reference binary
`.dev/loadbench/en-server-baseline`; restore it as shown in Concrete Steps.


## Interfaces and Dependencies

No new library.

- `En.SchemaCheck.validateTupleWrites :: ValidSchema -> TupleWriteRequest -> Either EnError ()`
  (new, exported).
- `applyValidatedTupleWrites :: (TupleStore :> es, Error EnError :> es) => ValidSchema ->
  TupleWriteRequest -> Eff es ConsistencyToken` (new, exported from `En.Effect.TupleStore` or a
  new `en-core` module if a cycle requires it).
- `En.Servant.Seam.ActiveSchema` gains `validSchema :: ValidSchema`. This is a change to an
  exported record of `en-servant`; embedded hosts that build an `ActiveSchema` themselves must
  set the new field. Note it in the user guide's embedding section if one documents building an
  `ActiveSchema`.
- The wire contract does not change: `400 schema_violation` already exists.
