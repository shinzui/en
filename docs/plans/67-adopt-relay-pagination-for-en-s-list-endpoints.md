---
id: 67
slug: adopt-relay-pagination-for-en-s-list-endpoints
title: "Adopt Relay pagination for en's list endpoints"
kind: exec-plan
created_at: 2026-08-25T20:39:49Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Adopt Relay pagination for en's list endpoints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`en` has four endpoints that return pages of an unbounded, growing collection:
`POST /v1/lookup` (which objects can this subject reach?), `POST /v1/lookup-subjects` (which
subjects can reach this object?), `POST /v1/relationships/query` (which stored tuples match
this filter?), and `POST /v1/watch` (what has changed since this point?). Each invented its
own paging envelope. `lookup` answers with

```json
{"status":"hasMore","cursor":"eyJ...","objects":[...],"checkedAt":"..."}
```

where `status` is one of `complete`, `hasMore`, or `truncated`, and a client is expected to
resend the `cursor` to continue.

It works, and it is `en`-specific. A generated TypeScript client has no idea that `cursor`
means anything; nothing in the OpenAPI document says these endpoints are pages of the same
collection; and `truncated` — which means "the traversal hit its budget", not "there is more
data" — is a distinction only `en`'s own documentation explains.

The fleet's answer is Relay pagination: a `Connection` envelope with `edges`, `pageInfo`, and
opaque versioned cursors, backed by keyset SQL, with a conformance test proving that walking
the pages skips no row and duplicates none. After this plan a client pages `en` the same way
it pages every other service in the fleet, and the OpenAPI document says so in a shape
client generators already understand.

**This is the one deliberately breaking wire change in its initiative.** Response shapes on up
to four endpoints change, `nagare` decodes some of them, and this plan owns answering that
rather than inheriting an answer from elsewhere.

It is also the plan most likely to need rescoping on contact, for two reasons recorded below:
`en`'s endpoints are POST-with-body rather than GET-with-query, and `en`'s cursors carry a
pinned consistency snapshot that Relay's cursor model does not have a slot for. **Milestone 1
exists to decide, per endpoint, whether the standard applies at all** — and to say so out loud
rather than forcing four endpoints into a shape that fits two of them.


## Progress

- [ ] Milestone 1 — Decide applicability per endpoint. Prove the four `relay-pagination`
      packages resolve against `en`'s pinned closure, read their actual API, and produce a
      written verdict for each of the four endpoints: convert, convert with a recorded
      deviation, or exempt with a reason. Record every verdict in the Decision Log before
      writing any conversion code.
- [ ] Milestone 2 — Make the database order total for each endpoint being converted, adding
      the indexes the keyset queries need as a new append-only migration.
- [ ] Milestone 3 — Convert the first endpoint end to end — route type, handler, hasql keyset
      query, client, OpenAPI — and ship its conformance test. One endpoint, fully done, before
      the others start.
- [ ] Milestone 4 — Convert the remaining endpoints Milestone 1 ruled in, each with its own
      conformance test.
- [ ] Milestone 5 — Record the `RelayPageError` exemption in the problem-details conformance
      test, regenerate `docs/api/openapi.json`, update the Hurl suite's pagination
      assertions, notify consumers, and write the ADR.


## Surprises & Discoveries

- Discovery (2026-08-25, while planning): **every one of `en`'s paginated endpoints is
  `POST`-with-a-body, while `RelayPage` is a query-parameter combinator.** `RelayPage
  (defaultSize :: Nat) (maximumSize :: Nat)` declares the four query parameters `first`,
  `after`, `last`, and `before`, and its `HasServer` instance validates them before the
  handler runs. `en`'s routes look like

  ```haskell
    lookup ::
      mode
        :- "lookup"
          :> ReqBody '[JSON] LookupRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire),
  ```

  and they are `POST` for a real reason: their inputs are a subject, a permission, an object
  filter, a caveat context, and a consistency token — structured data that does not belong in
  a query string. The combinators compose (`RelayPage 20 100 :> ReqBody ... :> MultiVerb
  'POST ...` is legal), so paging arguments would arrive in the query string of a POST while
  the rest of the request arrives in its body. That is unusual and needs to be a recorded
  decision in Milestone 1, not something discovered by whoever reads the OpenAPI document
  later.

- Discovery (2026-08-25, while planning): **`en`'s cursors carry a pinned consistency
  snapshot, and Relay's cursor model has no slot for one.** A Relay `Cursor` is unpadded
  base64url over a `CursorPayload` containing a format version, a 32-bit FNV-1a
  `sortSpecFingerprint` over the column expressions and directions, and a list of typed keys —
  integer, text, UUID, timestamp-microseconds, boolean, or null. `en`'s lookup cursor pins the
  database revision the traversal is reading at, so every page of one traversal carries the
  same `checkedAt` and a continuation reads at the revision its cursor validated. That is a
  correctness property of an authorization service, not an implementation detail: pages of one
  lookup must not straddle a write. Whether it survives as a typed key inside the Relay
  payload, as a separate request field, or as a documented deviation is Milestone 1's
  question, and it is the single most likely reason for this plan to come back smaller than it
  started.

