---
title: "en (縁) — Initial Spec: a schema-parametric ReBAC toolkit"
status: draft
version: 0.1.0
created_at: 2026-06-22
authors: [shinzui]
related:
  - shinzui/kikan → docs/architecture/evolution/contracts.md (C13)
  - shinzui/shomei (the authentication sibling)
---

# en (縁) — Initial Spec

> `en` is to **authorization** what [`shomei`](../../../shomei) is to **authentication**: a
> reusable Haskell toolkit, embeddable as a library or run as a standalone service.
> `shomei` (証明, "proof") establishes *who you are*; `en` (縁, "the ties that bind")
> establishes *what you may do* — by modeling the **relationships** between principals and
> objects and answering authorization as a query over that graph.

This document is the initial design spec. It fixes the **model**, the **query surface**, the
**consistency guarantee**, and the **package architecture**, and names the first consumer
(kikan) and a staged build plan. It is deliberately grounded in two reference
implementations read at the source level (OpenFGA v1.18, SpiceDB v1.54); where a design
choice follows or departs from them, it says so.

---

## 1. What `en` is (and is not)

`en` is a **relationship-based access control (ReBAC)** engine in the **Zanzibar lineage**
(Google Zanzibar → OpenFGA / SpiceDB). It answers object-level authorization questions —
*may THIS subject do THIS to THIS object, given how they are related* — which is the layer
that coarse role/scope authentication (shomei) deliberately leaves out.

**It is a toolkit, not an application.** `en` ships **no built-in authorization model**. Each
consuming project supplies its own **schema** (object types, relations, rewrite rules, caveats)
as a Haskell value; the engine is generic over that schema. This is the same posture as
`shomei`, and it is the chosen point on the genericity spectrum:

- **(chosen) Schema-parametric Haskell toolkit** — reusable across Haskell projects, fully
  type-safe, no runtime DSL. The schema is *typed data* supplied at startup.
- (not now) A runtime-configurable, language-agnostic service (the full OpenFGA/SpiceDB
  product). `en`'s engine is already schema-parametric, so a runtime-schema service layer can
  be added later **without rearchitecting** — but it is out of scope until a non-Haskell
  consumer needs it.

**Non-goals (deliberate, with rationale):**

- **Not Zanzibar-scale.** Single organization on **one PostgreSQL**, not a globally-distributed
  Spanner fleet. No multi-region, no consistent-hashing aclserver fleet, no request hedging.
- **No offline materialized index (Leopard) yet.** Live `lookup` covers inbox-scale queries.
  A denormalized reverse index for very large result sets (e.g. stream read-filtering at the
  high end) is deferred; note there is **no open-source reference** for it (SpiceDB's
  "Materialize" is commercial), so if it is built it is built from the paper.
- **No general policy engine (OPA/Rego).** That would forfeit `lookup` (you cannot cheaply
  enumerate "everything a subject can see" through arbitrary policy). Bounded ABAC lives in
  **caveats**, not a policy language.

---

## 2. Relationship to Zanzibar (what is adopted, simplified, omitted, added)

| Zanzibar concept | `en` |
| --- | --- |
| Relation tuples `object#relation@user` (user = id or userset) | **Adopted** — `En.Tuple.Tuple` |
| Userset rewrites: `_this`, `computed_userset`, `tuple_to_userset`, union/intersection/exclusion | **Adopted** — `En.Schema.Rewrite` |
| Wildcards / public | Adopted (model-level) |
| Namespace config / schema | Adopted, but **fixed & typed** per consumer, not runtime-reconfigurable |
| Zookie consistency token; new-enemy prevention; snapshot reads | **Adopted** — `ConsistencyToken`, `Consistency` |
| External consistency via Spanner + TrueTime | **Simplified** → single-Postgres `pg_snapshot` (a *partial* order) |
| API: Check, Read, Expand, Write, Watch | Check/Read/Write/Expand adopted; **Watch deferred** |
| Leopard reverse index | **Omitted/deferred** (no OSS reference) |
| Global distribution, consistent hashing, hedging | **Omitted** (single org, single Postgres) |
| Reverse queries (`lookup` / ListObjects / LookupResources) | **Added** (postdates the paper; from the descendants) |
| Caveats / conditions (ABAC) | **Added** (postdates the paper; for autonomy-leveled & time-bounded grants) |

Bottom line: **`en` is "Zanzibar-model, not Zanzibar-scale," plus the two modern extensions
(reverse `lookup` + caveats)** — the same family as OpenFGA/SpiceDB, sized for one org.

---

## 3. The model (`en-core`)

- **Tuple** (`En.Tuple`): `(object, relation, subject, caveat?)`. `subject` is either a
  concrete id (`SubjectId`) or a userset (`SubjectSet object relation`) — the latter is how
  groups-of-groups (and guest *orgs*) are expressed.
- **Schema** (`En.Schema`): a map from object type to its relations; each relation carries a
  **rewrite** (`This | ComputedUserset | TupleToUserset | Union | Intersection | Exclusion |
  Caveated`). Permissions are relations whose rewrite composes others.
