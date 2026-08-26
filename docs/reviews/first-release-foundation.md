---
type: Review
title: First-release foundation review — APIs are sound, release gates remain
description: The July architecture review's critical API and engine defects are fixed, but Biscuit verification, packaging, CI, and a few bounded correctness and operability risks still require changes before the first release.
generated:
  by: process:codex
  at: "2026-08-26T12:46:24Z"
reviewId: REV-1
subject: mori://shinzui/en
subjectKind: project
repository: mori://shinzui/en/repos/en
reviewedSha: f1ff413e92a5741641f1914e37899c35ad075a12
coverage: full
reviewedAt: "2026-08-26T12:46:24Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-5
effort: unspecified
outcome: changes-requested
dimensions:
  - correctness
  - security
  - performance
  - design
  - test-coverage
  - documentation
  - operability
context: >-
  Re-audited every finding in the retired 2026-07-07 review against the source,
  tests, generated OpenAPI document, operator guidance, and completed remediation
  plans at the reviewed commit. Ran the complete API Hurl corpus against a local
  PostgreSQL-backed server, the Cabal build/test/package checks, the flake check,
  and OKF validation. The unrelated process already bound to 127.0.0.1:8080 was
  avoided by running en-server on 18080.
---

# First-release foundation review — APIs are sound, release gates remain

## Verdict

**Changes requested before the first release.** The architectural center is now
strong and the original review's unsafe-service verdict is obsolete. The standalone
server has an authenticated and rate-limited perimeter, pooled PostgreSQL access,
versioned typed routes, consistency-token chaining, bounded evaluation, operational
probes and telemetry, maintenance, and the missing relationship, lookup-subjects,
watch, schema, OpenAPI, and Biscuit-minting surfaces. The critical and high defects
that made the July server a prototype are fixed.

The release is not ready to cut yet. Valid Biscuit authorization can fail
nondeterministically under the dependency's one-millisecond default execution budget;
the flake's default package cannot build; the full test suite is absent from CI and is
currently red when the Biscuit timeout fires; and `cabal check` says `en-postgres`
would be rejected by Hackage while every package still has missing upper bounds.

## What this review replaces

The deleted `docs/reviews/2026-07-07-architecture-performance-review.md` reviewed
commit `919b8b4` and supplied the A1–A9, B1–B12, C1–C10, D1–D3, and E1–E14 labels
used below. It predated the shared reviews profile and had no stable review handle.
REV-1 preserves its useful checklist, verifies it against the current tree, and starts
the structured review history. The profile is
`mori://shinzui/okf-profiles/profiles/reviews`.

## API-first assessment

### Verified foundation

- **Perimeter:** production startup requires configured credentials or an explicit
  development-only opt-out. Missing and invalid keys return `401`; read-only keys
  cannot write; rate limiting is per authenticated caller; only liveness and
  readiness are public. Optional direct TLS and a documented reverse-proxy posture
  close A1/E8 rather than merely moving the risk.
- **Contract:** all business routes are under `/v1`; relationship deletion uses POST;
  request and response DTOs no longer expose Haskell constructor names; handler faults
  have stable codes, retryability, and RFC 9457 problem documents; a generated OpenAPI
  3.1 artifact describes authentication, media types, schemas, and response variants.
  This closes A3/A5/E11 for ordinary handler paths.
- **Consistency:** check, batch-check, lookup, lookup-subjects, expand, watch, and grant
  minting return `checkedAt`. Continuation cursors pin and validate the same token
  metadata, so callers can chain reads without forging a revision. This closes
  B7's snapshot half, B9, and E3.
- **Write and audit surface:** relationship query, exact delete, delete-by-filter,
  preconditions, atomic mixed writes, touch semantics, bulk import/export, watch,
  lookup-subjects, operator-preserving expand, schema read/reload, and schema preflight
  are present. This closes C1/E1/E2/E4/E5/E6/E9 and B10.
- **Operations:** the server uses `hasql-pool`, validates configuration before binding,
  persists datastore identity, drains on shutdown, serves health/readiness and metrics,
  logs bounded structured requests, traces named Servant routes, and schedules bounded
  tuple and transaction cleanup. This closes A2, most of A4/A6/A7/A9, and C2/C4.