- Discovery (2026-08-25, while planning): **`watch` is probably not a paginated list
  endpoint.** `POST /v1/watch` is a changelog feed: it takes a start point (a cursor or a
  consistency token), returns a batch of tuple changes, and returns a cursor to resume from.
  Its cursor means "resume the stream here", not "the keyset position of row N in a sorted
  collection", and there is no backward direction — `last`/`before` are meaningless on a
  changelog. Forcing it into `Connection` would produce an envelope whose `pageInfo`
  half-lies. Milestone 1 should look hard at exempting it, and if it does, the exemption must
  be recorded with this reasoning rather than left implicit.

- Discovery (2026-08-25, while planning): **`shinzui/relay-pagination` is registered in Mori
  with an `Experimental` lifecycle**, while `servant-health` and the OpenTelemetry packages
  this initiative also adopts are `Active`. The pagination standard itself is unqualified and
  names four released `0.1.x` packages; the local working copy at
  `/Users/shinzui/Keikaku/bokuno/relay-pagination` shows all four at `0.1.1.0`. So the
  standard and the registry disagree about maturity. Milestone 1 re-verifies the released
  versions and the lifecycle before committing, and this plan is sequenced last in its
  initiative precisely so that a bad answer here costs nothing already delivered.

(Add further entries as work proceeds.)


## Decision Log

- Decision: Make applicability a milestone with a written verdict per endpoint, rather than
  assuming all four convert.
  Rationale: the standard's rule is "every list endpoint over an unbounded collection uses
  `RelayPage`", and it means it — `when in doubt, paginate`, because retrofitting a
  `Connection` onto a shipped plain-list endpoint is a breaking change while an unnecessary
  `Connection` costs one wrapper. But that rule is about *whether to paginate*, and `en`'s
  four endpoints already paginate. The open question here is different: whether `en`'s
  existing paging semantics — a pinned consistency revision, a `truncated` outcome distinct
  from `hasMore`, a changelog resume point — survive translation into the Relay model, and for
  which endpoints. Answering that per endpoint, in writing, before converting anything is
  cheaper than discovering mid-conversion that one of them does not fit.
  Date: 2026-08-25

- Decision: Convert one endpoint completely — route, handler, query, client, document, and
  conformance test — before starting the others.
  Rationale: the conversion has six distinct layers, and the unknowns are concentrated in the
  seams between them: how the keyset query expresses `en`'s ordering, whether the consistency
  revision survives, what the conformance harness needs from the handler. Doing one endpoint
  end to end surfaces all of that once, at the cost of one endpoint's rework, rather than four
  times over. The remaining conversions are then mechanical.
  Date: 2026-08-25

- Decision: `en` uses `RelayPageError` for handler-detected cursor rejection too, not only for
  the combinator's pre-handler validation.
  Rationale: the standard requires it, and the reason is that one endpoint must never have two
  different 400 bodies. `en` today rejects a stale or malformed cursor from inside the handler
  — a cursor whose pinned revision has fallen outside the garbage-collection horizon is a
  handler-level judgment, not a parse failure — and that rejection currently produces an `en`
  error envelope. After conversion it produces a `RelayPageError`, so a client has one decoder
  for every 400 the endpoint can answer.
  Date: 2026-08-25

(Add further entries as work proceeds; Milestone 1's four verdicts belong here.)


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC) in the style of
Google Zanzibar. It stores relationship *tuples* — facts like "user:alice is `viewer` of
space:project-x" — and answers questions about them over HTTP. It is built with `cabal` and
GHC 9.12.4 and developed inside a nix shell.

Four of its eight packages matter here. **`en-servant`** owns the HTTP API type and its
vertical slices: `en-servant/src/En/Lookup/Api.hs` holds the lookup routes and
`en-servant/src/En/Tuple/Api.hs` holds the relationship and watch routes. **`en-core`** owns
the engine that produces the pages. **`en-postgres`** owns the hasql queries and would own any
keyset SQL. **`en-migrations`** owns the schema as a `pg-migrate` component.

### Terms used in this plan

**Relay pagination** is a cursor-based paging convention from GraphQL's Relay specification,
here applied to REST. Its envelope is a **`Connection`**: a list of **`Edge`** values (each a
node plus its cursor) and a **`PageInfo`** (whether there are more pages forward or backward,
and the first and last cursors of this page).

**Keyset pagination** — sometimes "seek pagination" — means continuing a query by asking for
rows *after a specific sort key value*, rather than by skipping a count of rows. It requires a
**total order**: a sort specification in which no two rows compare equal, usually achieved by
appending a unique column as the final tiebreaker. Without totality, a page boundary can fall
between two equal rows and a row is skipped or repeated.

**An opaque cursor** is a string a client must treat as a token: store it, send it back,
never decode or compare it. Relay's is unpadded base64url over a payload containing a format
version, a **sort-spec fingerprint**, and the typed key values of the row it points at.

