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

en's storage boundary is the `TupleStore` effect
(`en-core/src/En/Effect/TupleStore.hs`): eight operations covering snapshot reads
(`ReadObjectRelation`, `ReadStartingWithUser`), writes and deletes that return a
`ConsistencyToken`, revision queries (`HeadRevision`, `OptimizedRevision`), and
garbage-collection maintenance (`OldestRetainedXid`, `ReapDeletedTuples`). Two
interpreters exist today: the production PostgreSQL interpreter
(`en-postgres/src/En/Postgres/TupleStore.hs`) and a deliberately *read-only* conformance
fixture, `En.Conformance.Kikan.runTupleStoreInMemory`
(`en-core/src/En/Conformance/Kikan.hs`), which evaluates reads against a fixed pure list
and answers `WriteTuples`/`DeleteTuples` with dummy tokens without storing anything.

That leaves a hole: anyone who embeds en and wants to test their authorization wiring —
or run a databaseless demo — has no interpreter that *remembers writes*. The gap is not
hypothetical. en's own example host works around it (`en-example/src/En/Example/Host.hs`
threads pre-built tuple lists), and the sibling project Shōmei's integration plan
(`shomei/docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`,
in `/Users/shinzui/Keikaku/bokuno/shomei`) ships its own bespoke `IORef`-backed
interpreter precisely because en does not provide one, and lists this plan's deliverable
as external companion work it will migrate onto.

After this plan, en-core exports `En.Store.InMemory` with a pair of interpreters —
`runTupleStoreInMemory` over a mutable world and a matching
`runConsistencyStoreInMemory` — such that this program works with no database:

```haskell
world <- newInMemoryWorld
runEff . runInMemoryStores world $ do
  token <- writeTuples [Tuple projectRef (RelationName "editor") (SubjectId alice) Nothing]
  -- a check through the ordinary engine now sees the write:
  decision <- check graph checkRequest{consistency = AtLeastAsFresh token}
  ...
```

Writes are visible to subsequent reads, deletes hide tuples, snapshot reads at an older
revision still see the pre-delete state (honest `AtExactSnapshot` semantics), and the
maintenance operations behave sensibly. The module's haddock states loudly what this is
**not**: a production store. Authorization data must survive restarts and agree across
instances, and en's consistency guarantees are grounded in PostgreSQL's
`pg_snapshot`/xid8 machinery (`en-postgres/src/En/Postgres/Revision.hs`) that a
process-local counter only imitates within a single process. The target users are test
suites, examples, and demos — the same posture as Shōmei's `Shomei.Effect.InMemory`,
which this design copies on purpose (one `World` record in an `IORef`, per-effect
interpreters reading through it).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `En.Store.InMemory` module with `InMemoryWorld`, `newInMemoryWorld`,
      `runTupleStoreInMemory`, `runConsistencyStoreInMemory`, and the combined
      `runInMemoryStores`; compiles and is exported from `en-core.cabal`.
