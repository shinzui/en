---
title: "en — lookup spike: retire the reverse-expansion risk in the real read-path shape"
status: draft
version: 0.1.0
created_at: 2026-06-22
authors: [shinzui]
related:
  - docs/spec/0001-en-overview.md (§5 lookup design, §6 the en/consumer boundary, §10 build plan)
  - shinzui/kikan → docs/architecture/evolution/contracts.md (C13)
---

# en — `lookup` Spike

> **One risk decides whether building `en` in-house is weeks or quarters: does reverse-expansion
> `lookup` perform at our scale?** This spike retires it *before* the engine is built — and it tests
> the **real read-path shape** (the §6 boundary), not a synthetic worst case that we have already
> designed away.

## 1. Why this spike exists

`lookup` (reverse expansion) is the one expensive, hard-to-scale operation in `en`. The source
studies are unambiguous: live reverse expansion is bounded everywhere — OpenFGA defaults to a **3s
deadline / 1000-result cap**; SpiceDB recommends `LookupResources` only for **< ~10k results** before
escalating to a materialized index. So the question is not "is naive `lookup` fast" (it isn't at
scale) — it is **"does `lookup` in the shape we actually use it stay small and fast?"**

The shape we actually use it in is the **§6 boundary discipline**:

- `en` holds the **low-cardinality relationship graph** (spaces, orgs, memberships, delegations —
  thousands of tuples), **not** per-object facts.
- A consumer (kawa) **never asks `en` to enumerate its objects.** It asks `en.lookup` for the **small
  reachable label-set** ("which spaces / visibility-classes can this subject see"), then filters its
  **own** indexed store: `… WHERE space IN (:spaces) AND class IN (:classes)`.

This spike validates that shape, and — by also running the **anti-pattern** (enumerate objects
directly) — demonstrates *why* the boundary discipline is mandatory.

## 2. What to build (minimal, throwaway)

A self-contained harness (Haskell `cabal run` or a SQL-plus-generator script — kikan's
"self-contained proof" house style), with **no dependency on the real engine**:

1. **Schema (kikan-shaped subset):** object types `space`, `org`, `intention`; relations
   `member`, `guest_org` (org→space, view-only), `parent` (space nesting, bounded depth), and a
   `visibility_class` label set (a handful of coarse tiers). Hand-written as a fixed graph — the
   spike does **not** need `En.Reachability.compile`.
2. **Synthetic relationship graph generator** → a Postgres `relation_tuple` table (the §7 columns,
   but the spike may read at **head revision only** — consistency tokens are out of scope here).
   Parameters: number of spaces, orgs, users, guest-org shares, and space-nesting depth.
3. **`lookup_labels(subject)`** — the reverse traversal that returns the **reachable label-set**:
   the set of `space` ids (incl. via `guest_org` and `parent`) and `visibility_class` tiers the
   subject can view. This is the small, bounded query. Implement it as the SpiceDB-style reverse
   walk (subject → resource) over the single `readStartingWithUser` primitive.
4. **Synthetic consumer store** — a `kawa_activity` table of **realistic stream size** (≥ 1,000,000
   rows) with `space` and `visibility_class` columns, indexed.
5. **The read-path query** (the thing we are actually measuring):
   `SELECT … FROM kawa_activity WHERE space = ANY(:spaces) AND visibility_class = ANY(:classes)
    ORDER BY occurred_at DESC LIMIT :page` — using the label-set from step 3.
6. **The anti-pattern, for contrast:** the same page produced by enumerating visible activities
   through `lookup` directly (treating each activity as an object with a relation), to show it blows
   the deadline / cap.

## 3. Parameters to sweep

| Dimension | Values |
| --- | --- |
| Relationship-graph size | 1k, 10k, 100k tuples |
| Space-nesting depth | 1, 3, 6 |
| Guest-org sharing | none; one agency org over N spaces |
| `kawa_activity` rows | 1M, 10M |
| Schema shape | union/container only **vs** with one `Intersection`/`Exclusion` (to see the cliff) |

## 4. Pass / fail bar

Green (proceed with the engine build per spec §10):

- **`lookup_labels` p95 < ~25 ms** at 100k relationship tuples and depth 6 (it returns *tens* of
  labels, not activities — it should be small regardless of stream size).
- **End-to-end filtered page p95 < ~50 ms** at 10M `kawa_activity` rows (dominated by the indexed
  consumer query, not by `en`).
- **The label-set stays small** (bounded by spaces×classes, independent of stream size) across all
  sweeps — this is the property the whole architecture depends on.

Red (reconsider before committing): if `lookup_labels` grows with stream size, or the reachable
label-set is not small, or depth/guest-org sharing makes the traversal super-linear — then either the
schema needs tightening (shallower, fewer intersections) or a materialized index (Leopard, deferred
in §1/§6) must be pulled forward.

**Expected contrast result:** the anti-pattern (enumerate activities via `lookup`) should hit the 3s
/ 1000-result wall at 1M rows — the concrete evidence that the §6 boundary is necessary, not optional.

## 5. Explicitly out of scope (keep it a perf probe)

Consistency tokens (read at head), caveats, the Servant API, cycles, the full reachability compiler,
caching. Those are engine work; this spike answers **one** question — does the §6 read-path shape
stay bounded — and nothing else.

## 6. Output

A short result note appended here (the sweeps, the p95s, green/red) and a go/no-go on the §10 build
plan. If green, `lookup` ceases to be the project's open risk and the engine build proceeds in the
spec's order.