**The sort-spec fingerprint** is a 32-bit FNV-1a hash over each column expression, direction,
and codec tag. Changing any part of the order changes the fingerprint, so old cursors fail as
`invalid_cursor` rather than being silently reinterpreted under the new order. That rejection
is part of safe API evolution, not an availability bug.

**A consistency token** is `en`'s opaque string pinning a database revision. `en` uses one to
guarantee that every page of one traversal reads at the same revision, so a page boundary
cannot straddle a concurrent write.

**`MultiVerb`** is the servant combinator letting one route declare several possible HTTP
statuses as alternatives, mapped onto a Haskell sum by a hand-written **`AsUnion`** instance.

**An RFC 9457 problem document** is the fleet's standard error body under
`application/problem+json`. `RelayPageError` is a **recorded exemption** from it.

### The rule this plan implements

Recorded canonically at
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination` (resolve it with `mori path`;
today it lands at `patterns/api/relay-pagination.md` in the working copy at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`). Restated:

> Every list endpoint over an unbounded collection uses `RelayPage`, returns a `Connection`
> on 200 and a `RelayPageError` on 400 through `MultiVerb`, executes a `SortSpec` keyset
> query, and ships a conformance test proving that no row is skipped or duplicated.
> Offset/limit is not an accepted production pagination contract — if an endpoint paginates
> at all, it paginates this way.

The exemption for a plain list requires **all three** of: the collection is bounded by design
rather than by observation (a hard domain limit that does not grow with tenants, users, or
time); the whole set is the unit of consumption; and the bound is stated in the route's
OpenAPI description. None of `en`'s four endpoints comes close — they are all tenant-scoped
and time-accumulating — so the plain-list exemption is not the escape hatch here. The
questions Milestone 1 asks are different ones, about semantics rather than size.

The four packages, each with a separate job:

```cabal
build-depends:
    relay-pagination             ==0.1.*
  , relay-pagination-servant     ==0.1.*
  , relay-pagination-hasql       ==0.1.*

test-suite en-servant-test
  build-depends:
      relay-pagination-conformance ==0.1.*
```

The core package owns `Connection`, `Edge`, `PageInfo`, `PageRequest`, and opaque cursors. The
servant package owns the route combinator and its 400 wire error. The hasql package owns
keyset SQL and typed sort-key codecs. The conformance package walks a real endpoint in both
directions.

The route shape the standard prescribes:

```haskell
type MemberPageResponses =
  '[ Respond 200 "Page of members" (Connection Member),
     Respond 400 "Invalid pagination" RelayPageError
   ]

data MemberPageResult
  = MemberPageOk !(Connection Member)
  | MemberPageBadRequest !RelayPageError

instance AsUnion MemberPageResponses MemberPageResult where
  toUnion = \case
    MemberPageOk page -> Z (I page)
    MemberPageBadRequest err -> S (Z (I err))
  fromUnion = \case
    Z (I page) -> MemberPageOk page
    S (Z (I err)) -> MemberPageBadRequest err
    S (S impossible) -> case impossible of {}

type ListMembersEndpoint =
  "members"
    :> RelayPage 20 100
    :> MultiVerb 'GET '[JSON] MemberPageResponses MemberPageResult
```

Write `AsUnion` by hand, as `en` already does elsewhere. The combinator rejects non-decimal
sizes, malformed cursors, negative or oversized page sizes, and mixed forward/backward
arguments — and it **rejects** oversize values rather than clamping them. `first` with `last`,
`after` with `before`, `first` with `before`, and `last` with `after` are all invalid.

`RelayPageError` carries `code`, `message`, `retryable`, and `parameter`, with stable codes
`invalid_integer`, `invalid_cursor`, `mixed_pagination_directions`, `negative_page_size`, and
`page_size_too_large`.

Two further obligations. **The database order must be total**, or keyset paging skips or
duplicates rows. And **a conformance test is part of the endpoint** — the standard says an
endpoint without one "is not a paginated endpoint; it is a bug waiting to happen".

Clients must not decode, edit, compare, or persist assumptions about a cursor payload; they
may store and return the opaque string.

### Where `en` stands today

Four endpoints page, all `POST` with a JSON body. From `en-servant/src/En/Lookup/Api.hs`:

```haskell
data LookupRoutes mode = LookupRoutes
  { lookup ::
      mode
        :- "lookup"
          :> ReqBody '[JSON] LookupRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized objects" LookupPageWire) (EnResult LookupPageWire),
    lookupSubjects ::
      mode
        :- "lookup-subjects"
          :> ReqBody '[JSON] LookupSubjectsRequestWire
          :> MultiVerb 'POST '[JSON] (EnResponses "A page of authorized subjects" LookupSubjectsPageWire) (EnResult LookupSubjectsPageWire)
  }
```

and from `en-servant/src/En/Tuple/Api.hs`, `readRelationships` at `"relationships" :>
"query"` and `watch` at `"watch"`, both the same shape.