- [ ] M1: production-non-goal haddock written on the module header (restating the
      Purpose section's reasons).
- [ ] M2: unit tests in `en-core/test/Main.hs` covering write-then-read visibility,
      delete hiding, snapshot isolation at `AtExactSnapshot`, `AtLeastAsFresh`
      resolution, pagination/cursor stability under interleaved writes, and
      reap-after-delete.
- [ ] M2: engine-level test: `check` and `lookup` run end-to-end over the in-memory
      stores with tuples written through `writeTuples` (not fixture lists).
- [ ] M3: `en-example` host migrated from pre-built lists to the new store, proving the
      write path in a runnable demo; conformance fixture (`En.Conformance.Kikan`) left
      untouched.
- [ ] M3: docs touch: `en-docs` embedding page (or the module haddock, if no page fits)
      mentions the interpreter and its test/demo-only posture; note left for Shōmei's
      plan 47 that the upstream interpreter now exists.
- [ ] Living sections of this plan updated; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The module lives in **en-core** (new module `En.Store.InMemory`), not a
  separate package and not `En.Conformance`.
  Rationale: en-core already hosts the read-only fixture and has zero heavy
  dependencies; a separate package would burden every consumer's build for one module.
  `En.Conformance.Kikan` stays exactly as it is — it is a *fixture* (fixed data, fixed
  schema) with different guarantees, and the conformance suite must not silently start
  depending on mutation. The name `En.Store.InMemory` mirrors the effect it interprets
  rather than a test-suite location, because demos (not just tests) consume it.
  Date: 2026-07-07

- Decision: Revisions are a **monotonic `Int` counter** encoded through the existing
  opaque `Revision`/`ConsistencyToken` `Text` wrappers (e.g. `Revision "mem:42"`), with
  visibility rules `createdAt <= r && (deletedAt == Nothing || deletedAt > r)`.
  Rationale: within one process writes are genuinely totally ordered, so a counter gives
  *honest* snapshot semantics rather than pretending at xid8 arithmetic. The `mem:`
  prefix makes tokens self-describing and unambiguously non-PostgreSQL, so a token that
  leaks across store kinds fails decoding loudly instead of resolving to nonsense.
  Date: 2026-07-07

- Decision: Write semantics match the **current** PostgreSQL interpreter: plain
  insert-per-tuple in one revision (`writeTuplesSession`,
  `en-postgres/src/En/Postgres/TupleStore.hs` ~158-166), no touch/upsert behavior.
  Plan 45 (`docs/plans/45-adopt-touch-semantics-for-tuple-writes.md`, unimplemented at
  the time of writing — zero checked progress items) will change tuple identity to
  SpiceDB-style touch semantics; when it lands, its scope must include this interpreter,
  and a note saying so belongs in *its* plan text as part of this plan's M1.
  Rationale: an in-memory store that diverges from the production store's observable
  write behavior would make tests pass that production fails, defeating its purpose.
  Date: 2026-07-07

- Decision: `runConsistencyStoreInMemory` ships in the same module and reads the same
  `InMemoryWorld`, resolving `MinimizeLatency`/`FullyConsistent` to the head counter,
  `AtLeastAsFresh t` to `max(head, decode t)` (which in-process is always `head`), and
  `AtExactSnapshot t` to `decode t`; `DecodeToken` fails with a decode error on tokens
  lacking the `mem:` prefix.
  Rationale: the two effects are meaningless apart — a mutable tuple store consulted at
  revisions no consistency resolver can produce is a foot-gun. Shipping the pair (plus a
  `runInMemoryStores` convenience that installs both) is what makes the module a working
  harness rather than a parts kit.
  Date: 2026-07-07

- Decision: This interpreter is documented as **test/demo-only**, and no configuration
  flag ever selects it in `en-server`.
  Rationale: durability and cross-instance agreement are non-negotiable for
  authorization data; the new-enemy guarantee en exists to provide cannot be honored by
  a process-local store in any multi-instance deployment. Keeping it out of en-server's
  configuration space forecloses the tempting-but-wrong "quick start in production"
  path.
  Date: 2026-07-07

- Decision: Cursors encode the last-seen **row id** (`mem-row:<n>`), not a list index.
  Rationale: the Kikan fixture's index-based cursors are sound over immutable data but
  break under interleaved writes (a new row shifts indices and pages skip or repeat
  rows). Row ids are allocated once and never reused, so resuming a page after a write
  is well-defined: strictly-greater row ids, filtered by the read's snapshot revision.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

en is a Haskell relationship-based authorization (ReBAC) toolkit: hosts define a schema
(object types with relations and permissions), write **relation tuples** ("subject S has
relation R on object O" — `En.Tuple.Tuple` in `en-core/src/En/Tuple.hs`), and ask the
engine questions (`En.Check.check`, `En.Lookup`, `En.Expand`). The engine never touches
storage directly; it sends operations of two `effectful` dynamic effects:

- `TupleStore` (`en-core/src/En/Effect/TupleStore.hs`) — the eight-operation storage
  interface described below. Reads take a `Revision` (an opaque `Text`-wrapped snapshot
  identifier, `en-core/src/En/Revision.hs`) and return a `TuplePage` of `TupleRow`s
  (`rowId :: TupleRowId`, `tuple :: Tuple`, `createdAt :: Revision`,
  `deletedAt :: Maybe Revision` — the store is append-only with soft deletes). Writes
  return a `ConsistencyToken`, the opaque "zookie" a caller can present later to demand
  read-your-writes.
- `ConsistencyStore` (`en-core/src/En/Effect/ConsistencyStore.hs`) — resolves a
  requested `Consistency` (`MinimizeLatency` | `AtLeastAsFresh token` |
  `AtExactSnapshot token` | `FullyConsistent`) to the concrete `Revision` a read uses,
  and decodes/validates tokens (`TokenMetadata` carries revision, datastore id, schema
  hash, expiry).

Interpreters supply meaning: `en-postgres` implements both over PostgreSQL
(`En.Postgres.TupleStore`, `En.Postgres.Revision` — revisions are `pg_snapshot` values,
deliberately only *partially* ordered, which is why `Revision` has no `Ord` instance).
The only in-memory interpretation today is the conformance fixture
`En.Conformance.Kikan.runTupleStoreInMemory` (`en-core/src/En/Conformance/Kikan.hs`): it
pages a fixed `[Tuple]` (`pageTuples`, index-based cursors, every row stamped
`testRevision`, `deletedAt = Nothing`) and answers `WriteTuples`/`DeleteTuples` with
constant tokens (`ConsistencyToken "in-memory-write"`) **without storing anything**. Its
sibling `runConsistencyStoreInMemory` resolves every consistency mode to `testRevision`.
That is exactly right for conformance tests over fixed fixtures and exactly wrong for
anyone testing a write path.

The model to copy is Shōmei's in-memory assembly
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/InMemory.hs`): one
`World` record of maps held in a single `IORef`, one interpreter per effect reading and
atomically modifying it, exported per-port so hybrid stacks can mix real and fake
interpreters. Shōmei ships it explicitly for pure test suites — never production — and
this plan adopts the same posture, stated in the module haddock.

Term of art: **new-enemy problem** — the Zanzibar failure mode where a permission
revocation and a subsequent read race such that stale data is served to a principal who
was just denied. en prevents it with snapshot reads at carefully chosen revisions; an
in-process counter preserves the property within one process and cannot across
processes, which is one of the two reasons (with durability) this store must never back
a real deployment.


## Plan of Work

### Milestone 1 — The module

Create `en-core/src/En/Store/InMemory.hs`, register it in `en-core.cabal`'s
`exposed-modules` (alphabetical placement near `En.Schema` — check the existing list
ordering convention), and implement:

    data InMemoryRow = InMemoryRow
      { rowId     :: !Int
      , tuple     :: !Tuple
      , createdAt :: !Int
      , deletedAt :: !(Maybe Int)
      }

    data InMemoryWorld = InMemoryWorld
      { rows :: !(Seq InMemoryRow)   -- or Map Int InMemoryRow keyed by rowId
      , headCounter :: !Int
      , nextRowId :: !Int
      }

    newInMemoryWorld :: IO (IORef InMemoryWorld)

`runTupleStoreInMemory :: (IOE :> es) => IORef InMemoryWorld -> Eff (TupleStore : es) a -> Eff es a`
interprets (use `atomicModifyIORef'` for every mutation so concurrent test threads are
safe — this was a lesson from Shōmei's suite, whose plain `modifyIORef'` interpreters
needed atomizing for concurrency regression tests):

- `ReadObjectRelation revision object relation limit cursor` — decode the revision
  counter (reject non-`mem:` encodings with the same error channel the Postgres
  interpreter uses for decode failures — `Error EnError` with a `StoreError`; check how
  `interpretTupleStorePostgres`'s `orThrow` constructs it and mirror the constructor);
  filter rows by object+relation and snapshot visibility
  (`createdAt <= r && maybe True (> r) deletedAt`); order by `rowId`; apply the cursor
  (strictly greater `rowId` than `mem-row:<n>`) and `limit`; produce `TuplePage` with
  `Exhausted`/`HasMore` exactly as `pageTuples` does (there is no truncation source in
  memory, so `Truncated` is never produced — say so in a comment).
- `ReadStartingWithUser revision query` — same visibility/paging over the
  `UsersetQuery` filter (type, relation, `subject ∈ querySubjects`), mirroring the
  Kikan fixture's filter at `En/Conformance/Kikan.hs` (`ReadStartingWithUser` case).
- `WriteTuples tuples` — one counter bump for the whole batch (matches the Postgres
  session: one anchored transaction per call, `writeTuplesSession`); append one row per
  tuple with fresh `rowId`s; return `ConsistencyToken ("mem:" <> show newCounter)`. No
  touch/dedup semantics (Decision Log; revisit with en plan 45).
- `DeleteTuples tuples` — bump once; set `deletedAt = Just newCounter` on every *live*
  row whose `tuple` equals a requested tuple; return the token. Deleting an absent
  tuple is a no-op for that tuple (verify the Postgres `deleteTuplesSession` behaves
  this way — read the statement — and match it; record what you find in Surprises if
  it differs).
- `HeadRevision` / `OptimizedRevision` — `Revision ("mem:" <> show headCounter)` (no
  quantization; in memory the optimized revision *is* head — note the comment).
- `OldestRetainedXid` — `0` (no GC window in memory; everything is retained until
  reaped).
- `ReapDeletedTuples horizon` — hard-drop rows with `deletedAt <= horizon` (decode the
  `Word64` against the counter), returning the count dropped — enough to test that
  reaping is wired, without simulating xid arithmetic.

`runConsistencyStoreInMemory :: (IOE :> es, Error EnError :> es) => IORef InMemoryWorld -> Eff (ConsistencyStore : es) a -> Eff es a`:

- `DecodeToken t` — parse `mem:<n>`; failure throws the same token-decode `EnError` the
  Postgres consistency store throws (find it in `en-postgres`'s consistency module and
  reuse the constructor); success returns `TokenMetadata` with
  `DatastoreId "in-memory"`, the world's schema-agnostic `SchemaHash "in-memory"`, and
  `expiresAt = Nothing`. (If `ValidateToken`'s production implementation checks
  datastore/schema identity, mirror the shape but validate only the prefix — document
  the difference in the haddock.)
- `ResolveConsistency` — per the Decision Log: head for
  `MinimizeLatency`/`FullyConsistent`; `AtLeastAsFresh` = head (in-process, head
  dominates every issued token — comment why); `AtExactSnapshot t` = `decode t`.

`runInMemoryStores` composes both over one world. Module haddock: the production
non-goal, verbatim reasons (durability, cross-instance agreement, xid8-grounded
new-enemy guarantee), pointer to `en-postgres` for real deployments, pointer to
`En.Conformance.Kikan` for fixed-fixture conformance runs.

Acceptance: `cabal build en-core` succeeds; haddock renders
(`cabal haddock en-core`).

### Milestone 2 — Tests

Extend `en-core/test/Main.hs` (study its existing tasty structure and group naming
before adding) with a `Store.InMemory` group:

1. write → `ReadObjectRelation` at the returned token's revision sees the tuple.
2. delete → read at post-delete head does not see it; read `AtExactSnapshot` at the
   pre-delete token still does (snapshot isolation).
3. `AtLeastAsFresh` after a write resolves to a revision that sees the write.
4. Pagination: write 5 tuples on one object/relation, page with `limit = 2`; then
   interleave a write between pages and assert no row is skipped or repeated
   (rowId-cursor stability — the reason index cursors were rejected).
5. `ReapDeletedTuples` drops exactly the soft-deleted rows at/below the horizon and
   subsequent reads are unchanged (they were already invisible).
6. Engine end-to-end: build a small schema with `En.Schema.Builder` (the
   `en-example/src/En/Example/Host.hs` builder usage is the template), compile with
   `compileSchema`, run `check` over the in-memory stores where the granting tuple
   arrives via `writeTuples` mid-test: denied before, permitted after, denied again
   after `deleteTuples` with `FullyConsistent`.

Acceptance: `cabal test en-core` green; the new group visible in the tasty tree.

### Milestone 3 — Consumers and docs

Migrate `en-example`'s host (`en-example/src/En/Example/Host.hs`) from fixed tuple
lists to `En.Store.InMemory`, adding a small write path to the demo so the example
exercises mutation (follow its existing route conventions; keep the schema unchanged).
The conformance fixture and suite are deliberately untouched.

Docs: add the interpreter to whatever en-docs page introduces embedding/interpreters
(search `/Users/shinzui/Keikaku/bokuno/en-docs/content/docs/` for the page that
currently mentions interpreters or the example host; if none fits, the module haddock
is the documentation of record and en-docs gets a one-paragraph mention on the example
page). State the test/demo-only posture wherever it is mentioned. Finally, note in the
plan's Outcomes that Shōmei's
`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`
(External Companion Work, in the shomei repo) can now consume this interpreter instead
of its bespoke one — do not edit the shomei repo from this plan.

Acceptance: `cabal build all && cabal test all` green in the en repo;
`cabal run en-example` (or its documented invocation — check the package's executable
stanza) demonstrates a write followed by a permitted check.


## Concrete Steps

All commands run from the en repository root, `/Users/shinzui/Keikaku/bokuno/en`,
inside its dev shell (`nix develop`).

```bash
nix develop
cabal build en-core                 # after M1
cabal haddock en-core               # haddock must render the new module
cabal test en-core                  # after M2
cabal build all && cabal test all   # after M3
```

Expected test excerpt after M2 (names indicative; match the suite's real convention):

```text
en-core
  Store.InMemory
    write-then-read visibility:        OK
    delete hides at head:              OK
    at-exact-snapshot sees pre-delete: OK
    cursor stable under writes:        OK
    reap drops soft-deleted:           OK
    engine check over mutable store:   OK
```

Commit after each milestone with the trailer:

```text
ExecPlan: docs/plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md
```


## Validation and Acceptance

The plan is done when a developer with no database can, in `ghci` or a test, create a
world, write a tuple, and watch a `check` flip from denied to permitted — and when
reverting the grant with `deleteTuples` under `FullyConsistent` flips it back. The
milestone-2 engine test is the executable form of that sentence. Additionally:
`grep -rn "runTupleStoreInMemory" en-core/src` shows both the Kikan fixture and the new
module (they intentionally share a function name in different modules — if that
collides for a consumer importing both, qualify at the import; do NOT rename the Kikan
one, the conformance suite and external references depend on it — reconsider and record
in the Decision Log if this proves too confusing during implementation); the module
haddock contains the words "not a production store"; en-example runs without PostgreSQL.


## Idempotence and Recovery

Every step is additive and re-runnable: the module and tests can be rebuilt repeatedly;
`en-example`'s migration is a self-contained diff revertible with git. No migrations, no
data, no external services are touched. If milestone 3's example migration stalls, the
module + tests (M1-M2) stand alone and should be committed as such.


## Interfaces and Dependencies

New module `En.Store.InMemory` in en-core, depending only on existing en-core modules
(`En.Effect.TupleStore`, `En.Effect.ConsistencyStore`, `En.Revision`, `En.Tuple`,
`En.Error`) plus `base`/`containers`/`effectful-core` — all already in
`en-core.cabal`'s build-depends; add nothing new. Exports at end of M1:

    data InMemoryWorld
    newInMemoryWorld        :: IO (IORef InMemoryWorld)
    runTupleStoreInMemory   :: (IOE :> es, Error EnError :> es) => IORef InMemoryWorld -> Eff (TupleStore : es) a -> Eff es a
    runConsistencyStoreInMemory :: (IOE :> es, Error EnError :> es) => IORef InMemoryWorld -> Eff (ConsistencyStore : es) a -> Eff es a
    runInMemoryStores       :: (IOE :> es, Error EnError :> es) => IORef InMemoryWorld -> Eff (ConsistencyStore : TupleStore : es) a -> Eff es a

(Exact constraint rows must be confirmed against the effect stacks the engine
functions demand — read `En.Check.check`'s signature and the Postgres interpreters'
constraints before committing to these; adjust and record deviations in the Decision
Log.) Consumers after M3: `en-core` tests, `en-example`; external (not this plan's
scope): Shōmei's `examples/embedded-with-en` per its plan 47.