- **Caveats**: a `Caveated` rewrite gates membership on a named, bounded predicate evaluated
  against request context (`CaveatContext`). Two first-class uses: **time-bounded** grants
  (`until`) and **autonomy-leveled** delegation. No CEL — a small typed predicate evaluator
  (there is no Haskell CEL library, and we do not need wire-compat with OpenFGA/SpiceDB
  conditions). Keep it non-Turing-complete and total.

**Design lean: prefer `Union`/`ComputedUserset`/`TupleToUserset`; minimize
`Intersection`/`Exclusion`.** Those are the non-streaming, expensive cases for `lookup`
(§5). Model sensitivity tiers as **container relations**, not as intersections, to keep
`lookup` a pure reachability query.

---

## 4. The query surface

Over a compiled schema (`En.Reachability.ReachabilityGraph`) and a `TupleStore`:

- `check(subject, permission, object) → Bool` (`En.Check`) — forward evaluation, the gate.
- `lookup(subject, permission, objectType) → [object]` (`En.Lookup`) — reverse expansion, the
  **read-filter primitive** (e.g. kawa filtering the activity stream, a kizashi inbox query).
  **Required, not optional** — under-providing it is the classic ReBAC-adoption failure.
- `expand(object, permission) → tree` — who can reach an object (review/audit UIs).
- `write` / `delete` tuples → returns a `ConsistencyToken`.

Every read takes a `Consistency` (§6). Reads and writes go through the `TupleStore` effect
(`En.Effect.TupleStore`), whose single reverse primitive is `readStartingWithUser` —
Zanzibar's `ReadStartingWithUser`, which backs both `check` and `lookup`.

---

## 5. `lookup` design (the one hard part)

Both reference engines are the same family — **reverse-walk to generate candidates, forward
`check` to confirm the hard cases** — differing in graph intelligence:

- **OpenFGA v1.18** (`internal/listobjects/pipeline`): a *weighted* graph drives a dataflow
  **worker network** (one worker per node, bounded-buffer message passing with backpressure,
  three set-op worker types). Intersection/exclusion are resolved **structurally** by blocking
  workers — *no* per-candidate check. The genuinely fiddly parts: cycle/quiescence handling
  (only needed for recursive relations) and blocking set-op teardown.
- **SpiceDB v1.54** (`internal/graph/lookupresources3.go`): a **boolean** reachability graph
  (no weights) + composable **cursored iterators** + **reach-then-check** for conditional
  entrypoints, with a three-valued result (member / not-member / **conditional**) carrying
  caveat obligations.

**`en` ports SpiceDB's skeleton, optionally borrowing OpenFGA's weights later:**

1. **Boolean reachability graph** compiled from `Schema` (`En.Reachability.compile`). Each
   entrypoint is marked **direct** (under unions → unconditionally a result) or **conditional**
   (under intersection/exclusion/caveat → needs a confirming `check`).
2. **Reverse expansion** as **lazy, cursorable streams** (conduit/streamly/pipes, or a small
   resumable cursor monad) — the LR3 producer/mapper shape maps far more naturally onto Haskell
   than goroutines-and-channels. Producer = datastore chunks via `readStartingWithUser`;
   mapper = recursive dispatch (found resources become the next subjects).
3. **Reach-then-check** for conditional entrypoints; **three-valued membership** as a clean ADT.
4. **Bounded, possibly-truncated results** by design: a deadline + max-results cap (OpenFGA
   defaults 3s / 1000; SpiceDB 1000) — live reverse expansion does not scale to unbounded
   sets. If/when a large-result path is needed (stream read-filter at the high end), add a
   **materialized reverse index** (Leopard-style) fed by a change feed — deferred (§1).
5. **Weights later, if needed.** OpenFGA-style edge weights are an *additive* traversal-ordering
   optimization over the same reachability graph — not a foundation. Defer.

**`en`'s simplifications vs the references** (it is a toolkit for one org, not a product):
fixed typed schema → the reachability graph is generated from the supplied `Schema`, not a
runtime DSL; constrain recursion → smaller/no cycle machinery; container-first sensitivity +
minimal intersection/exclusion → few conditional entrypoints → little check-confirmation.

---

## 6. Consistency design (`en-postgres`)

The standalone, multi-writer topology requires a real consistency token. Following SpiceDB's
PostgreSQL datastore, this is **mostly Postgres MVCC + a codec**, not a consistency protocol:

- **A revision is a `pg_snapshot`** (`xmin:xmax:xip`), not a sequence number. Each write inserts
  an `en_transaction` row with `xid xid8` + `snapshot pg_snapshot DEFAULT pg_current_snapshot()`.
- **Tuples are soft-deleted by xid**: `relation_tuple` carries `created_xid`/`deleted_xid`
  (xid8, sentinel max = live). Upsert inserts a new row; delete stamps `deleted_xid`. Never
  update in place — that is what makes point-in-time reads possible.
