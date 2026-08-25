---
id: 58
slug: add-a-mutable-in-memory-tuple-store-for-tests-and-demos
title: "Add a Mutable In-Memory Tuple Store for Tests and Demos"
kind: exec-plan
created_at: 2026-07-07T20:37:43Z
intention: intention_01kx20y2tyeem9wat59b32ke7g
---

# Add a Mutable In-Memory Tuple Store for Tests and Demos

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en's algorithms use two `effectful` effects rather than talking to a database directly.
`TupleStore` stores relationship tuples and reads them at named revisions;
`ConsistencyStore` turns a caller's consistency request into one of those revisions. The
production interpreters live in `en-postgres`. `En.Conformance.Kikan` has a small pure,
stateful fixture interpreter, but it intentionally has no historical snapshots: every read
sees its current list and maintenance operations are placeholders.

After this plan, `en-core` exports `En.Store.InMemory`, a reusable mutable interpreter for
tests and databaseless demonstrations. A caller creates one opaque `InMemoryWorld`, installs
both effects over it, writes a grant, and sees an ordinary engine `check` change from
`Denied` to `Allowed`. Deleting the grant changes the answer back, while an
`AtExactSnapshot` read at the pre-delete token still sees the grant. The store also implements
the current filter, precondition, bulk-read, changelog, and garbage-collection operations, so
it is a complete interpreter of today's `TupleStore` rather than a narrowly compiling fake.

The module states that it is not a production store. Its process-local state is not durable,
its total-order counter only models PostgreSQL's partially ordered transaction snapshots, and
independent application instances cannot agree on its state. Production deployments must use
`en-postgres`.


## Progress

- [x] Refresh the 2026-07-07 draft against the 2026-08-25 tree: current effect surface,
      touch writes, preconditions, relationship filters, changelog, GC horizon, example host,
      test harness, docs, ADRs, and canonical cross-repository references. (2026-08-25)
- [x] M1: add and export `En.Store.InMemory` with an opaque `InMemoryWorld`, complete
      `TupleStore` and `ConsistencyStore` interpreters, and combined `runInMemoryStores`.
      (2026-08-25; implementation written, build correction remains below.)
- [x] M1: correct build/type issues found by the first compiler pass. (2026-08-25)
- [x] M1: document the test/demo-only boundary and validate `cabal build en-core` plus
      `cabal haddock en-core`. (2026-08-25; both exit 0, Haddock reports 100% coverage for
      `En.Store.InMemory`.)
- [x] M2: add focused `en-core/test/Main.hs` assertions for mutation, exact snapshots,
      consistency resolution, stable cursors, touch/precondition/filter operations,
      changelog, reaping, and malformed tokens/cursors. (2026-08-25; assertions written,
      compiler/test corrections remain below.)
- [x] M2: correct build or behavioral failures exposed by the new assertions. (2026-08-25)
- [x] M2: prove `check` and `lookup` end to end over tuples written through the mutable
      interpreter; validate `cabal test en-core`. (2026-08-25; both core suites pass.)
- [x] M3: migrate `en-example` from fixed Kikan fixture lists to a shared mutable world and
      seed its demo grant through `writeTuples`. (2026-08-25; code written, workspace build
      correction remains below.)
- [x] M3: correct build/type issues found by the first workspace compiler pass. (2026-08-25)
- [x] M3: update `docs/user/getting-started.md` with the public interpreter and its
      non-production posture. (2026-08-25)
- [x] M3: complete full validation. (2026-08-25; `cabal build all` exits 0,
      `cabal test all -j1` passes all eight suites, and `cabal run en-example` reaches the
      database-free listening message before an intentional Ctrl-C.)
- [x] Complete ADR distillation and write Outcomes & Retrospective. (2026-08-25; durable
      interpreter scope and the production boundary recorded in
      `docs/adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md`.)


## Surprises & Discoveries

- 2026-08-25: the original plan described the eight-operation `TupleStore` that existed on
  2026-07-07. The effect now has fourteen constructors. Plans 39, 45, 46, 48, 50, 53, and 60
  added point probes, touch semantics, atomic preconditions, bulk/filter operations, a net
  changelog, and a monotone garbage-collection horizon. Evidence: the constructors in
  `en-core/src/En/Effect/TupleStore.hs` now run from `ReadObjectRelation` through
  `ReapDeletedTuples`; plan 45 is complete rather than unimplemented.