The page envelope, from `en-servant/src/En/Lookup/Api.hs`, is a three-way status:

```haskell
    LookupCompleteWire        -> ["status" .= "complete"]
    LookupHasMoreWire cursor  -> ["status" .= "hasMore",   "cursor" .= cursor]
    LookupTruncatedWire cursor -> ["status" .= "truncated", "cursor" .= cursor]
```

`truncated` is not `hasMore`. It means the traversal hit its evaluation budget rather than
exhausting the data — a distinction with no counterpart in `PageInfo`, and one Milestone 1
must decide what to do with. Every page of one traversal carries the same `checkedAt`,
because the cursor pins the snapshot and a continuation reads at the revision its cursor
validated.

`en` depends on none of the `relay-pagination` packages today:
`grep -rn "relay-pagination\|RelayPage" --include='*.cabal' --include='*.hs' .` is empty.

### Relevant Architecture Decision Records

`en`'s ADRs live in `docs/adr/` as ordinary Markdown files with frontmatter `title`,
`status`, `date`, `authors`, `related`, and a body headed `# ADR N — <title>`. `mori.dhall`
declares one OKF bundle, `docs/capabilities`, and **none** at `docs/adr`, so the repository's
filesystem convention is authoritative; no OKF frontmatter belongs on an ADR written here.

Two ADRs constrain this plan, and this is the only plan in its initiative constrained by both.

