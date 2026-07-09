---
id: 35
slug: version-the-wire-contract-and-type-the-error-model
title: "Version the wire contract and type the error model"
kind: exec-plan
created_at: 2026-07-07T15:24:43Z
master_plan: "docs/masterplans/6-production-harden-the-en-service.md"
intention: intention_01kx21nk4kemtt6pjnb5tr76nk
---

# Version the wire contract and type the error model

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

en-server's JSON wire format today is an accident of Haskell internals. The wire types in
`en-servant/src/En/Servant/API.hs` derive their JSON instances generically, so sum types
serialize with constructor tags: a client literally sends
`{"tag":"AtLeastAsFreshWire","contents":"en1.…"}` and matches decisions against
`"AllowedWire"` — the internal `Wire` suffix and aeson's default sum encoding are frozen
into the public API. There is no version prefix, so none of this can ever be fixed
compatibly. Errors are worse: every engine error becomes HTTP 500 with the `Show` output
of `EnError` as the message (`en-servant/src/En/Servant/Seam.hs`), so a client cannot
distinguish "your consistency token is stale" (its fault, don't retry) from "the database
is down" (retry later), and malformed request bodies get Servant's plain-text 400, so
even the error *content type* is inconsistent. `DELETE /tuples` carries a request body,
which HTTP intermediaries are allowed to drop. These are findings A3 (HIGH) and A5 (MED)
of `docs/reviews/2026-07-07-architecture-performance-review.md`; the missing
machine-readable API description is gap E11 there.

After this change, the API lives under a `/v1` path prefix with hand-written, stable,
tag-free JSON encodings; every error — engine, validation, or body-decode — arrives as
one JSON envelope `{"code": …, "message": …, "retryable": …}` with a status code that
separates client faults (4xx) from server faults (5xx); tuple deletion is
`POST /v1/relationships/delete` (no DELETE-with-body); and `GET /v1/openapi.json` serves
a generated OpenAPI document describing all of it. **This is a deliberate,
one-time breaking change to every wire consumer** — the Haskell client
(`en-client/src/En/Client.hs`) and the Justfile smoke tests are updated in the same
commit series, and the `/v1` prefix exists precisely so the *next* break can be staged
instead of forced. This plan is child EP-35 of
`docs/masterplans/6-production-harden-the-en-service.md` and owns the error envelope
that EP-33 and EP-36 emit.

Handler-produced errors are not merely *shaped* consistently — they are part of the
API type. Each of the six operations is a Servant `MultiVerb` whose response
alternatives enumerate the statuses it can return (200, 400, 422, 503), so a handler
returns an ordinary Haskell value rather than throwing an untyped `ServerError`, the
OpenAPI document in M4 lists every error response per operation with its schema, and
`en-client` hands callers a typed `EnResult` instead of an opaque `ClientError`. Errors
raised *before* a handler runs — a malformed request body, an unmatched route — cannot
be expressed this way, since they come from Servant's routing layer; those are
normalized into the same envelope by `ErrorFormatters`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-08): hand-written `ToJSON`/`FromJSON` instances for every wire type in
  `en-servant/src/En/Servant/API.hs` per the JSON grammar in this plan; generic
  derivations removed. `toEncoding` written explicitly alongside `toJSON` for every
  type, which fixes field order and skips the intermediate `Value` on the response path.
- [x] M1 (2026-07-08): golden encoding tests (exact bytes), decode round-trip tests, and
  a negative decode per sum type added to `en-servant/test/Main.hs`.
- [x] M1 (2026-07-08): `Justfile` `test-server` request bodies moved to the new grammar
  ahead of schedule (paths still unversioned) so the smoke test stays green between M1
  and M2. `just start-and-test` prints `server smoke test passed: allowed`.
- [x] M2 (2026-07-08): routes moved under `/v1`; `DELETE /tuples` replaced by
  `POST /v1/relationships/delete`; writes at `POST /v1/relationships`. Verified: old
  paths return `404`, `DELETE /v1/relationships` returns `405` without consuming a body.
- [x] M2 (2026-07-08): `isWriteRequest` in `en-server/app/Middleware.hs` re-pointed at
  the `/v1/relationships` prefix; a read-only key gets `403` on both write routes and
  `200` on `/v1/check`.
- [x] M2 (2026-07-08): `en-client/src/En/Client.hs` comment and `Justfile`
  (`test-server`) updated; `docs/user/service-and-operations.md` and
  `docs/user/production-deployment-and-performance.md` swept for old shapes; an "API
  versioning" section added documenting the discriminators and the one-time break.
- [x] M3 (2026-07-08): typed error envelope (`ErrorEnvelopeWire`) in Seam.hs with the
  `EnError -> EnFault` mapping (`status`, `code`, `retryable`); `requirePermission` and
  handler 400s migrated onto it. Table test pins all six `EnError` constructors.
- [x] M3 (2026-07-08): uniform JSON errors for body-decode/404 via Servant
  `ErrorFormatters` and `serveWithContext`; 405 observed to return an empty body (see
  Surprises). Verified with PostgreSQL stopped: `503`, `store_error`,
  `"retryable":true`, generic message, SQL detail on stderr only.
- [ ] M3b: the six operations become `MultiVerb` endpoints over the shared response list
  `EnResponses`; handlers return `EnResult` instead of throwing; `AsUnion` instance
  written by hand.
- [ ] M3b: `en-client/src/En/Client.hs` operations re-typed to `ClientM (EnResult …)`;
  `en-servant/test/Main.hs` assertions moved onto `EnResult`.
- [ ] M4: OpenAPI document generated with servant-openapi-hs and served at
  `GET /v1/openapi.json`; `ToSchema` instances hand-written to match the JSON grammar;
  every operation documents its 400/422/503 responses.
