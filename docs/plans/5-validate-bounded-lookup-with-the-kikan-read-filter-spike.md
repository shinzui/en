---
id: 5
slug: validate-bounded-lookup-with-the-kikan-read-filter-spike
title: "Validate bounded lookup with the kikan read-filter spike"
kind: exec-plan
created_at: 2026-06-23T04:05:56Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Validate bounded lookup with the kikan read-filter spike

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan retires the largest architectural risk before the full lookup engine is built: whether reverse lookup stays small and fast when used in the intended kikan read-filter shape. After it is complete, `docs/spec/0002-lookup-spike.md` will contain measured results and a green/red decision. A green result means production lookup can proceed without a materialized reverse index. A red result means the schema, boundary discipline, or materialized-index scope must be reconsidered before building the rest.


## Progress

- [ ] Build a throwaway harness that generates a kikan-shaped relationship graph.
- [ ] Populate a synthetic consumer activity table with at least 1,000,000 rows and indexed `space` and `visibility_class` columns.
- [ ] Implement `lookup_labels(subject)` as a reverse walk over low-cardinality relationships.
- [ ] Implement the real read-path query that filters activity rows using reachable labels.
- [ ] Implement the anti-pattern contrast that treats each activity as an authorization object.
- [ ] Sweep relationship graph sizes, nesting depths, guest-org sharing, stream sizes, and schema shape.
- [ ] Record p95 timings, label-set sizes, and the green/red decision in `docs/spec/0002-lookup-spike.md`.
- [ ] Run any harness tests plus `cabal build all` if Haskell code is added.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep the spike independent of the production engine.
  Rationale: `docs/spec/0002-lookup-spike.md` explicitly scopes out consistency tokens, caveats, the Servant API, cycles, caching, and the full reachability compiler so the performance risk can be answered quickly.
  Date: 2026-06-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is based on `docs/spec/0002-lookup-spike.md`. It has no hard dependency on other child plans because it is a minimal proof harness. It has soft dependencies on `docs/plans/1-stabilize-core-authorization-interfaces.md` and `docs/plans/3-implement-schema-validation-and-reachability-compilation.md` because their terminology should align with the spike, but the spike must not wait for production code.

The architectural boundary being tested is simple: `en` stores low-cardinality, slow-changing relationship facts such as spaces, orgs, memberships, guest sharing, and visibility-class reachability. The high-cardinality activity stream remains in the owning service, such as kawa. A consumer asks `en.lookup` for a small set of reachable spaces/classes and then uses its own indexed database query to page activities.


## Plan of Work

Create a self-contained harness under a clearly throwaway or experimental location, such as `spikes/lookup-read-filter` or a documented test executable. Use Haskell if it can be built quickly with the repo tooling; otherwise a SQL-plus-generator script is acceptable as long as it is checked in and reproducible.

The harness should generate a relationship table with object type/id, relation, subject type/id, and optional subject relation. It may read at head revision only. Generate object types `space`, `org`, and `visibility_class`; relations `member`, `guest_org`, `parent`, and the minimum view relation needed to compute reachable labels.

Implement `lookup_labels(subject)` to return reachable spaces and visibility classes for a subject. This is the query the architecture depends on. It should return tens of labels in the green path, not activity-scale results.

Generate a synthetic `kawa_activity` table with at least 1,000,000 rows, and optionally 10,000,000 rows if local resources allow. Add indexes that match the intended read-path query:

```sql
SELECT *
FROM kawa_activity
WHERE space = ANY(:spaces)
  AND visibility_class = ANY(:classes)
ORDER BY occurred_at DESC
LIMIT :page;
```

Run the parameter sweep from `docs/spec/0002-lookup-spike.md`: 1k, 10k, and 100k relationship tuples; nesting depths 1, 3, and 6; no guest sharing and one agency org over many spaces; 1M and 10M activity rows where feasible; union/container-only schema and one intersection/exclusion variant.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Read the spike spec:

```bash
sed -n '1,220p' docs/spec/0002-lookup-spike.md
```

Create the harness in the chosen location and document how to run it in a `README.md` next to the harness. A future implementation should update this section with the exact command. The expected shape is one command to generate data and one command to run measurements, for example:

```bash
cabal run lookup-read-filter-spike -- --tuples 100000 --activities 1000000 --depth 6
```

Append a concise results note to `docs/spec/0002-lookup-spike.md` with the sweep matrix, p95s, and decision.


## Validation and Acceptance

Green acceptance is exactly the bar in `docs/spec/0002-lookup-spike.md`: `lookup_labels` p95 below about 25 ms at 100k relationship tuples and depth 6, end-to-end filtered page p95 below about 50 ms at 10M activity rows where feasible, and label-set size remaining bounded independently of stream size. The anti-pattern should hit the deadline/cap wall at 1M rows and demonstrate why per-activity tuples are forbidden.

If local hardware cannot run the 10M activity case, record the limitation and still run 1M rows plus explain what evidence remains missing.


## Idempotence and Recovery

The harness should be safe to rerun. It should create isolated local databases, schemas, or table names and provide a documented cleanup path. Do not use destructive commands outside the harness-managed scope without explicit user approval.


## Interfaces and Dependencies

No hard dependencies.

Soft dependencies: `docs/plans/1-stabilize-core-authorization-interfaces.md` and `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`.

This plan informs `docs/plans/7-implement-cursored-reverse-lookup-and-expand.md`. If the spike is red, update the MasterPlan before implementing production lookup.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.