[ADR 1 — en's schema is an append-only pg-migrate component](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md).
Milestone 2 adds indexes so the keyset queries have a total order to seek within. Under ADR 1
that is a **new migration file** in `en-migrations`, never an edit to an existing one:
`pg-migrate` keys applied migrations by file, so editing a file that has already run in any
environment leaves that environment silently divergent. Add `CREATE INDEX` statements as their
own forward migration, and consider `CONCURRENTLY` if the target tables are large enough that
an exclusive lock during migration would matter.

[ADR 2 — crypton 1.1 binds en's dependency closure through a biscuit-haskell fork](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md).
This plan adds **four** packages to a closure already pinned by `pg-migrate`'s
`crypton >= 1.1` and the forked `biscuit-haskell` that requirement forced. The ADR also
records the trap: relaxing a bound alone can let the solver succeed while the compile fails on
a missing instance, so "it solved" is not the acceptance criterion — "it built" is. That is
why Milestone 1 proves the cohort before any conversion work.

[ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md) matters obliquely: the
in-memory store implements the same `TupleStore` effect, so **converting a paginated endpoint
means converting both interpreters**. A keyset query in `en-postgres` with no counterpart in
the in-memory store leaves the demo and test store answering a shape the API no longer
declares.

This plan **owes a new ADR**, per its parent MasterPlan's Integration Points: that `en`'s list
endpoints paginate the Relay way, including the deliberate breaking change and what it costs
`nagare`. Write it in Milestone 5.

### How this plan relates to the others in its initiative

This is a child of
`docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md`,
and it is sequenced **last among the API plans**.

It **hard-depends on**
`docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md`. The
Relay standard defines `RelayPageError` as a *recorded exemption* from the RFC 9457 default —
a paginated endpoint answers 400 with `RelayPageError`, not a problem document, and exempts
those routes by name in the problem-details conformance test. That exemption mechanism is
EP-61's, and there is nothing to exempt yourself from before it exists.

It **soft-depends on**
`docs/plans/66-add-a-hurl-black-box-api-suite-for-en-server.md`. This is the initiative's one
breaking wire change; having a black-box suite already in place means the migration can be
demonstrated against a live server rather than argued from unit tests. Expect to **rewrite**
that suite's pagination assertions here — that is this plan's job, not a defect in EP-66.

`docs/plans/68-migrate-en-s-records-to-generic-lens-label-syntax-and-a-custom-prelude.md`
sweeps the whole tree after this plan lands, so code written here should not try to
anticipate that idiom.

### Build and test commands

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just process-up && just run-migrations && just start-server
just openapi        # regenerates docs/api/openapi.json and fails on drift
just hurl           # the black-box suite, once EP-66 has landed
```


## Plan of Work

### Milestone 1 — Decide, per endpoint, before converting anything

Scope: dependency resolution, reading the packages' real API, and four written verdicts. No
conversion code.

First, prove the cohort resolves. Add the four packages to `en-servant` (and
`relay-pagination-hasql` to `en-postgres`, where the queries live) and build:

```bash
cabal build all
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if "relay" in u.get("pkg-name","")}))'
```

Expect four packages at `0.1.1.0`. If the solver fails, diagnose with `cabal build all -v2`
before touching a bound, per ADR 2.

Second, **re-verify the packages themselves**, because the registry and the standard disagree
about their maturity (see Surprises & Discoveries):

```bash
mori registry show shinzui/relay-pagination --full     # lifecycle: Experimental?
grep -n "^version" /Users/shinzui/Keikaku/bokuno/relay-pagination/*/*.cabal
```

Confirm the local checkout's versions match what the solver resolved before reading its source
as authoritative — a development checkout can sit ahead of its release. If the lifecycle is
still `Experimental`, that is not automatically a blocker, but it is a fact the verdicts below
must weigh and the ADR must record.

Third, read the actual API rather than this plan's summary of it: the `RelayPage` combinator's
`HasServer` instance, the `Connection`/`Edge`/`PageInfo` shapes, `PageRequest`, the
`CursorPayload` and its `KeyValue` sum, and what `relay-pagination-hasql` needs from a
`SortSpec`.

Then write a verdict for **each** of the four endpoints. Each verdict answers three questions
and lands in the Decision Log:

1. **Do the paging arguments belong in the query string of a POST?** `RelayPage` declares
   `first`, `after`, `last`, and `before` as query parameters, and `en`'s requests are
   `ReqBody` on `POST`. The combinators compose, so the answer can be yes — but it produces an
   endpoint whose paging is in the URL and whose filter is in the body, which a reader of the
   OpenAPI document will find surprising. Decide and say why.
2. **What happens to the pinned consistency revision?** `en` guarantees every page of one
   traversal reads at the same revision. Relay's `CursorPayload` holds a format version, a
   sort-spec fingerprint, and typed keys — no snapshot slot. Options: carry the revision as an
   additional typed key inside the payload; keep it in the request body as `en` does today and
   let the Relay cursor carry only the keyset position; or record a deviation. This is the
   question most likely to change the plan's shape.
3. **What happens to `truncated`?** `PageInfo` says whether more pages exist; it does not say
   *why* this page ended. `en`'s `truncated` means the traversal hit its evaluation budget,
   which is operationally different from `hasMore` and which callers are expected to act on
   differently. Decide whether it becomes an extension field beside the `Connection`, a
   distinct status, or is folded into `hasMore` with the distinction lost.

For `watch` specifically, ask a fourth: **is this a list endpoint at all?** It is a changelog
feed whose cursor means "resume the stream here", with no meaningful backward direction — so
`last` and `before` would be declared and never usable. Exempting it is a defensible verdict.
If you exempt it, record the reasoning; if you convert it, record how `PageInfo`'s backward
fields are made honest.

Acceptance: `cabal build all && cabal test all` passes with the four packages present and no
code using them; the resolved versions and the lifecycle finding are recorded in Interfaces
and Dependencies; four verdicts are in the Decision Log; and this plan's Progress section is
updated to reflect the endpoints actually being converted, which may be fewer than four.

### Milestone 2 — A total order, and the migration that supports it

Scope: `en-migrations` (a new migration file) and the query planning for each endpoint ruled
in.

Keyset pagination requires a **total** order: a sort specification in which no two rows
compare equal. If two rows tie on every sort column, a page boundary can fall between them and
one is skipped or repeated — which is exactly what the conformance test in Milestone 3
detects, and which is much cheaper to prevent than to debug.

For each converted endpoint, write down the sort specification explicitly, ending in a column
guaranteed unique within the result set, and confirm an index exists that matches it —
same columns, same directions, same leading order. A keyset query without a matching index
degrades to a sort of the whole result set on every page, which is a performance cliff that
appears only under real data volume.

Add the indexes as a **new** migration in `en-migrations`, never by editing an existing one.
[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md) is explicit:
`pg-migrate` keys applied migrations by file, so editing a file that has already run leaves
that environment silently divergent. Consider `CREATE INDEX CONCURRENTLY` if an exclusive lock
during migration would matter at the target's data volume — and note that `CONCURRENTLY`
cannot run inside a transaction, so check how `pg-migrate` wraps migration files before
relying on it.

Then verify with `EXPLAIN` against a table with enough rows to make the planner honest that
the keyset query uses the index rather than sorting. A few hundred rows will not show you
this; seed enough that a sequential scan is not the cheapest plan anyway.

Acceptance: `just run-migrations` applies cleanly on a fresh database and is a no-op on an
already-migrated one; `EXPLAIN` shows an index scan for each keyset query, with the transcript
recorded in Surprises & Discoveries; the sort specification for each endpoint is written down
in this plan.

### Milestone 3 — One endpoint, all the way through

Scope: one endpoint — `POST /v1/relationships/query` is the natural first choice, because it
reads stored rows directly rather than running a graph traversal, so it has no `truncated`
case and no budget semantics to reconcile. Confirm that choice against Milestone 1's verdicts.

Six layers, in order.

**The route type**, in `en-servant/src/En/Tuple/Api.hs`: a response list of
`Respond 200 "..." (Connection RelationshipWire)` and
`Respond 400 "Invalid pagination" RelayPageError`, a two-constructor result sum, and a
**hand-written** `AsUnion` — including the exhaustiveness witness clause
(`S (S impossible) -> case impossible of {}`) that makes growing the list a compile error.

**The handler**: takes the validated `PageRequest` the combinator produces and returns a
`Connection`. Handler-detected cursor rejection — a cursor whose pinned revision has fallen
outside the garbage-collection horizon, which is a judgment the combinator cannot make —
returns `RelayPageError` with the `invalid_cursor` code, **not** an `en` problem document, so
the endpoint has exactly one 400 body.

**The query**, in `en-postgres`: a `SortSpec` keyset query through `relay-pagination-hasql`,
using the total order from Milestone 2.

**The in-memory interpreter**: the same effect has a second implementation
([ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md)), and leaving it
behind means the demo store answers a shape the API no longer declares. Converting it is part
of this milestone, not a follow-up.

**The client**, in `en-client`: the generated client's result type changes shape with the
route.

**The conformance test**, from `relay-pagination-conformance`, which walks the real endpoint in
both directions and proves no row is skipped or duplicated. The standard is blunt that an
endpoint without this is not a paginated endpoint. Seed enough rows that pages actually
boundary — a dataset smaller than one page proves nothing — and include rows that tie on the
primary sort column, because ties are exactly what a non-total order gets wrong.

Acceptance: `cabal build all && cabal test all` passes; the conformance test is green; a live
`curl` of the endpoint returns a `Connection` with `edges` and `pageInfo`; following
`pageInfo`'s end cursor returns the next page with no overlap; a deliberately corrupted cursor
returns `400` with `application/json` and code `invalid_cursor`.

### Milestone 4 — The remaining endpoints

Scope: whichever of `lookup`, `lookup-subjects`, and `watch` Milestone 1 ruled in.

Each repeats Milestone 3's six layers, and each gets its **own** conformance test — the
harness proves one endpoint, so a shared test proves one endpoint and gives false confidence
about the others.

The graph-traversal endpoints (`lookup`, `lookup-subjects`) are where Milestone 1's `truncated`
verdict gets exercised for real. Implement whatever that verdict said, and if it turns out not
to work, **amend the verdict in the Decision Log** rather than quietly doing something else;
the whole value of Milestone 1 is that the reasoning is written down where the next reader
finds it.

Acceptance: `cabal build all && cabal test all` passes; each converted endpoint has its own
green conformance test; `just openapi` reflects every converted route.

### Milestone 5 — Exemption, document, consumers, ADR

Scope: `en-servant/test/Main.hs`, `docs/api/openapi.json`, the Hurl suite, and `docs/adr/`.

Record the `RelayPageError` exemption in the problem-details conformance test created by
`docs/plans/61-...`'s Milestone 6. Exempt the converted routes **by name** — never a prefix or
a predicate that could silently grow to cover a real endpoint — and justify it in the Decision
Log, as the standard requires of every exemption. The justification is that `RelayPageError`
is a released wire contract that predates and outranks the fleet default, and that one
endpoint must never have two different 400 bodies.

Regenerate the document as its own commit and **read** the diff:

```bash
cabal run en-openapi
just openapi
```

Update the Hurl suite's pagination assertions to the `Connection` shape, and add the
boundary-failure cases the standard names: a negative page size (`negative_page_size`), an
oversize page size (`page_size_too_large` — the combinator rejects rather than clamps), and
mixed directions (`mixed_pagination_directions`).

Then handle consumers, which is this plan's distinctive obligation. `kikan-en` imports only
`app`, `Env`, and `AppEffects` from `En.Servant.API` and `En.Servant.Seam`, so it never names
a page type and cannot break. **`nagare` is different**: it pins `en` by a
`source-repository-package` git tag and decodes responses. Find out which of the converted
endpoints it calls, and say so here — with evidence, not assumption. Whether `nagare` is
updated in the same change, pinned to the pre-migration tag until it can be, or already stale
for unrelated reasons is a decision this plan owns and must record.

Finally the ADR: `en`'s list endpoints paginate the Relay way; what that cost; which endpoints
were exempted and why; how the pinned consistency revision is carried; and the
`Experimental` lifecycle finding from Milestone 1. Follow the existing convention —
`docs/adr/000N-<slug>.md`, frontmatter `title`, `status: accepted`, `date`,
`authors: [shinzui]`, `related:` naming this plan and `mori://shinzui/relay-pagination`; body
headed `# ADR N — <title>` with `## Status`, `## Context`, `## Decision`, `## Consequences`.
No OKF frontmatter.

Acceptance: `cabal test all` passes with the exemption present and nothing else newly
exempted; `just openapi` clean; `just hurl` green with the new assertions; the consumer
finding is recorded; the ADR exists.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix development shell. Baseline first
— if these do not pass before you start, fix that before blaming your own changes:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi        # must be clean before you start
```

Milestone 1 is reading and deciding, not editing. Resolve the cohort, then read the packages
and the endpoints together:

```bash
$EDITOR en-servant/en-servant.cabal en-postgres/en-postgres.cabal
cabal build all
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if "relay" in u.get("pkg-name","")}))'

mori registry show shinzui/relay-pagination --full          # lifecycle and path
grep -n "^version" /Users/shinzui/Keikaku/bokuno/relay-pagination/*/*.cabal
```

Confirm the checkout's versions match what the solver resolved before reading its source as
authoritative, then read the four endpoints side by side with the combinator:

```bash
sed -n '/^data LookupRoutes/,/deriving stock/p' en-servant/src/En/Lookup/Api.hs
sed -n '/^data TupleRoutes/,/deriving stock/p'  en-servant/src/En/Tuple/Api.hs
grep -rn "data RelayPage\|instance HasServer" \
  /Users/shinzui/Keikaku/bokuno/relay-pagination/relay-pagination-servant/src