- [ ] Final: full curl transcript reproduced; `cabal test en-servant` and
  `just start-and-test` green; breaking change called out in
  `docs/user/service-and-operations.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Exact-bytes goldens are stable, and no fallback was needed.** The plan anticipated
  that `Data.Aeson.encode` might not fix object key order (aeson 2's `KeyMap` does not
  promise one) and permitted comparing decoded `Value`s instead. Defining `toEncoding`
  explicitly for every type removes the question: `encode` goes through `toEncoding`,
  whose `pairs` builder emits fields in written order. All 40 golden assertions passed
  on the first run against the bytes written into the plan's grammar. This is also a
  small win on the response path, which no longer materializes an intermediate `Value`.

- **`Data.Aeson.object` collides with the `object` record field.** `en-core`'s `Tuple`
  and `BatchPair` export an `object` field selector (those packages do not use
  `NoFieldSelectors`), and `En.Servant.API` imports both. Every use of aeson's `object`
  in the new instances was ambiguous. Resolved by importing `Data.Aeson qualified as
  Aeson` and writing `Aeson.object`; `.=`, `.:`, `.:?`, `pairs`, and `withObject` stay
  unqualified. Any sibling plan hand-writing aeson instances in a module that imports
  `En.Tuple` or `En.Check` will hit the same wall.

- **`en-servant` lacked `BlockArguments`.** `en-core` and `en-server` enable it; the
  `withObject "…" \o -> …` idiom needs it. Added to `default-extensions` in
  `en-servant/en-servant.cabal`, matching the two siblings.

- **`DELETE /v1/relationships` returns 405, not 404.** The plan's acceptance criterion
  allowed either. Servant matches the path, finds no `DELETE` verb, and returns
  `405 Method Not Allowed` with an empty body — importantly, without consuming the
  request body, which was the point of retiring `DELETE`-with-body. Old unversioned
  paths (`/tuples`, `/check`) return `404`. Both bodies are currently non-JSON; M3's
  `ErrorFormatters` reach the 404 but not the 405.

- **`isWriteRequest` is now a prefix match, not an equality test.** EP-33's predicate
  compared `pathInfo == ["tuples"]`; the replacement matches
  `"v1" : "relationships" : _` with `POST`, so it covers both `/v1/relationships` and
  `/v1/relationships/delete` and will cover any future write sub-route added under that
  prefix. Verified with a read-only key: `403` on both write routes, `200` on
  `/v1/check`. `methodDelete` is no longer imported in
  `en-server/app/Middleware.hs`.

- **An unknown discriminator surfaces as `malformed_request_body`, not its own code.**
  The `FromJSON` instances reject `{"mode":"freshest"}`, but that failure happens inside
  Servant's `ReqBody` combinator, so it reaches the client through
  `bodyParserErrorFormatter`. The message is still precise — `Error in $.consistency:
  unknown consistency mode "freshest"; expected minimizeLatency, fullyConsistent,
  atLeastAsFresh, atExactSnapshot` — because aeson prepends the JSON path. This is the
  right outcome (a bad discriminator *is* a malformed body), and it is worth knowing
  that no amount of instance work can give it a distinct code.

- **`405` and `415` bodies stay empty; `ErrorFormatters` cannot reach them.** Confirmed
  with curl: `DELETE /v1/relationships` returns `405` with a zero-length body and no
  `Content-Type`. `ErrorFormatters` has hooks only for body-parse, URL-parse,
  header-parse, and not-found. The plan offered an outermost WAI middleware in `app` to
  rewrite bodyless 4xx responses into the envelope; **not done**, because en-server
  already composes WAI middleware in `en-server/app/Main.hs` and EP-36 owns that stack.
  A 405 reaching a client means the client used the wrong verb — a programming error,
  not a runtime condition it must parse. Recorded here so EP-36 can add the rewrite if
  it wants uniformity.

- **`InvalidConsistencyToken` messages leak an internal constructor name.** A garbage
  token yields `{"code":"invalid_consistency_token","message":"TokenBadPrefix",…}`. The
  `code` is stable and correct, and `message` is explicitly prose that clients must not
  branch on, so the contract holds — but `TokenBadPrefix` is the `Show` output of an
  engine-internal type flowing through `En.Revision`'s `EnError` payload. Cosmetic, and
  out of scope here (this plan changes representation, not engine text). Whichever plan
  next touches `En.Revision`'s token parsing should give it human prose.

- **This plan closes the loop on EP-34's database-restart finding.** The master plan
  records that a PostgreSQL restart costs `2 × (established connections)` failed
  requests, and that the first failure per stale connection is a *statement*-level error
  whose text (`Unexpected number of rows …`) reads like a row-decoding bug. Both now
  reach the client as `503 store_error` with `"retryable":true`, because
  `enErrorToFault` classifies on the `EnError` constructor — `StoreError` — and never on
  message text, exactly as EP-34 warned it must. Verified by stopping PostgreSQL under
  load: four consecutive probes all returned the same retryable envelope, and the
  underlying socket error appeared only on the server's stderr.

- **`.:?` already handles explicit `null`.** `TupleWire.caveat` encodes as
  `"caveat":null` and decodes from either an explicit `null` or an absent key, because
  aeson's `FromJSON1 Maybe` instance maps `Null` to `Nothing`. No custom parser was
  needed, and a test pins both spellings.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make this one deliberate breaking cut — replace the unversioned paths and
  generic encodings outright rather than serving old and new side by side.
  Rationale: en-server is not yet deployable as a service (its API is unauthenticated
  until EP-33 lands, per the review's verdict), so there are no external wire consumers
  to migrate; the only in-repo consumers are en-client and the Justfile smoke test,
  both updated here. Carrying a compatibility shim for a format with constructor-tag
  leakage would enshrine exactly what this plan removes. The `/v1` prefix is the
  mechanism that makes *future* breaks stageable.
  Date: 2026-07-07
- Decision: Group wire versioning, error typing, and OpenAPI generation in one plan.
  Rationale: Restated from the master plan's Decision Log
  (`docs/masterplans/6-production-harden-the-en-service.md`): all three are breaking
  changes to the same JSON surface; clients should migrate once, not three times.
  Date: 2026-07-07
- Decision: Keep the Haskell-side type names (`CheckRequestWire` etc.) unchanged; only
  the JSON representation changes, via hand-written instances with a discriminator
  field per sum type (`kind` for subjects and expand nodes, `mode` for consistency,
  `result` for decisions, `status` for page states, `type` for caveat values).
  Rationale: The `Wire` suffix is a useful internal convention; the review's complaint
  is that it *leaks onto the wire*, not that it exists. Hand-written instances make the
  wire shape a reviewed artifact instead of a derivation side effect, and the named
  discriminators read naturally in every consumer language. `type` is kept for caveat
  values specifically because the storage layer already encodes payloads as
  `{"type": …, "value": …}` (see `caveatValueToJson` in
  `en-postgres/src/En/Postgres/TupleStore.hs`), so wire and storage agree.
  Date: 2026-07-07
- Decision: Replace `DELETE /tuples` with `POST /v1/relationships/delete`, and rename
  the write route to `POST /v1/relationships`.
  Rationale: DELETE with a request body is explicitly undefined-ish in HTTP semantics
  and dropped by real proxies (finding A5). Delete-as-POST-verb-suffix is the pattern
  the reference systems use (SpiceDB `DeleteRelationships`, OpenFGA `write` with
  deletes). Renaming `tuples` to `relationships` at the same time aligns the path with
  the domain vocabulary used across the docs, and costs nothing extra since every path
  moves under `/v1` anyway. New endpoints added by
  `docs/masterplans/9-complete-the-en-api-surface.md` must live under the same `/v1`
  prefix and envelope.
  Date: 2026-07-07
- Decision: Error envelope is `{"code": <stable snake_case string>, "message": <human
  text>, "retryable": <bool>}`; the `EnError -> (status, code, retryable)` mapping is
  the table in Milestone 3, with `StoreError` details logged server-side but replaced by
  a generic message on the wire.
  Rationale: `code` gives machines a stable contract that `Show` output never was;
  `retryable` lets clients implement retry policy without parsing prose (store outages
  are retryable, token/schema faults are not). Raw `StoreError` text contains SQL and
  parameter details (`Hasql.toDetailedText`) — an information leak flagged by A3 — so
  it must not cross the trust boundary.
  Date: 2026-07-07
- Decision: Adopt Servant's `MultiVerb` for the six operations, so handler-produced
  errors are alternatives of the API type rather than thrown `ServerError`s. Added to
  this plan as milestone M3b rather than deferred to a follow-up.
  Rationale: `MultiVerb` changes the *Haskell* types, not a single JSON byte — the
  statuses and `{code, message, retryable}` bodies are identical either way — so
  adopting it is not a second break of the `/v1` wire contract, only of `en-client`'s
  Haskell shape. en currently has no API consumers, which makes that break free now and
  expensive later; that is the whole reason to do it before anyone depends on the
  client. The payoff is that M4's OpenAPI document lists each operation's real error
  responses instead of one hand-attached "default error response", and callers of
  `en-client` pattern-match a typed result instead of inspecting an opaque
  `ClientError`. Verified beforehand that the toolchain supports it: servant 0.20.3
  ships `Servant.API.MultiVerb` with a `HasServer` instance;
  `servant-client-core` defines `Client m (MultiVerb method cs as r) = m r`; and the
  pinned `shinzui/servant-openapi-hs` fork carries a dedicated MultiVerb `HasOpenApi`
  port (`MultiVerbStatus`, `IsSwaggerResponseList`) that keys responses by status and
  merges alternatives sharing one.
  Date: 2026-07-08
- Decision: Give all six operations one uniform response list `EnResponses`
  (200/400/422/503) rather than a narrower list for the two write routes.
  Rationale: `ResolutionLimitExceeded` (422) arises from graph traversal, so a write
  cannot in practice emit it — but `EnError` is a single closed sum shared by every
  operation, and the type system cannot prove the write path never produces that
  constructor. A write-specific response list would make `EnError -> WriteResult` a
  partial function, which is a real defect traded for a cosmetic gain. One total
  conversion and a slightly over-broad OpenAPI document is the better trade; the
  response descriptions say what each status means.
  Date: 2026-07-08
- Decision: Keep `MultiVerb` for handler errors and `ErrorFormatters` for framework
  errors, rather than trying to express everything one way.
  Rationale: `malformed_request_body`, `not_found`, the 405 on a wrong method, and 415
  content-type mismatches are raised by Servant's routing layer before any handler runs,
  so no response type on the endpoint can describe them. EP-33's `unauthenticated`,
  `permission_denied`, and `rate_limited` come from WAI middleware, outside Servant
  entirely. `MultiVerb` therefore complements the envelope rather than replacing it;
  both paths emit `ErrorEnvelopeWire`.
  Date: 2026-07-08
- Decision: Retain the throwing `runEngine` and `enErrorToServerError` alongside the new
  value-returning `runEngineEither`.
  Rationale: `requirePermission` in `En.Servant.Authorize` is a helper for *embedded*
  host applications' own Servant routes, not an operation of `EnAPI`. It has no
  `MultiVerb` response list to return into, so it must keep throwing a `ServerError` —
  now carrying the envelope with code `permission_denied`.
  Date: 2026-07-08
- Decision: Generate the OpenAPI document with `servant-openapi-hs` (the mori-registered
  fork of `servant-openapi3` at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`, GitHub
  `shinzui/servant-openapi-hs`, together with its `openapi-hs` data-model dependency,
  GitHub `shinzui/openapi-hs`) pinned via `source-repository-package` in
  `cabal.project`, rather than Hackage `servant-openapi3`.
  Rationale: Hackage `servant-openapi3`/`openapi3` do not build against this project's
  GHC 9.12.4 / servant 0.20.3 without patches; the fork targets exactly this toolchain
  (its cabal file requires `base >=4.21`) and emits OpenAPI 3.1. The pin follows the
  existing precedent in `cabal.project` (the biscuit-haskell pin). Hand-written
  `ToSchema` instances are required so the document matches the hand-written JSON —
  and the golden tests in M1 are what keep both honest.
  Date: 2026-07-07