- 2026-08-25: `En.Conformance.Kikan.runTupleStoreInMemory` is no longer read-only. Plan 45
  made it a pure stateful touch store, but it still deliberately has no historical revisions,
  stable row identities across mutations, or real reaping. It remains useful for conformance
  fixtures and does not satisfy this plan's snapshot-store purpose.

- 2026-08-25: `en-core/test/Main.hs` is a plain assertion executable, not a Tasty tree. The
  refreshed validation names assertion labels visible on failure rather than promising a
  nonexistent test-group listing.

- 2026-08-25: baseline `nix develop -c cabal test en-core` exits 0. Both `en-core-conformance`
  and `en-core-interface-tests` pass; the latter reports an existing incomplete-pattern
  warning in an unrelated inline test interpreter.

- 2026-08-25: the first M1 build reached `En.Store.InMemory` and failed because the explicit
  `En.Effect.TupleStore` import list omitted `TupleChange` while the implementation referred
  to it qualified. This is an import-list correction, not a design change.

- 2026-08-25: the first M2 compiler pass rejected two record updates of `Tuple.subject`
  because this test module imports several records with a `subject` field. The pagination
  fixture now constructs `Tuple` positionally, matching the module's existing ambiguity
  avoidance for `RelationshipFilter`.

- 2026-08-25: the first M3 workspace build reached `en-example/app/Main.hs` and could not
  infer the `Error` effect's error type around the polymorphic `runInMemoryStores`. The
  startup and test seeds now specify `runErrorNoCallStack @EnError`, as the core tests do.

- 2026-08-25: the first full test build found the monomorphism restriction on a local
  `tupleStore = runTupleStoreInMemory world` binding in `en-example/test/Main.hs`; the
  rank-n interpreter could not be passed to `mkEnv` twice. Applying the interpreter at each
  call site preserves its required polymorphism.

- 2026-08-25: after the example test compiled and passed, parallel `cabal test all` failed
  only because `en-biscuit-tests` reported `authorization rejected: Timeout` while the
  PostgreSQL integration suite ran concurrently. All other suites, including `en-example`,
  passed. The `-j1` rerun removed suite contention and passed.

- 2026-08-25: the serial rerun confirms contention rather than regression: all eight suites
  pass under `nix develop -c cabal test all -j1`, including `en-biscuit-tests` and the
  PostgreSQL integration suite. The example smoke run prints `en-example listening on :8080`
  and its Alice grant message without opening a database connection.

- 2026-08-25: this repository has no `just check-adr` recipe and `docs/adr` is not a
  profile-governed OKF bundle. ADR 3 therefore follows the frontmatter and section convention
  of ADRs 1 and 2 and is checked by the repository's ordinary formatting/diff validation.


## Decision Log

- Decision: keep the new interpreter in `en-core` as `En.Store.InMemory`, and leave
  `En.Conformance.Kikan` unchanged.
  Rationale: the public store is useful to embedders and demos, while Kikan's pure fixture
  contract and fixed-data call sites remain independently useful. A new package would add
  deployment and dependency surface for one module that uses only dependencies already in
  `en-core`.
  Date: 2026-07-07; confirmed 2026-08-25.

- Decision: make `InMemoryWorld` opaque and have `newInMemoryWorld :: IO InMemoryWorld`,
  rather than exporting its `IORef` representation.
  Rationale: callers need a shared handle, not the ability to violate row-id, revision, or GC
  invariants. The original draft exposed `IORef InMemoryWorld`; today's broader atomic write
  contract makes representation hiding materially safer without reducing test ergonomics.
  Date: 2026-08-25.

- Decision: use monotonically increasing `Word64` revisions and row ids. Revisions encode as
  `mem:<world-id>:<counter>` and row cursors as `mem-row:<row-id>`.
  Rationale: one process has a genuine total order. A per-world id lets token validation reject
  a token from a different in-memory world, while stable row ids make keyset pagination immune
  to interleaved writes. The distinct prefixes make a PostgreSQL token or cursor fail loudly.
  Date: 2026-08-25, superseding the draft's world-agnostic `mem:<counter>` token.

- Decision: implement the complete current `TupleStore` effect and mirror production-visible
  semantics: atomic preconditions, deletes-before-writes, last-write-wins request deduplication,
  touch identity `(object, relation, subject)`, snapshot visibility, relationship filters, and
  net live-set changes in `(start,end]`.
  Rationale: tests using the public interpreter must not pass because an operation is a
  placeholder or because it follows the obsolete pre-plan-45 insert semantics.
  Date: 2026-08-25, superseding the 2026-07-07 plain-insert decision.