```

Milestone 2 adds a migration. Under ADR 1 that is a **new file**, never an edit:

```bash
ls en-migrations/migrations/            # see the existing naming convention first
$EDITOR en-migrations/migrations/<new-timestamped-file>.sql
just run-migrations
just migration-status
```

Milestones 3 and 4 are convert-build-test loops, one endpoint at a time, each endpoint its own
commit so a single `git revert` undoes one wire change:

```bash
cabal build all && cabal test all
cabal run en-openapi && git diff docs/api/openapi.json     # read it, do not skim it
```

For the live checks, a running server with enough seeded data to span pages:

```bash
just process-up && just run-migrations && just start-server &
curl -s -X POST "http://127.0.0.1:8080/v1/relationships/query?first=2" \
  -H "Authorization: Bearer ${EN_API_KEY:-dev-secret-0123456789}" \
  -H 'content-type: application/json' -d '{"filter":{}}' | jq '{n:(.edges|length),pageInfo}'
```

Every commit carries all three trailers:

```text
feat(en-servant)!: page relationships/query as a Relay Connection

Replace the bespoke {status, cursor} envelope with Connection/PageInfo on
200 and RelayPageError on 400, backed by a keyset query over a total order.
BREAKING CHANGE: the response shape of POST /v1/relationships/query changes.