- **Read at revision `R`** is one predicate:
  `pg_visible_in_snapshot(created_xid, R) AND NOT pg_visible_in_snapshot(deleted_xid, R)`.
  Postgres decides visibility; `en` does not build a consistency protocol.
- **The token** (`ConsistencyToken`) is an opaque base64-proto wrapping the revision string +
  a datastore-id prefix + a schema hash (so a token from a different datastore/schema is
  detected).
- **The four modes** (`En.Revision.Consistency`): `MinimizeLatency` (a **quantized** revision —
  floor-now-to-window, pick first txn, so many requests share a snapshot and caches hit),
  `FullyConsistent` (head / `pg_current_snapshot()`), `AtLeastAsFresh token` (the new-enemy fix:
  `max(optimized, token)`), `AtExactSnapshot token` (the token's revision, GC-window checked).

**The load-bearing correctness subtlety — comparison is a PARTIAL order.** Two Postgres
snapshots can be *concurrent* (incomparable). `En.Revision.RevisionOrder` is therefore
four-valued (`RBefore | RAfter | REqual | RConcurrent`), and `Revision` has **no `Ord`
instance**. `AtLeastAsFresh` relies on a concurrent optimized revision **not** counting as
≥ the token (so it correctly falls through to honoring the token). A naive total `Ord`
silently breaks read-your-writes. This is the one place to be most careful.

---

## 7. Package architecture (mirrors `shomei`)

| Package | Role |
| --- | --- |
| `en-core` | Engine: `En.Schema`, `En.Tuple`, `En.Revision`, `En.Reachability` (compiler), `En.Check`, `En.Lookup`, `En.Effect.TupleStore`, `En.Error`. No transport/DB deps. |
| `en-migrations` | codd PostgreSQL schema: `relation_tuple` (xid8 soft-delete), `en_transaction` (snapshot). |
| `en-postgres` | hasql `TupleStore` impl + `pg_snapshot` revision/token machinery. |
| `en-servant` | Servant API (check/lookup/expand/write) + a `RequirePermission` combinator (composes *after* shomei authn). |
| `en-server` | Standalone service (thin app). |
| `en-client` | Haskell client for the standalone service. |

Effects-as-interfaces live in `en-core` (an in-memory `TupleStore` enables testing without
Postgres); implementations live in `en-postgres` — the shomei pattern.

---

## 8. First consumer: kikan (contract C13)

kikan supplies the first `Schema`. Its load-bearing requirements (from C13,
`shinzui/kikan → docs/architecture/evolution/contracts.md`):

- **Object types & relations**: `space`, `org`, `intention`, `conversation`, `activity`,
  with `owner`, `member`, `guest_org`, `participant`, `delegate`, plus a `visibility-class`
  container for sensitivity tiers.
- **Cross-org guest sharing (the agency case)**: an `org` of agency members granted
  `(space:project-x, guest_org, org:acme)`; `guest_org` computes to `view` only, never
  `act`/`admin`, and never inherits internal relations. Subset visibility = reachability from
  the shared space + a coarse sensitivity tier (container, not attribute).
- **Delegation**: `(intention, delegate, user)` with a **caveat** carrying autonomy level and
  an optional `until` (time bound).
- **Composition with shomei (C11)**: shomei's `requireRole`/`requireScope` is the coarse gate
  *in front of* every `en.check` (object gate). The two compose; they do not compete.

**The agency scenario is the day-1 conformance case** — it exercises guest orgs, reachability
scoping, sensitivity tiers, *and* `lookup` filtering at once. If the proof harness passes the
agency case, the model is right.

---

## 9. Staged build plan

1. **Schema + reachability compiler** (`En.Reachability.compile`) over a fixed kikan-shaped
   schema; property-test the rewrite rules (QuickCheck).
2. **Tuple store + consistency** (`en-migrations` + `en-postgres`): the schema, the
   `pg_snapshot` revision partial order, the token codec, the four modes. In-memory store first.
3. **`check`** (forward) — the smaller algorithm.
4. **`lookup`** (reverse, cursored streaming, reach-then-check) — **the risk to retire first**;
   spike it over a synthetic kikan graph at target tuple counts with a pass/fail latency bar
   *before* committing the full build.
5. **`en-servant` + `en-server`** + the `RequirePermission` combinator.
6. **kikan schema + agency conformance proof.**

---

## 10. References (read at source level)

- Google Zanzibar (Pang et al., USENIX ATC 2019) — the model, Zookies, the new-enemy problem,
  Leopard.
- OpenFGA v1.18 — `internal/listobjects/pipeline/*` (dataflow reverse expansion),
  `pkg/typesystem/weighted_graph.go`.
- SpiceDB v1.54 — `internal/graph/lookupresources3.go`, `pkg/schema/reachabilitygraph*.go`,
  `internal/datastore/postgres/{revisions,snapshot}.go`, `pkg/middleware/consistency/*`,
  `pkg/zedtoken/*`.
- `shinzui/shomei` — the sibling toolkit whose package layout and effect pattern `en` mirrors.