- Decision: one successful mutating request advances the revision once, including an empty or
  no-op request; a failed precondition advances nothing. All mutation is one
  `atomicModifyIORef'`.
  Rationale: this matches the production transaction boundary and makes concurrent test
  threads observe whole requests rather than partially applied batches.
  Date: 2026-08-25.

- Decision: `MinimizeLatency` and `FullyConsistent` resolve to head;
  `AtLeastAsFresh` resolves to the larger of head and the validated token revision; and
  `AtExactSnapshot` resolves to the validated token revision. `DecodeToken` checks structure,
  `ValidateToken` checks world identity and retained history, and `MintToken` only accepts a
  revision belonging to the world.
  Rationale: this preserves each current consistency mode's observable promise in the store's
  total-order model and mirrors the production separation between decode and validate.
  Date: 2026-08-25.

- Decision: `AdvanceGcHorizon` raises an in-memory high-water mark to head.
  `ReapDeletedTuples h` removes rows deleted strictly before `h` and atomically raises the
  high-water mark to at least `h`; validation expires older tokens.
  Rationale: strict-before matches PostgreSQL's `deleted_xid < horizon` rule. Raising the mark
  during direct reap keeps this test store sound even when a test invokes the public primitive
  without first following the production background worker's advance-then-reap sequence.
  Date: 2026-08-25.

- Decision: document the interpreter in the repository-local
  `docs/user/getting-started.md`, not the separate en-docs checkout named by the old draft.
  Rationale: en now has a maintained user-guide corpus in this repository, so the public module
  and its exact versioned API can be documented and committed atomically with the code.
  Date: 2026-08-25.

- Decision: no ADR is required at refresh time.
  Rationale: `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md` concerns
  migration ownership and `docs/adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md`
  concerns the cryptography dependency closure. Neither governs a test-only interpreter, and
  this plan does not change the production storage boundary.
  Date: 2026-08-25.

- Decision: distill the public interpreter's durable scope and production exclusion into
  `docs/adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md`.
  Rationale: the initial refresh did not alter production architecture, but the completed
  implementation establishes a lasting public interpreter and a deliberate server boundary.
  Future `TupleStore` changes must know which semantics this interpreter mirrors, and future
  deployment work must preserve the prohibition on selecting it in `en-server`.
  Date: 2026-08-25.


## Outcomes & Retrospective

ExecPlan 58 achieved its user-visible purpose. `en-core` now exports an opaque
`InMemoryWorld` and paired mutable interpreters that implement all fourteen current
`TupleStore` operations with historical row visibility, per-world tokens, stable row-id
cursors, atomic touch/precondition semantics, relationship filters, net changelog reads, and
a retained-history horizon. The core test suite proves a grant written through `writeTuples`
changes both `check` and `lookup`, deletion reverses the decision at head, and the earlier
exact snapshot remains truthful until reaping.

`en-example` no longer passes a prebuilt list into the Kikan fixture. Startup creates a world,
seeds Alice's grant through the public write effect, and reaches its listener without
PostgreSQL. `docs/user/getting-started.md` now shows the same current effectful API and states
the test/demo-only boundary. `En.Conformance.Kikan` remains unchanged.

Validation completed with `cabal build all`, `cabal haddock en-core`, serial
`cabal test all -j1` across all eight suites, `git diff --check`, and a live example smoke
start. Parallel `cabal test all` exposed an existing resource-sensitive `en-biscuit` timeout;
the serial run proved it was contention and not a behavior regression.

The main lesson was that the July draft could not safely be implemented literally after seven
subsequent storage plans landed. Refreshing first changed the work from an obsolete
eight-operation, plain-insert fake into a complete interpreter of today's contract. The
remaining follow-up is external: the Shōmei integration plan can replace its bespoke store
with this one, but that repository was intentionally not edited here.


## Context and Orientation

en is a Haskell relationship-based authorization toolkit. A `Tuple` in
`en-core/src/En/Tuple.hs` says that a subject has a named relation on an object. A
`Revision` in `en-core/src/En/Revision.hs` names a snapshot. A `ConsistencyToken` is the
opaque value returned after a write and accepted by later reads for read-your-writes.