- Decision: Define `toEncoding` explicitly alongside `toJSON` for every wire type,
  rather than letting it default to `Data.Aeson.Encoding.value . toJSON`.
  Rationale: It is what makes the exact-bytes golden tests this plan calls for both
  possible and stable — `encode` routes through `toEncoding`, whose field order is the
  order written. It also removes an intermediate `Value` allocation from every HTTP
  response. The cost is that each type states its field order twice; the golden tests
  catch any drift between the two.
  Date: 2026-07-08
- Decision: Move the `Justfile` `test-server` request bodies to the new JSON grammar in
  M1, ahead of the M2 path change, instead of leaving the smoke test broken across one
  commit.
  Rationale: The exec-plan protocol requires each commit to leave the codebase in a
  working state. M1 breaks the old request bodies (the server no longer accepts
  `{"tag":…}`) while leaving the paths intact, so the bodies can move independently of
  the paths. M2 then changes only the paths and the delete verb.
  Date: 2026-07-08
- Decision: Also export `CaveatPayloadWire`, `LookupStateWire`, and `ExpandStateWire`
  from `En.Servant.API`.
  Rationale: The golden tests must construct a value of every type whose encoding they
  pin, and these three were reachable only through their parents. They are part of the
  wire contract either way; hiding them made the contract untestable, not smaller.
  Date: 2026-07-08
- Decision: `checkMany`'s per-pair behavior (errors collapse to `Denied`,
  finding B5) is out of scope; the batch response stays a positional `decisions` array.
  Rationale: Changing batch semantics is an engine-behavior change owned by the
  evaluation master plan (`docs/masterplans/7-fix-the-en-evaluation-engine.md`). This
  plan changes representation only; the array is already wrapped in an object
  (`{"decisions": […]}`), so enriching entries later is non-breaking.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