MasterPlan: docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
ExecPlan: docs/plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```


## Validation and Acceptance

### A page is a Connection, and following it works

Against a running server with enough seeded rows to span pages:

```bash
curl -s -X POST "http://127.0.0.1:8080/v1/relationships/query?first=2" \
  -H "Authorization: Bearer $EN_API_KEY" -H 'content-type: application/json' \
  -d '{"filter": {...}}' | jq '{edges: (.edges|length), pageInfo}'
```

Expected: two edges and a `pageInfo` carrying `hasNextPage`, `hasPreviousPage`, `startCursor`,
and `endCursor`. Then follow it:

```bash
curl -s -X POST "http://127.0.0.1:8080/v1/relationships/query?first=2&after=<endCursor>" ...
```

Expected: the next two rows, **disjoint** from the first page. Overlap or a gap means the
order is not total, which is Milestone 2's failure showing up here.

### The combinator rejects rather than clamps

```bash
curl -s -o /dev/null -w '%{http_code}\n' "...?first=-1"      # 400
curl -s "...?first=100000" | jq -r '.code'                   # page_size_too_large
curl -s "...?first=2&last=2" | jq -r '.code'                 # mixed_pagination_directions
curl -s "...?after=not-a-cursor" | jq -r '.code'             # invalid_cursor
```

The oversize case is the interesting one: expect a `400`, **not** a silently clamped page.
Clamping is what the standard rules out, because a client asking for 100,000 and receiving 100
has no way to know its request was altered.

Each of those responses must be `application/json` with a `RelayPageError` body — **not**
`application/problem+json`. That is the recorded exemption working, and asserting it is what
makes the exemption visible rather than implicit.

### The conformance test proves the hard part

`relay-pagination-conformance` walks the endpoint in both directions and asserts no row is
skipped or duplicated. Beyond it passing, two things must be true of how it is run, and both
are easy to get wrong in a way that makes a green result meaningless:

- The dataset must be **larger than one page**, or the walk never crosses a boundary and the
  test proves nothing.
- The dataset must include rows that **tie on the primary sort column**, because a non-total
  order is correct on distinct values and wrong on ties. Seed the ties deliberately.

Record the seeded cardinality in this plan, so a future reader can tell whether a green test
was actually exercised.

### The order really is total

```sql
EXPLAIN (ANALYZE, BUFFERS) <the keyset query with a cursor's key values bound>;
```

Expected: an index scan matching the sort specification, not a sequential scan followed by a
sort. Run it against a table with enough rows that a sequential scan is not simply the
cheapest plan; on a few hundred rows the planner will pick a scan regardless and tell you
nothing.

### Nothing else changed shape

```bash
just openapi
python3 - <<'PY'
import json
d = json.load(open("docs/api/openapi.json"))
for p in sorted(d["paths"]):
    for m, o in d["paths"][p].items():
        if m in ("get", "post"):
            print(m.upper(), p, sorted(o.get("responses", {})))