`en-core/src/En/Effect/TupleStore.hs` is the full storage port. Snapshot reads return
`TupleRow`s carrying a stable `TupleRowId`, `createdAt`, and optional `deletedAt`. Mutation
flows through `ApplyTupleWrites`, whose `TupleWriteRequest` checks preconditions, applies
deletes, then applies writes atomically. Writes have touch semantics: a live tuple's identity
is its object, relation, and subject; the caveat is replaceable data. Operator-facing
operations read, count, or delete a validated `RelationshipFilter`. `ReadChanges` reports the
net difference between the live sets at two revisions. The final operations read revisions
and maintain the garbage-collection horizon.

`en-core/src/En/Effect/ConsistencyStore.hs` decodes and validates tokens, resolves the four
`Consistency` modes, and mints tokens for read responses. The PostgreSQL reference behavior is
in `en-postgres/src/En/Postgres/TupleStore.hs` and
`en-postgres/src/En/Postgres/Revision.hs`. The implementation uses `effectful`'s dynamic
`interpret_`; Mori locates that dependency at `mori://effectful/effectful`, with source at the
registered `effectful/effectful` repository. No new dependency or bound is needed.

`en-core/src/En/Conformance/Kikan.hs` remains the pure conformance fixture. The new module is
an IO-backed historical store. `en-core/test/Main.hs` is one assertion executable whose
`main` calls focused test functions. `en-example/src/En/Example/Host.hs` defines a small
embedded host and `en-example/app/Main.hs` currently seeds it by passing a fixed tuple list to
Kikan's interpreter; milestone 3 replaces that startup path with `writeTuples` against one
shared world.

The sibling integration work is
`mori://shinzui/shomei/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer`.
The currently released Mori CLI cannot yet resolve that plan-kind URI, but the canonical plan
shape is retained rather than falling back to an ambiguous path. This plan does not edit
Shōmei.

No local ADR is relevant, as recorded in the Decision Log.


## Plan of Work

### Milestone 1 — Complete mutable store interpreters

Create `en-core/src/En/Store/InMemory.hs` and expose it from `en-core/en-core.cabal`. Define an
opaque world containing an `IORef` of historical rows, head revision, next row id, and retained
horizon, plus an immutable per-world identity. Every read first parses its revision and cursor,
then snapshots the world with `readIORef`. A row is visible at revision `r` when
`createdAt <= r` and it has no deletion revision at or before `r`. Page filtered rows in row-id
order and resume strictly after the cursor; `Truncated` is never produced because this store
has no external read deadline.

Implement every current `TupleStore` constructor. `ReadObjectRelation`,
`ReadStartingWithUser`, `ReadAllTuples`, `ProbeTuples`, `ReadRelationships`, and
`CountRelationships` filter the visible row set. `ApplyTupleWrites` checks the preconditions
against the live head, then performs delete-by-key and touch writes at one new revision.
`DeleteRelationships` retires matching live rows at one new revision and returns their count.
`ReadChanges` compares visibility at its two endpoints and emits one `ChangeTouch` or
`ChangeDelete` for each row whose membership differs. Revision and maintenance constructors
follow the Decision Log.

Implement `runConsistencyStoreInMemory` over the same world and expose
`runInMemoryStores` as the normal paired composition. Malformed tokens raise
`MalformedConsistencyToken`, foreign-world tokens raise `InvalidConsistencyToken`, expired
history raises `ConsistencyTokenExpired`, malformed cursors raise `InvalidCursor`, and a
foreign direct `Revision` raises `StoreError`. Put the production warning in the module
Haddock with pointers to `En.Postgres.TupleStore` and `En.Conformance.Kikan`.

At milestone completion, from the repository root run:

```bash
nix develop -c cabal build en-core
nix develop -c cabal haddock en-core
```

Both commands must exit 0 and Haddock must include `En.Store.InMemory`.


### Milestone 2 — Behavioral and engine tests

Add `testMutableInMemoryStore` to `en-core/test/Main.hs` and call it from `main`. Exercise the
public operations, not internal helpers. At minimum assert write/read visibility, delete hiding,
pre-delete exact-snapshot visibility, `AtLeastAsFresh`, stable row-id pagination across an
interleaved write, identical-touch no duplication, differing-caveat replacement, failed
preconditions with no state change, relationship read/count/delete, net changelog behavior,
strict cursor/token failures, and reap counts plus expired old tokens.

In the same test, compile a small schema, run `Check.check` before and after a grant written via
`writeTuples`, and run `Lookup.lookup` at `FullyConsistent` to observe the written object. Delete
the grant and assert the check returns to `Denied`. This is the executable proof of the purpose.

Run:

```bash
nix develop -c cabal test en-core
```