en is a Haskell workspace at `/Users/shinzui/Keikaku/bokuno/en` built with `cabal`
(GHC 9.12.4). The HTTP layer is the `en-servant` package:

- `en-servant/src/En/Servant/API.hs` defines the Servant API type `EnAPI` (six routes:
  `POST /tuples`, `DELETE /tuples` with a JSON body, `POST /check`, `POST /batch-check`,
  `POST /lookup`, `POST /expand`), all the `*Wire` request/response types, the handlers,
  and pure `…ToWire`/`…FromWire` converters between wire types and engine types. Every
  wire type currently ends with `deriving anyclass (FromJSON, ToJSON)` — aeson's
  *generic* encoding, which for record types produces plain objects (fine) but for sum
  types produces `{"tag": "<ConstructorName>", "contents": …}` (the leak).
- `en-servant/src/En/Servant/Seam.hs` holds `Env` (the record of engine operations),
  `runEngine` (runs an effectful action and converts `Left EnError` into a Servant
  `ServerError`), `enErrorToServerError = jsonError err500 . Text.pack . show` (the A3
  collapse), and `jsonError` (wraps a `Text` message as `{"error": <text>}` via the
  `ErrorWire` newtype).
- `en-servant/src/En/Servant/Authorize.hs` (`requirePermission`) throws
  `jsonError err403 …` — it must move onto the new envelope too.
- `en-servant/test/Main.hs` is a hand-rolled test executable (no tasty/hspec; local
  `assertEqual`/`assertBool` helpers) that exercises handlers through
  `Servant.runHandler` against in-memory stores from `En.Conformance.Kikan`.
- `en-client/src/En/Client.hs` derives a client record from `apiProxy` with
  `Servant.Client.client`; because it is generated from the API *type*, path and wire
  changes propagate automatically once it recompiles.
- `en-core/src/En/Error.hs` defines the closed engine error sum:
  `UnknownRelation Text | SchemaViolation Text | MissingCaveatContext [Text] |
  InvalidConsistencyToken Text | ResolutionLimitExceeded | StoreError Text`.

The current wire shapes are easiest to see in the `Justfile` `test-server` recipe, which
this plan rewrites; today it posts bodies like
`{"subject":{"tag":"SubjectIdWire","contents":{…}}}` and asserts
`.decision.tag == "AllowedWire"`.

Terms of art: a **wire type** is a Haskell record/sum that exists only to define the
JSON contract (as opposed to engine types in en-core); a **discriminator field** is a
JSON property (like `"mode"`) whose string value selects which variant of a sum an
object encodes; **OpenAPI** is the standard machine-readable HTTP API description format
(a JSON document listing paths, request/response schemas, and errors) that client
generators and API explorers consume; a **golden test** asserts that encoding a known
value produces an exact expected byte string, freezing the format.

Integration points restated from the master plan
(`docs/masterplans/6-production-harden-the-en-service.md`): this plan owns the typed
error envelope; EP-33 (`docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md`)
emits a minimal `{"error", "code"}` object for 401/403/429 until this plan lands, and
whichever lands second reconciles EP-33's middleware bodies to the full envelope
(add `retryable: false` to all three). EP-33's write-route predicate
(`pathInfo == ["tuples"]`) must be updated to the new `/v1` paths by whichever plan
lands second. EP-36 uses this envelope for error responses of its endpoints where
applicable. New endpoints from `docs/masterplans/9-complete-the-en-api-surface.md`
extend this same `/v1` surface.


## Plan of Work

Five milestones: stabilize the JSON encodings (M1), move and rename the routes (M2),
type the error model (M3), lift handler errors into the API type with `MultiVerb` (M3b),
and describe it all with OpenAPI (M4). M1 and M2 could land together, but M1 is
independently verifiable through the test suite alone, which keeps review tractable.
M3 and M3b are separated because M3 alone already fixes the wire-visible defect
(finding A3) and is verifiable with curl; M3b then changes only Haskell types, leaving
every byte on the wire identical. Landing them apart makes that claim reviewable — the
curl transcript captured after M3 must reproduce byte-for-byte after M3b.


### Milestone 1: Hand-written, tag-free JSON encodings

Scope: every wire type in `en-servant/src/En/Servant/API.hs` gets explicit
`ToJSON`/`FromJSON` instances implementing the grammar below; the
`deriving anyclass (FromJSON, ToJSON)` clauses are deleted. Record types whose generic
encoding is already a plain object (e.g. `ObjectRefWire`, `TupleWire`,
`CheckRequestWire`) may keep semantically identical hand-written instances or generic
ones — but write them by hand anyway so the whole surface is explicit and future field
renames are deliberate. At the end, `cabal test en-servant` passes with new golden
tests.

The JSON grammar (this is the contract; write it into the instances verbatim):

```json
{"comment": "SubjectWire — discriminator: kind",
 "id":       {"kind":"id","objectType":"user","objectId":"alice"},
 "set":      {"kind":"set","objectType":"group","objectId":"eng","relation":"member"},
 "wildcard": {"kind":"wildcard","objectType":"user"}}
```

```json
{"comment": "ConsistencyWire — discriminator: mode",
 "minimizeLatency": {"mode":"minimizeLatency"},
 "fullyConsistent": {"mode":"fullyConsistent"},
 "atLeastAsFresh":  {"mode":"atLeastAsFresh","token":"en1.…"},
 "atExactSnapshot": {"mode":"atExactSnapshot","token":"en1.…"}}
```

```json
{"comment": "CheckDecisionWire — discriminator: result",
 "allowed":     {"result":"allowed"},
 "denied":      {"result":"denied"},
 "conditional": {"result":"conditional",
                 "obligations":[{"caveat":"business_hours","missingContext":["now"]}]}}
```

```json
{"comment": "CaveatValueWire — discriminator: type (matches storage encoding)",
 "text":      {"type":"text","value":"hello"},
 "bool":      {"type":"bool","value":true},
 "integer":   {"type":"integer","value":42},
 "timestamp": {"type":"timestamp","value":"2026-07-07T12:00:00Z"},
 "enum":      {"type":"enum","value":"read"}}
```

```json
{"comment": "LookupStateWire / ExpandStateWire — discriminator: status",
 "exhausted": {"status":"exhausted"},
 "hasMore":   {"status":"hasMore","cursor":"…"},
 "truncated": {"status":"truncated","cursor":"…"}}
```