- **Biscuit API:** `/v1/grants` mints only after an `Allowed` check, binds the grant to
  the active schema and checked-at token, supports keyed rotation, makes every token
  revocable by block id, and has holder-attenuation injection tests. This closes D1–D3.

### Live contract evidence

| Check | Result | What it established |
| --- | --- | --- |
| Default Hurl corpus | Pass, 15/15 requests | Probes, OpenAPI, check/batch-check errors, lookup/lookup-subjects cursors, expand operators, and schema read |
| Relationship Hurl corpus | Pass, 10/10 requests | Failed-precondition rollback, idempotent write/delete, read-your-writes token, Relay continuation, cursor and pagination errors |
| Perimeter Hurl corpus | Pass, 5/5 requests | Public probes, indistinguishable missing/invalid credentials, valid writer, refused read-only write |
| `en-servant-tests` | Pass | Route, DTO, response-alternative, checked-at chaining, OpenAPI, problem-details, and grant-minting behavior |
| OpenAPI regeneration | Pass, no diff | Checked-in `docs/api/openapi.json` matches the current route types |

### API issues to settle before freezing `/v1`

1. **HIGH — valid Biscuit grants can time out nondeterministically.** The registered
   fork `mori://shinzui/biscuit-haskell/packages/biscuit-haskell` defines
   `defaultLimits.maxTime = 1000` microseconds and `authorizeBiscuit` applies that
   default. The trivial smoke authorization passed once and returned `Timeout` twice
   during this review. `En.Biscuit.Verify.runRestrictions` uses the same default path,
   so this is not only a test problem: a valid attenuated grant can fail closed under
   ordinary scheduler noise. Give verification an explicit, tested execution budget
   and make its operational meaning configurable or deliberately fixed.
2. **MED — two error dialects remain.** Most failures are RFC 9457
   `application/problem+json`, but relationship-query pagination failures are
   `application/json` `RelayPageError`, and `415 Unsupported Media Type` still has an
   empty body. Both are documented in code; neither is uniform with the public claim
   that every error has one problem-details shape. Decide whether `/v1` promises one
   dialect before release and test the chosen exceptions explicitly.
3. **MED — metrics under-report the expanded API.** The bounded path-label vocabulary
   omits `grants`, `lookup-subjects`, `schema`, and `watch`, grouping them as `other`.
   Authentication and rate-limit short circuits (`401`, `403`, `429`) sit outside the
   logger and metrics middleware. The service is observable, but not yet by every
   security-relevant operation or perimeter outcome.
4. **LOW — `en-client` remains intentionally thin.** It now mirrors the full API and
   provides `chainFrom`, but still leaves `ClientEnv` construction, timeouts, retries,
   and page-draining helpers to each consumer. This is adequate for a low-level client,
   not yet the batteries-included client A9 originally imagined.

## Original finding closure

| Theme | Closed | Partial or intentionally retained |
| --- | --- | --- |
| A — service readiness | A1, A2, A5, A7, A8 | A3: Relay/415 exceptions; A4: perimeter and route-label telemetry gaps; A6: dump/restore identity rotation remains manual; A9: thin client |
| B — evaluation engine | B1–B6, B9–B11 | B7: one snapshot fixed, per-candidate confirmation remains; B8: deadlines interrupt work, but lookup/expand still recompute traversal across pages; B12: major allocations/configuration fixed, while sequential fan-out and FNV-1a-64 remain deliberate tradeoffs |
| C — storage/write semantics | C1–C6, C8, C9; C10 verified non-issue | C7: the GC validation/read race is documented and bounded by `EN_GC_WINDOW`, not eliminated |
| D — Biscuit layer | D1–D3 | New blocker: the verifier's default one-millisecond execution budget is unstable |
| E — feature gaps | E1–E9 and E11 | E10 multi-tenancy, E12 decision explain/trace, E13 wire streaming, and E14 advanced caveat operators remain explicit non-goals or future work |

The partial items do not invalidate the closed critical server findings. They do define
the honest boundary of a first release: one datastore per deployment, bounded
cursor-resumable rather than streamed traversal, and no decision proof trace beyond
operator-preserving expand.

