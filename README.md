# en (縁)

**A schema-parametric, relationship-based authorization (ReBAC) toolkit for Haskell.**

`en` is to authorization what [`shomei`](../shomei) is to authentication: a reusable
Haskell toolkit, usable as an **embedded library** or a **standalone service**. Where
`shomei` (証明, "proof") establishes *who you are*, `en` (縁, "the ties that bind")
establishes *what you may do* — by modeling the **relationships** between principals and
objects and answering authorization as a query over that graph.

It is in the **Zanzibar lineage** (the family of Google Zanzibar → OpenFGA / SpiceDB):
relation tuples, userset-rewrite rules, and a consistency-token model — sized for a single
organization on PostgreSQL rather than a globally-distributed fleet, and extended with the
two things Zanzibar's descendants added: **reverse `lookup` queries** ("what can this
subject see?") and **caveats** (bounded ABAC conditions, e.g. time-bounded or
autonomy-leveled grants).

## Schema-parametric

`en` does **not** hard-code an authorization model. Each consuming project supplies its own
**schema** — object types, relations, rewrite rules, caveats — as a Haskell value, normally
authored with `En.Schema.Builder`. The engine (tuple store, `check`, `lookup`, consistency
tokens) is generic over that schema. This is the same posture as `shomei`: a toolkit, not a
single-app service.

## Query surface

- `check(subject, permission, object) → bool` — the gate.
- `lookup(subject, permission) → [object]` — list what a subject may reach (the read-filter primitive).
- `expand(object, permission) → tree` — who can reach an object (review/audit).
- `write` / `delete` relationship tuples; reads honor a **consistency token** (read-your-writes).

## Packages

| Package | Role |
| --- | --- |
| `en-core` | Transport-/DB-agnostic engine: schema model, reachability compiler, `check`/`lookup`/`expand`, revision & token types, store effect interfaces |
| `en-migrations` | codd-compatible PostgreSQL schema as plain timestamped SQL (relation tuples, xid8 soft-delete, the revisions table, datastore identity); applied in dev by `just run-migrations` |
| `en-postgres` | PostgreSQL implementations of the store effects + `pg_snapshot` revision machinery |
| `en-servant` | Servant API + `requirePermission`, a fail-closed handler helper |
| `en-server` | Standalone authorization service (thin app over the libraries) |
| `en-client` | Haskell client for the standalone service |
| `en-biscuit` | Optional Biscuit decision-token layer: mint short-lived signed proofs of `en` decisions and verify/attenuate them locally downstream |

## Status

Experimental — scaffolding + initial spec. See [`docs/spec/0001-en-overview.md`](docs/spec/0001-en-overview.md)
for the design, and the kikan contract **C13** (`shinzui/kikan` →
`docs/architecture/evolution/contracts.md`) for the cross-system role and the first consumer's
requirements.

User-facing integration docs start at [`docs/user/README.md`](docs/user/README.md).
For the optional Biscuit decision-token layer, see
[`docs/user/biscuit-decision-tokens.md`](docs/user/biscuit-decision-tokens.md).