```json
{"comment": "ExpandNodeWire — discriminator: kind",
 "subject":  {"kind":"subject","subject":{"kind":"id","objectType":"user","objectId":"alice"}},
 "userset":  {"kind":"userset","object":{"objectType":"group","objectId":"eng"},
              "relation":"member","children":[]},
 "caveated": {"kind":"caveated","caveat":"business_hours","children":[]}}
```

Record types keep their current field names as JSON keys (`objectType`, `objectId`,
`relation`, `subject`, `caveat`, `payload`, `values`, `consistency`, `context`,
`permission`, `object`, `pairs`, `decisions`, `objects`, `state`, `root`, `children`,
`tuples`, `token`, `limit`, `cursor`, `deadlineMillis`). `CheckResponseWire` therefore
becomes `{"decision":{"result":"allowed"}}`; `LookupObjectWire` becomes
`{"object":{…},"decision":{"result":…}}`; `WriteTuplesResponseWire` stays
`{"token":"…"}`. `null` caveats remain `"caveat":null` (encode `Maybe` as the field with
`null`, and accept an absent field on decode — use `.:?` — so clients may omit it).

Write the instances with `Data.Aeson.withObject`/`withText`, `object`/`(.=)`, and
explicit `parseJSON` matching on the discriminator; unknown discriminator values must
fail with a message naming the field and the allowed values (e.g.
`unknown consistency mode "freshest"; expected minimizeLatency, fullyConsistent,
atLeastAsFresh, atExactSnapshot`).

Add golden tests to `en-servant/test/Main.hs` in its existing hand-rolled style: for a
representative value of every wire type, assert
`Data.Aeson.encode value == expectedBytes` (exact `ByteString` — this freezes field
order via `toJSON`'s object construction; if key ordering proves unstable, compare
`decode (encode value) == decode expectedBytes` on `Data.Aeson.Value` instead, and note
it in Surprises & Discoveries), and assert `decode (encode value) == Just value` for
round-tripping, plus one negative decode per sum type (unknown discriminator ⇒
`Nothing`). Add `aeson` and `bytestring` to the test suite's `build-depends` in
`en-servant/en-servant.cabal`.

Acceptance: `cabal test en-servant` passes; `rg '"tag"' en-servant/src` finds nothing;
a grep for `AllowedWire` in encoded output of the tests finds nothing.


### Milestone 2: The /v1 surface and POST-based delete

Scope: routes move under `/v1`; delete loses its body-carrying DELETE. At the end the
server answers only on the new paths and every in-repo consumer uses them.

In `en-servant/src/En/Servant/API.hs`, redefine:

```haskell
type EnAPI =
    "v1" :> ( "relationships" :> ReqBody '[JSON] WriteTuplesRequestWire :> Post '[JSON] WriteTuplesResponseWire
        :<|> "relationships" :> "delete" :> ReqBody '[JSON] DeleteTuplesRequestWire :> Post '[JSON] WriteTuplesResponseWire
        :<|> "check" :> ReqBody '[JSON] CheckRequestWire :> Post '[JSON] CheckResponseWire
        :<|> "batch-check" :> ReqBody '[JSON] BatchCheckRequestWire :> Post '[JSON] BatchCheckResponseWire
        :<|> "lookup" :> ReqBody '[JSON] LookupRequestWire :> Post '[JSON] LookupPageWire
        :<|> "expand" :> ReqBody '[JSON] ExpandRequestWire :> Post '[JSON] ExpandTreeWire )
```

The `Delete` import from Servant goes away; handler order in `server` is unchanged
(write, delete, check, batch, lookup, expand), so `en-servant/test/Main.hs`'s positional
pattern matches (`_write :<|> _delete :<|> …`) still line up — verify, don't assume.
`en-client/src/En/Client.hs` needs no code change beyond recompilation (the record is
derived from `apiProxy`), but update its module comment to note the `/v1` base and that
`ClientEnv`'s `BaseUrl` should point at the host root (the `/v1` prefix is in the API
type, not the `BaseUrl`).

Rewrite the `Justfile` `test-server` recipe to the new paths and shapes:

```bash
curl -sS -X POST "$url/v1/relationships/delete" -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"kind":"id","objectType":"user","objectId":"alice"},"caveat":null}]}'
# write: POST "$url/v1/relationships" with the same tuple body -> {"token":"en1.…"}
# check: consistency {"mode":"atLeastAsFresh","token":"…"}; assert .decision.result == "allowed"
```

(Keep the recipe's existing structure — delete, write capturing `.token`, check
asserting the decision — changing only paths, bodies, and the final
`jq -r '.decision.result'` / `test "$decision" = "allowed"` assertion. Also update the
echoed success message.) Sweep `docs/user/` for old shapes
(`rg -l '"tag"|AllowedWire|/tuples|/check' docs/user Justfile`) and update every hit —
`docs/user/service-and-operations.md`, `docs/user/queries-and-writes.md`, and
`docs/user/getting-started.md` contain curl examples. Add a short "API versioning"
paragraph to `docs/user/service-and-operations.md` stating: the wire contract is
versioned by path; `/v1` is current; this change was breaking and one-time; future
breaking changes ship as `/v2` alongside `/v1`.

Acceptance: `just start-and-test` passes against the new surface; hitting an old path
returns 404 (in the M3 envelope once M3 lands); `cabal build en-client` succeeds.


### Milestone 3: The typed error envelope

Scope: one error shape everywhere, with correct status codes. At the end no handler
path can produce a non-JSON or un-coded error.

In `en-servant/src/En/Servant/Seam.hs`, replace `ErrorWire` with:

```haskell
data ErrorEnvelopeWire = ErrorEnvelopeWire
    { code :: !Text
    , message :: !Text
    , retryable :: !Bool
    }
```

with hand-written instances (`{"code":…,"message":…,"retryable":…}`). Introduce the
fault type that names the status without committing to a transport:

```haskell
-- | A handler-producible failure. The constructor selects the HTTP status.
data EnFault
    = BadRequestFault !ErrorEnvelopeWire     -- ^ 400
    | UnprocessableFault !ErrorEnvelopeWire  -- ^ 422
    | UnavailableFault !ErrorEnvelopeWire    -- ^ 503
```

`EnFault` exists so that M3b's `MultiVerb` alternatives and M3's thrown `ServerError`s
are built from one source of truth. Implement the mapping:

```haskell
enErrorToFault :: EnError -> EnFault
-- UnknownRelation t          -> 400 "unknown_relation"           retryable=False, message names t
-- SchemaViolation t          -> 400 "schema_violation"           retryable=False
-- MissingCaveatContext names -> 400 "missing_caveat_context"     retryable=False, message lists names
-- InvalidConsistencyToken t  -> 400 "invalid_consistency_token"  retryable=False
-- ResolutionLimitExceeded    -> 422 "resolution_limit_exceeded"  retryable=False
-- StoreError _detail         -> 503 "store_error"                retryable=True,
--                               message = "the tuple store failed; retry later"
```