The command must exit 0. A regression should fail with one of the new descriptive assertion
labels, such as `mutable store: exact snapshot survives delete`.


### Milestone 3 — Example and user guide

Replace `En.Example.Host`'s Kikan alias with imports from `En.Store.InMemory`. Keep its injected
interpreter shape so the existing failure-path tests remain possible, but make
`en-example/app/Main.hs` allocate one world and seed `viewerTuple "doc1" alice` by running
`writeTuples` through `runInMemoryStores`. Update `en-example/test/Main.hs` similarly. The
executable must still say that Alice can read `/documents/doc1`, now because startup exercised
the real mutable write path.

Update `docs/user/getting-started.md` so its embedded example uses `newInMemoryWorld`,
`runInMemoryStores`, `writeTuples`, and `check` with the current effect API. State beside the
snippet that the interpreter is for tests and demos only and that production uses
`en-postgres`.

Run:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
```

Both must exit 0. A short timeout smoke run of `cabal run en-example` must reach the listening
message without requiring PostgreSQL; the timeout may terminate the server after startup.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/en`. Use `nix develop -c` so the checked-in
development environment selects the expected compiler and package set.

After each milestone, update Progress, Surprises & Discoveries, and Decision Log before making a
Conventional Commit. Every commit carries both trailers:

```text
ExecPlan: docs/plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md
Intention: intention_01kx20y2tyeem9wat59b32ke7g
```

Before declaring completion, inspect `git diff --check`, run the complete validation above,
write Outcomes & Retrospective, and repeat the ADR distillation described by `agents/skills/exec-plan/ADR.md`.


## Validation and Acceptance

The feature is accepted when a developer can create an `InMemoryWorld`, run an effect program
through `runInMemoryStores`, and observe all of these behaviors without PostgreSQL:

1. A check is denied before a grant, allowed after `writeTuples`, and denied after
   `deleteTuples` at `FullyConsistent`.
2. `AtExactSnapshot` at the write token still sees the grant after its deletion.
3. A multi-page read neither repeats nor skips old rows when a write occurs between pages.
4. Atomic writes honor touch identity and preconditions, filter operations mutate exactly their
   matching live set, changelog reads describe net membership changes, and reaping expires only
   snapshots older than the raised horizon.
5. A token from another in-memory world and a non-`mem-row:` cursor fail through typed
   `EnError`s rather than silently producing a result.
6. `en-example` reaches its listening state without a database after seeding its grant through
   the public write effect.

The authoritative commands are:

```bash
nix develop -c cabal build all
nix develop -c cabal haddock en-core
nix develop -c cabal test all
git diff --check
```


## Idempotence and Recovery

The changes are source-only and additive. Builds, tests, Haddock, and the example seed may be run
repeatedly. Each example process creates a fresh world, so repeated startup cannot accumulate
rows. No database, migration, network service, or external repository is mutated. If a milestone
fails, keep the last working milestone committed and resume from the first unchecked Progress
item; do not replace or weaken the Kikan fixture to make the new tests pass.


## Interfaces and Dependencies

`En.Store.InMemory` exports:

```haskell
data InMemoryWorld

newInMemoryWorld :: IO InMemoryWorld

runTupleStoreInMemory
  :: (IOE :> es, Error EnError :> es)
  => InMemoryWorld
  -> Eff (TupleStore : es) a
  -> Eff es a

runConsistencyStoreInMemory
  :: (IOE :> es, Error EnError :> es)
  => InMemoryWorld
  -> Eff (ConsistencyStore : es) a
  -> Eff es a

runInMemoryStores
  :: (IOE :> es, Error EnError :> es)
  => InMemoryWorld
  -> Eff (ConsistencyStore : TupleStore : es) a
  -> Eff es a
```

The implementation depends only on `base`, `containers`, `effectful`, `effectful-core`, and
`text`, all already present in `en-core/en-core.cabal`. No dependency bounds change. Mori's
local dependency record for the only non-platform API consulted is
`mori://effectful/effectful`; the implementation follows the repository's existing
`interpret_` patterns, verified against that registered source.


Revision note (2026-08-25): refreshed the pre-implementation plan after plans 39, 45, 46, 48,
50, 53, and 60 expanded the store contract. The revision replaces obsolete plain-insert and
eight-operation assumptions with the complete current effect, changes the world to an opaque
handle with per-world tokens, moves documentation into this repository, corrects the test
harness description, records the green baseline, and canonicalizes the Shōmei plan reference.