PY
```

Expected: the converted routes list `200` and `400`; every other route is **unchanged** from
before this plan. A diff touching an endpoint this plan did not convert means something leaked.

### The demo store agrees with the API

`cabal test all` includes the in-memory store's suites. If a converted endpoint's in-memory
interpreter was not updated, the API declares a `Connection` while the demo store produces the
old envelope — a divergence that compiles if the shapes are structurally similar enough. Check
explicitly that the in-memory path is exercised by a test that asserts the new shape, rather
than trusting the type checker.


## Idempotence and Recovery

Most of this plan is ordinary source edits, which are safe to repeat: `cabal build all` and
`cabal test all` are pure functions of the tree, and `cabal run en-openapi` overwrites the
document deterministically.

**Milestone 2 is the exception, and the only place in this initiative that touches the
database.** It adds a migration. Under
[ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md), migrations are
append-only and keyed by filename: `just run-migrations` is idempotent — already-applied files
are skipped — but **editing a migration file after it has run anywhere is not recoverable by
re-running**. If you need to change an index after its migration has been applied, add a new
migration that drops and recreates it. Never edit the original.

Adding an index is otherwise a safe, reversible operation: it changes no row and can be
dropped. If `CREATE INDEX` without `CONCURRENTLY` holds a lock longer than acceptable on a
real database, that is a deployment-timing question rather than a correctness one, and it
belongs in the ADR.

Commit at each milestone boundary. Three recovery notes.

**If Milestone 1's verdicts turn out to be wrong**, that is the milestone working. Amend the
Decision Log entry — do not silently implement something different — and update the Progress
section to match the endpoints actually being converted. A plan that converts two endpoints
with recorded reasoning is a better outcome than one that converts four badly.

**If a conformance test fails after a conversion**, suspect the sort order before the handler.
Skipped or duplicated rows are the signature of a non-total order, and the fix is in Milestone
2's territory rather than in the paging code.

**This plan changes the wire.** Once Milestone 3 is committed, a client of that endpoint sees
a different response shape. The recovery is `git revert` of the conversion commit, which is
why each endpoint's conversion should be its own commit rather than one large one. Do not
attempt to serve both shapes: a compatibility shim would let a surface keep decoding the old
envelope and therefore let one be forgotten, which is the two-dialect failure this initiative
exists to prevent.


## Interfaces and Dependencies

### Libraries

Four packages, each with a separate job:

- **`relay-pagination ==0.1.*`** (`en-servant`) — `Connection`, `Edge`, `PageInfo`,
  `PageRequest`, and the opaque cursor type with its versioned payload and sort-spec
  fingerprint.
- **`relay-pagination-servant ==0.1.*`** (`en-servant`) — the `RelayPage` route combinator,
  its validating `HasServer` instance, and the `RelayPageError` wire type.
- **`relay-pagination-hasql ==0.1.*`** (`en-postgres`) — keyset SQL generation and typed
  sort-key codecs.
- **`relay-pagination-conformance ==0.1.*`** (the test suite) — the harness that walks a real
  endpoint in both directions.

The standard verified these against the four `0.1.0.0` packages, their upstream `v0.1.0.0`
tag, and their Hackage releases on 2026-07-22, re-checked against `0.1.1.0` on 2026-07-24. The
local working copy at `/Users/shinzui/Keikaku/bokuno/relay-pagination` shows all four at
`0.1.1.0`. **Re-check Hackage and the upstream tags before setting bounds, and record what
Milestone 1 resolved here**, along with the Mori lifecycle — the registry lists
`shinzui/relay-pagination` as `Experimental`, which the standard does not mention.

`en`'s closure is bound by `crypton >= 1.1` and a forked `biscuit-haskell` under
[ADR 2](../adr/0002-crypton-1-1-binds-en-s-dependency-closure-through-a-biscuit-haskell-fork.md);
"it solved" is not the acceptance criterion, "it built" is.

### Types and functions that must exist, per converted endpoint

```haskell
-- in the endpoint's slice module (En/Tuple/Api.hs or En/Lookup/Api.hs)
type <Name>PageResponses =
  '[ Respond 200 "<description>" (Connection <NodeWire>),
     Respond 400 "Invalid pagination" RelayPageError
   ]

data <Name>PageResult
  = <Name>PageOk !(Connection <NodeWire>)
  | <Name>PageBadRequest !RelayPageError

instance AsUnion <Name>PageResponses <Name>PageResult   -- hand-written, with the
                                                        -- exhaustiveness witness clause
```

and in `en-postgres`, a `SortSpec` whose columns and directions match the index added in
Milestone 2, plus the corresponding in-memory implementation.

### Modules that must not change

`En.Servant.Seam`'s exports (`Env`, `AppEffects`, `MintEnv`, `ActiveSchema`, `EnServer`,
`runEngine`, `runEngineEither`) and `En.Servant.API`'s exports of `app` and its re-export
umbrella — `nagare` and `kikan-en` import those modules directly.

The non-paginated endpoints. `check`, `batch-check`, `expand`, the write endpoints, the schema
lifecycle endpoints, and the grant-minting endpoint are untouched by this plan; a diff
reaching them means the conversion has leaked past its scope.

Existing migration files in `en-migrations`. Milestone 2 adds one; it edits none.