plus `invalidRequest :: Text -> EnFault` (code `invalid_request`) and
`batchTooLarge :: Text -> EnFault` (code `batch_too_large`), both 400/retryable=false,
for the validation failures that are not `EnError`s.

For `StoreError`, print the detailed text to stderr (`Text.hPutStrLn stderr`) before
returning the generic envelope — the operator needs the SQL context, the caller must not
see it (EP-36's structured logging later formalizes this). Do this in one place,
`logEnError :: EnError -> IO ()`, called from the engine runners; the mapping function
itself stays pure.

Keep two engine runners, because they serve different callers:

```haskell
-- Throws; used by requirePermission and any embedded host route.
runEngine :: Env es -> Eff es a -> Handler a
enErrorToServerError :: EnError -> ServerError  -- faultToServerError . enErrorToFault

-- Returns; used by every EnAPI handler once M3b lands.
runEngineEither :: Env es -> Eff es a -> Handler (Either EnFault a)
```

`faultToServerError` attaches the envelope as the body and
`Content-Type: application/json` at the status the constructor names, replacing the old
`jsonError`. Update `requirePermission` in `en-servant/src/En/Servant/Authorize.hs` to
throw a 403 envelope with code `permission_denied` (retryable=false, distinct messages
for `Denied` vs `Conditional`); it has no `MultiVerb` response list to return into, so
it keeps throwing.

Make framework errors uniform. In `API.hs`, change `app` to use `serveWithContext` with
custom `ErrorFormatters` (from `Servant.Server`):

```haskell
app env = serveWithContext apiProxy (customFormatters :. EmptyContext) (server env)
```

where `customFormatters` overrides `bodyParserErrorFormatter` and `urlParseErrorFormatter`
(400, code `"malformed_request_body"`, message = the aeson/parse error text,
retryable=false) and `notFoundErrorFormatter` (404, code `"not_found"`,
retryable=false). Content-type mismatches (415) and method errors (405) fall outside
`ErrorFormatters`; verify their behavior with curl and record the result in Surprises &
Discoveries — if they emit non-JSON bodies, add a small outermost WAI middleware in
`app` that rewrites bodyless 4xx responses into the envelope (keep it inside en-servant
so embedded users get it too).

Add tests to `en-servant/test/Main.hs`: assert `enErrorToFault` maps each of the six
`EnError` constructors to the right status, `code`, and `retryable` (it is pure, so this
is a table test), and that an unknown permission through the real `check` handler
produces `unknown_relation` (the in-memory conformance store yields it naturally).

Acceptance: `cabal test en-servant` passes; the curl transcript in Concrete Steps shows
a 400 with `invalid_consistency_token` for a garbage token, a 400 with
`malformed_request_body` for `{`-truncated JSON, and 404s in the envelope. **Capture
that transcript verbatim — M3b must reproduce it byte for byte.**


### Milestone 3b: Handler errors as MultiVerb response alternatives

Scope: the six operations stop throwing and start returning. At the end every
handler-producible status is a member of the API type, and no byte on the wire has
changed from M3.

In `en-servant/src/En/Servant/API.hs`, define one response list shared by all six
operations, parameterized by the success description and payload:

```haskell
type EnResponses (desc :: Symbol) a =
    '[ Respond 200 desc a
     , Respond 400 "Invalid request" ErrorEnvelopeWire
     , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
     , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
     ]

-- | What a handler returns. 'AsUnion' maps it onto 'EnResponses' positionally.
data EnResult a
    = EnOk a
    | EnClientError !ErrorEnvelopeWire     -- ^ 400
    | EnUnprocessable !ErrorEnvelopeWire   -- ^ 422
    | EnUnavailable !ErrorEnvelopeWire     -- ^ 503
    deriving stock (Eq, Show)
```

Write the `AsUnion` instance by hand rather than deriving it via `GenericAsUnion`: the
generic route needs `Generics.SOP.Generic` and ties constructor order to the response
list implicitly, whereas the hand-written instance states the correspondence in four
lines and fails loudly if the list changes. The final `fromUnion` equation
(`S (S (S (S x))) -> case x of {}`) satisfies the pattern checker; it needs `EmptyCase`,
which `GHC2024` already implies.

```haskell
instance
    AsUnion
        '[ Respond 200 desc a
         , Respond 400 "Invalid request" ErrorEnvelopeWire
         , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
         , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
         ]
        (EnResult a)
```

`Union` is `Data.SOP.NS I`, so the instance body uses `Z`, `S`, and `I` from
`Data.SOP` — add `sop-core` to `en-servant`'s library `build-depends`.

Each route becomes a `MultiVerb`, replacing `Post '[JSON] X`:

```haskell
type EnAPI =
    "v1"
        :> ( "relationships"
                :> ReqBody '[JSON] WriteTuplesRequestWire
                :> MultiVerb 'POST '[JSON]
                    (EnResponses "Consistency token for the write" WriteTuplesResponseWire)
                    (EnResult WriteTuplesResponseWire)
             :<|> …
           )
```

Handlers change from `Handler X` to `Handler (EnResult X)`. The validation helpers that
threw (`either400`, `traverseOr400`) become value-returning; the natural shape is to run
the body in `ExceptT EnFault Handler` and finish with
`either faultToResult EnOk <$> runExceptT …`, where

```haskell
faultToResult :: EnFault -> EnResult a
faultToResult = \case
    BadRequestFault envelope -> EnClientError envelope
    UnprocessableFault envelope -> EnUnprocessable envelope
    UnavailableFault envelope -> EnUnavailable envelope
```

is total — which is the reason all six operations share one response list (see the
Decision Log).

`en-client/src/En/Client.hs` needs a real change now: `Client m (MultiVerb …) = m r`, so
each operation's type becomes `… -> ClientM (EnResult X)`. Update the `EnClient` record
fields accordingly and note in the module comment that callers pattern-match `EnResult`
rather than catching a `ClientError` for engine faults (transport and framework errors
still surface as `ClientError`).

`en-servant/test/Main.hs`: the positional `server env` destructuring is unchanged, but
assertions move onto `EnResult`. The oversized-batch test asserts
`EnClientError` with code `batch_too_large` instead of inspecting `errHTTPCode`, which
is a strictly stronger check. Add a test that a check for an unknown permission returns
`EnClientError` with code `unknown_relation`.

Acceptance: `cabal build all` and `cabal test en-servant` pass; **the M3 curl transcript
replays with identical status codes and identical response bodies** — this is the
milestone's whole claim, so run it and diff, do not assume.


### Milestone 4: OpenAPI document at /v1/openapi.json

Scope: a generated, served API description that provably matches the encodings. At the
end `GET /v1/openapi.json` returns an OpenAPI 3.1 document.

Pin the two packages in `cabal.project` following the biscuit precedent — add
`source-repository-package` stanzas for `https://github.com/shinzui/openapi-hs.git` and
`https://github.com/shinzui/servant-openapi-hs.git` at the commits current when you
implement (resolve with `git ls-remote <url> HEAD`; record the chosen tags in the
Decision Log). Add `openapi-hs` and `servant-openapi-hs` to
`en-servant/en-servant.cabal`'s library `build-depends`.

Write hand-written `Data.OpenApi.ToSchema` instances for every wire type in a new module
`en-servant/src/En/Servant/OpenApi.hs` (added to `exposed-modules`), mirroring the M1
grammar — sum types as `oneOf` with the discriminator property enumerated (openapi-hs
exposes the schema-construction API under `Data.OpenApi`; build schemas explicitly
rather than deriving generically, since generic derivation would resurrect the `tag`
shapes M1 deleted). In the same module define:

```haskell
enOpenApi :: Data.OpenApi.OpenApi
enOpenApi = toOpenApi (Proxy :: Proxy EnAPI)
    -- then set info.title = "en authorization API", info.version = "v1".
```

No hand-attached default error response is needed: because M3b made the error statuses
`MultiVerb` alternatives, the fork's `IsSwaggerResponseList` instance emits a
status-keyed `responses` map per operation, so 400/422/503 and their
`ErrorEnvelopeWire` schema appear automatically. `ErrorEnvelopeWire` therefore needs a
`ToSchema` instance alongside the request/response types.

Extend the served API (server-only — keep `EnAPI` as the client-facing six operations so
`en-client` is unaffected):

```haskell
type ServedAPI = EnAPI :<|> ("v1" :> "openapi.json" :> Get '[JSON] Data.OpenApi.OpenApi)

app env = serveWithContext servedProxy (customFormatters :. EmptyContext)
    (server env :<|> pure enOpenApi)
```

Acceptance: `curl -s localhost:8080/v1/openapi.json | jq '.openapi, (.paths | keys)'`
lists the six `/v1/…` paths; the document's `SubjectWire` schema shows the three `kind`
variants; every operation's `responses` object has the keys `200`, `400`, `422`, `503`;
feeding the document to any OpenAPI validator (e.g. `jq empty` for JSON
well-formedness plus a spot check of `components.schemas`) succeeds.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/en`, inside the
nix dev shell.

After each milestone:

```bash
cabal build en-servant en-client en-server
cabal test en-servant
```

Expected: clean builds; the test executable prints its assertions and exits zero.

End-to-end against the dev database (after M2; bodies below are final M1–M3 shapes):

```bash
just process-up
just run-migrations
EN_DATABASE_URL="$PG_CONNECTION_STRING" cabal run en-server &

# write
curl -s -X POST localhost:8080/v1/relationships -H 'content-type: application/json' \
  -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"kind":"id","objectType":"user","objectId":"alice"},"caveat":null}]}'