## Remaining non-API correctness and performance risks

1. **MED — GC TOCTOU can return an incomplete exact-snapshot read.** A token may pass
   horizon validation and then lose historical rows to the reaper before its tuple read.
   The deployment invariant makes the window much longer than any request or pagination
   session, which makes the race unlikely but does not make the result detectable.
2. **MED — later lookup/expand pages repeat traversal work.** Snapshot correctness and
   real deadline interruption are fixed, but the storage order still cannot resume every
   branch from a safe frontier. Large multi-page traversals therefore pay repeated work,
   and intersection/exclusion confirmation remains per candidate.
3. **LOW — schema identity is still FNV-1a-64.** It is insertion-order independent and
   guarded by tests, but collision resistance remains weaker than is desirable for a
   fingerprint that invalidates consistency and decision-cache state.
4. **LOW — datastore restore detection is manual.** The persisted id prevents accidental
   cross-datastore token reuse, but restoring into a fresh PostgreSQL cluster still
   requires the operator to rotate that id; the runbook is the detection mechanism.

## Release engineering and documentation blockers

1. **HIGH — the flake package is broken.** `nix flake check --accept-flake-config`
   fails because `packages.default` calls `callCabal2nix` on the multi-package repository
   root, where no root `.cabal` or `package.yaml` exists. The advertised Nix package
   cannot be built.
2. **HIGH — CI does not defend the full test surface.** The workflows run benchmarks
   and the safe Hurl corpus, but no workflow runs all unit, conformance, Biscuit, Servant,
   migration, and PostgreSQL integration suites. Seven suites passed in the all-tests
   run; `en-biscuit-tests` failed as described above. The isolated Biscuit suite passed
   once, proving nondeterminism rather than health.
3. **HIGH for Hackage — package bounds are not publishable.** `cabal sdist all`
   successfully created every tarball, but `cabal check` reports missing upper bounds in
   all eight en packages and says Hackage would reject `en-postgres` because one
   `base` dependency has no upper bound. Choose bounds only after checking current
   authoritative package releases; do not copy the local solver plan blindly.
4. **MED — operator documentation contradicts `/v1`.** The operations guide shows the
   obsolete `{code,message,retryable}` error shape instead of RFC 9457's
   `{type,title,status,detail,code,retryable}`, says `405` has an empty body even though
   middleware now returns problem details, and lists obsolete metric path labels while
   omitting newer operations.
5. **MED — release documentation is incomplete.** There is no changelog or release
   checklist, and some Cabal descriptions still describe initial scaffolding rather than
   the shipped package. The existing capabilities bundle also reports a missing
   `okf_version` and 25 missing recommended review annotations under strict profile
   validation.

## Evidence summary

| Command or inspection | Result |
| --- | --- |
| `cabal build all` | Pass |
| `cabal test all --test-show-details=direct` | Fail: Biscuit smoke authorization `Timeout`; seven other suites pass |
| Isolated `cabal test en-biscuit-tests` | One pass; later serial all-tests run failed before any other suite |
| `cabal sdist all` | Pass; all en packages and pinned source dependencies produced tarballs |
| `cabal check` in all package directories | Warnings in all; Hackage-rejection error in `en-postgres` |
| `nix flake check --accept-flake-config` | Fail: root `callCabal2nix` has no package file |
| Released review profile verification | v0.12.0 is the latest upstream tag; reviews profile introduced in v0.11.0 and remains unchanged in v0.12.0 |

## Release bar

Before tagging the first release:

1. make Biscuit verification deterministic under an explicit execution budget and run
   its regression repeatedly;
2. make `nix flake check` build the intended package set;
3. add a CI job that runs the complete test suite, including PostgreSQL integration,
   and require it;
4. make every published Cabal package pass `cabal check` with deliberate dependency
   bounds;
5. choose and document the final `/v1` error-dialect exceptions, correct the operator
   guide, and add the release changelog/checklist;
6. explicitly accept or fix the GC race and repeated-page traversal costs for the
   expected first-release workload.

After those changes, the next review can be incremental from
`f1ff413e92a5741641f1914e37899c35ad075a12` and should be eligible for `approved`.