# -> {"token":"en1.…"}

# check with the returned token
curl -s -X POST localhost:8080/v1/check -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"atLeastAsFresh","token":"<paste>"},"context":{"values":{}},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}'
# -> {"decision":{"result":"allowed"}}

# error model: garbage token -> 400, typed
curl -si -X POST localhost:8080/v1/check -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"atLeastAsFresh","token":"garbage"},"context":{"values":{}},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}' | head -1
curl -s  -X POST localhost:8080/v1/check -H 'content-type: application/json' -d '{"consistency"' 
# -> HTTP/1.1 400 …; {"code":"invalid_consistency_token", …}
# -> {"code":"malformed_request_body","message":"…","retryable":false}

# old path is gone
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/check -d '{}' -H 'content-type: application/json'
# -> 404

# openapi (after M4)
curl -s localhost:8080/v1/openapi.json | jq -r '.paths | keys[]'
# -> /v1/batch-check … /v1/relationships … /v1/relationships/delete …
```

Then the maintained smoke test:

```bash
just start-and-test
```

Expected final line (message updated in M2): `server smoke test passed: allowed`.

If EP-33 has landed, export its dev key and add the `Authorization` header to the curls
above; the Justfile recipe already carries it in that case.


## Validation and Acceptance

Acceptance is observable behavior:

1. Encodings: the golden tests in `en-servant/test/Main.hs` pin every wire shape in
   this plan's grammar; `rg '"tag"' en-servant/src Justfile docs/user` finds no wire
   examples with constructor tags.
2. Versioned surface: all six operations answer under `/v1/…`; the unversioned paths
   return 404 in the error envelope; deletion is `POST /v1/relationships/delete` and
   `DELETE` anywhere returns 404/405 (never consuming a body).
3. Error typing: a stale/garbage consistency token yields status 400 with code
   `invalid_consistency_token`; an unknown permission yields 400 `unknown_relation`;
   stopping PostgreSQL (`pg_ctl stop -D "$PGDATA"`) and issuing a check yields 503 with
   code `store_error` and `"retryable":true`, with no SQL text in the body (restart
   PostgreSQL afterwards); truncated JSON yields 400 `malformed_request_body`. Every
   one of these bodies has exactly the keys `code`, `message`, `retryable` and
   `Content-Type: application/json`.
4. Typed errors: every handler-producible status is an alternative of the API type. In
   `en-servant/test/Main.hs`, an oversized batch returns `EnClientError` with code
   `batch_too_large` and an unknown permission returns `EnClientError` with code
   `unknown_relation` — as values, not thrown `ServerError`s. `MultiVerb` changed no
   byte on the wire: the M3 curl transcript replays identically after M3b.
5. OpenAPI: `GET /v1/openapi.json` returns a document whose `paths` set equals the
   served operations, whose schemas use the discriminators from M1, and each of whose
   operations documents `200`, `400`, `422`, and `503` responses.
6. Consumers: `cabal build en-client` succeeds; `just start-and-test` passes;
   `cabal test en-servant` passes; `cabal build all` passes.

The breaking change is accepted as complete only when the docs sweep (M2) leaves no
example of the old format anywhere under `docs/user/` or in the `Justfile`.


## Idempotence and Recovery

All steps are compile-and-test cycles — safe to repeat arbitrarily. The wire change
itself carries no data migration: consistency tokens, cursors, and stored tuples are
unaffected (tokens are opaque `Text` on the wire in both formats). The one coordination
hazard is in-repo: this plan edits `en-servant/src/En/Servant/API.hs`, `Seam.hs`, and
the `Justfile`, which EP-33/EP-36/EP-38 also touch — land whole milestones and rebase
siblings rather than interleaving. If M4's `source-repository-package` pins fail to
build, M1–M3 stand alone and must be landed anyway; record the failure in Surprises &
Discoveries and open the OpenAPI milestone as a follow-up rather than blocking the error
model on it. Reverting any milestone is a clean `git revert` since no state outlives the
process.


## Interfaces and Dependencies

Changed interfaces (all full module paths):

- `En.Servant.API` (`en-servant/src/En/Servant/API.hs`): `EnAPI` re-rooted under `/v1`
  with `relationships`/`relationships/delete`; hand-written aeson instances for
  `ObjectRefWire`, `SubjectWire`, `CaveatValueWire`, `CaveatPayloadWire`,
  `CaveatContextWire`, `TupleCaveatWire`, `TupleWire`, `ConsistencyWire`,
  `CheckRequestWire`, `CheckDecisionWire`, `CaveatObligationWire`, `CheckResponseWire`,
  `BatchCheckPairWire`, `BatchCheckRequestWire`, `BatchCheckResponseWire`,
  `LookupRequestWire`, `LookupObjectWire`, `LookupStateWire`, `LookupPageWire`,
  `ExpandRequestWire`, `ExpandNodeWire`, `ExpandStateWire`, `ExpandTreeWire`,
  `WriteTuplesRequestWire`, `DeleteTuplesRequestWire`, `WriteTuplesResponseWire`;
  `app` switches to `serveWithContext` with `ErrorFormatters`; each route becomes a
  `MultiVerb 'POST '[JSON] (EnResponses desc a) (EnResult a)` (M3b), and the module
  gains `EnResponses`, `EnResult (..)`, and the hand-written `AsUnion` instance.
- `En.Servant.Seam` (`en-servant/src/En/Servant/Seam.hs`): `ErrorWire` replaced by
  `ErrorEnvelopeWire { code :: Text, message :: Text, retryable :: Bool }`; new
  `EnFault` with `enErrorToFault :: EnError -> EnFault` implementing the M3 mapping
  table, plus `invalidRequest`, `batchTooLarge`, `faultToServerError`, and
  `logEnError`; `jsonError` removed in favor of `faultToServerError`;
  `enErrorToServerError :: EnError -> ServerError` retained for the throwing path;
  new `runEngineEither :: Env es -> Eff es a -> Handler (Either EnFault a)` alongside
  the existing `runEngine`.
- `En.Servant.Authorize` (`en-servant/src/En/Servant/Authorize.hs`): 403s emitted in
  the envelope with code `permission_denied`. Still throws — it is an embedded-host
  helper, not an `EnAPI` operation.
- New module `En.Servant.OpenApi` (`en-servant/src/En/Servant/OpenApi.hs`):
  `enOpenApi :: OpenApi` plus `ToSchema` instances (including `ErrorEnvelopeWire`);
  `exposed-modules` updated in `en-servant/en-servant.cabal`.
- `En.Client` (`en-client/src/En/Client.hs`): **breaking Haskell-API change** — each
  `EnClient` field is re-typed from `… -> ClientM X` to `… -> ClientM (EnResult X)`,
  because `Client m (MultiVerb method cs as r) = m r`. The JSON on the wire is
  unchanged. Module comment updated.

Dependencies: `en-servant/en-servant.cabal` library gains `sop-core` (M3b) and
`openapi-hs` + `servant-openapi-hs` (M4); its test suite gains `aeson` and `bytestring`
(M1) and `time` (M1 goldens). `BlockArguments` added to its `default-extensions` (M1).
`cabal.project` gains two `source-repository-package` pins (GitHub `shinzui/openapi-hs`
and `shinzui/servant-openapi-hs`, commits recorded at implementation time). No changes
to `en-core`, `en-postgres`, or `en-biscuit`.

Wire contract at the end (the artifact other plans and
`docs/masterplans/9-complete-the-en-api-surface.md` build on): six operations under
`/v1`, the M1 JSON grammar, the `{code, message, retryable}` envelope with codes
`unknown_relation`, `schema_violation`, `missing_caveat_context`,
`invalid_consistency_token`, `resolution_limit_exceeded`, `store_error`,
`invalid_request`, `batch_too_large`, `malformed_request_body`, `not_found`,
`permission_denied` (plus EP-33's `unauthenticated` and `rate_limited`), and
`GET /v1/openapi.json`. New endpoints added by
`docs/masterplans/9-complete-the-en-api-surface.md` should be `MultiVerb` endpoints over
`EnResponses` so their error responses are documented on the same terms.


## Revision Note — 2026-07-08

**What changed.** Added milestone M3b: the six operations become Servant `MultiVerb`
endpoints whose response alternatives enumerate the statuses they can return, so
handler-produced errors live in the API type rather than being thrown as untyped
`ServerError`s. Restructured M3 around a new `EnFault` type shared by the throwing and
returning paths. M4 no longer hand-attaches a default error response, because MultiVerb
now supplies per-operation error responses to the OpenAPI generator. `en-client`'s six
operations are re-typed to `ClientM (EnResult …)`, which the plan previously promised
would not change.

**Why.** The original plan made the error *bytes* consistent but left the error *types*
invisible: the OpenAPI document would have listed only 200 responses, and `en-client`
callers would still have inspected an opaque `ClientError`. MultiVerb fixes both.
Crucially it changes no JSON: the statuses and envelope bodies are identical either way,
so this is a break of `en-client`'s Haskell shape, not of the `/v1` wire contract. en
has no API consumers today, which makes that break free now and costly once anyone
depends on the client — the same reasoning that motivated the one-time wire break in the
first place. Verified before committing to it that servant 0.20.3 ships
`Servant.API.MultiVerb` with a `HasServer` instance, that `servant-client-core` defines
`Client m (MultiVerb method cs as r) = m r`, and that the already-pinned
`shinzui/servant-openapi-hs` fork carries a MultiVerb `HasOpenApi` port. See the four
Decision Log entries dated 2026-07-08.

Sections revised: Purpose / Big Picture, Progress, Decision Log, Plan of Work
(overview, Milestone 3, new Milestone 3b, Milestone 4), Validation and Acceptance,
Interfaces and Dependencies.
