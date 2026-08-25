---
id: 61
slug: adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit
title: "Adopt RFC 9457 problem details and close the API conformance audit"
kind: exec-plan
created_at: 2026-07-22T04:59:56Z
intention: "intention_01m0xaavwqeznrgzs3j67m0q21"
master_plan: "docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md"
---

# Adopt RFC 9457 problem details and close the API conformance audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`en` is a Zanzibar-style relationship-based authorization service: it stores relationship
*tuples* (facts like "user:alice is `viewer` of space:project-x") and answers questions about
them over HTTP — `check` (may this subject do this?), `lookup` (which objects may this subject
reach?), `expand` (show me the subject tree behind this permission), a `watch` feed, a grant-
minting endpoint, and the writes that create and delete tuples. Today, when any of those fails,
`en` answers with a shape it invented for itself:

```json
{"code":"store_error","message":"the tuple store failed; retry later","retryable":true}
```

served under the media type `application/json`. Every other service in this fleet has moved to
**RFC 9457 problem details** — an IETF-standard error body served as `application/problem+json`
— so a client that talks to two services needs two error decoders, a log pipeline needs two
parsers, and no off-the-shelf HTTP tooling recognizes either. After this change `en` answers the
same failure like this, under `application/problem+json`:

```json
{"type":"about:blank","title":"Store unavailable","status":503,
 "detail":"the tuple store failed; retry later","code":"store_error","retryable":true}
```

**Nothing a client branches on changes.** The `code` strings — all twenty of them, from
`unknown_relation` to `rate_limited` — carry forward *verbatim*, because the migration changes the
envelope, not the vocabulary. A client that switched on `code` today keeps working by reading
`code` out of a differently-shaped object; the old `message` prose moves to `detail`; `status`
and a human-readable `title` are added; and the media type becomes self-describing, so a problem
body found in a HAR file or a log line still says what it is.

Three further defects, all found by a conformance audit recorded in
`docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`, are fixed in the same
pass because each of them changes the same wire and downstream deserves one coordinated break
rather than four:

**A caller is currently told to retry requests that can never succeed.** `en` has no `500`
response anywhere. Every failure that reaches it from PostgreSQL becomes `store_error` — HTTP
`503`, `retryable: true`. That is right for an unreachable database and wrong for the two cases
that are genuinely `en`'s own fault: a stored `caveat_payload` that no longer decodes (the row
decoder fails the statement), and a freshly minted write token that will not parse. Both are
bugs in `en`, not outages in a dependency, and a client obeying `retryable` will hammer them
forever. After this change those answer `500` with `retryable: false`, and a real outage still
answers `503` with `retryable: true`.

**`POST /v1/grants` answers two statuses that appear in no type, no document, and no client
signature.** It is the one operation that throws `Servant.ServerError` instead of declaring its
responses: `404` when grant minting is disabled, `403` when the authorization decision was not
`Allowed`. Neither reaches `docs/api/openapi.json` (which lists only `200` and a body-parse
`400`) nor `en-client`, whose `mintGrant` returns the success payload so those two outcomes
surface as an opaque transport error. After this change both are declared response alternatives
and a caller can pattern-match them like every other en outcome.

**The published API document says the service is unauthenticated; the server rejects
unauthenticated requests.** `en-server` requires an `Authorization: Bearer <key>` header on every
request by default, but `docs/api/openapi.json` declares no security scheme, so a client
generated from that artifact sends no header and gets `401` on every call. After this change the
document declares the scheme and every operation requires it.

You can see all of this working without reading any Haskell. Start the server, send a malformed
body, and observe a problem document with the right media type; ask for a grant on a server with
minting disabled and get a declared, documented `404`; and read `docs/api/openapi.json` to see
`application/problem+json` under every error response and a `bearerAuth` requirement on every
operation. The exact commands and expected output are in Validation and Acceptance below.


## Progress

- [x] (2026-08-25 22:22Z) Established the implementation baseline: `cabal build all` and
      `just openapi` passed. `cabal test all` reproduced EP-63's pre-existing
      `en-biscuit-tests` authorization timeout; the other seven suites passed, including
      `en-servant-tests` and the PostgreSQL integration suite.
- [x] (2026-08-25 22:22Z) Milestone 1 — Built the machinery in isolation (`ProblemDetails`, the `ProblemJSON` content
      type, the spec catalog, the two renderers), add the `http-media` dependency and the OpenAPI
      cohort bounds to `en-servant/en-servant.cabal`, and prove the machinery with a throwaway
      spike that exercises **three** legs: the wire's media type, a client round-trip, and the
      generated document's content keys on *both* the error and the success alternative. Legs 2
      and 3 fail on en's resolved packages unless the workarounds recorded in the Decision Log
      are applied — watch them fail first. No production route changes.
- [ ] Milestone 2 — Convert the whole servant surface: the shared `EnResponses` list, `EnResult`,
      the hand-written `AsUnion`, `EnFault`, `enErrorToFault`, every thrown `ServerError`, and
      `envelopeFormatters` (setting all four hooks, not three). Widen every `MultiVerb`'s
      content-type list to `'[JSON, ProblemJSON]`, without which `en-client` rejects every error
      response at runtime. Add the WAI middleware that rewrites servant's empty `405` and install
      it inside `En.Servant.API.app`. Delete `ErrorEnvelopeWire`.
- [ ] Milestone 3 — Add the `500` arm and stop mislabelling internal faults as retryable `503`s.
      Split `En.Error.EnError`'s store failures into a dependency outage and an internal fault,
      classify hasql's `SessionError` structurally in `en-postgres`, and grow the response list,
      the result sum, and the exhaustiveness witness.
- [ ] Milestone 4 — Make `POST /v1/grants` declare its statuses: a `MintGrantResponses` list
      (shared tail plus `403` and `404`), a result sum, a hand-written `AsUnion`, a handler that
      returns rather than throws, and an `en-client` field that surfaces the outcomes as values.
- [ ] Milestone 5 — Convert `en-server`: the authentication, read-only-key, and rate-limit
      rejections in `en-server/app/Middleware.hs`, and the `/readyz` failure body in
      `en-server/app/Health.hs`. Delete the duplicated `errorBody` helper in favour of the shared
      renderer.
- [ ] Milestone 6 — Close the OpenAPI half: narrow each **success** response's content map to the
      media type actually served (the errors arrive keyed correctly; see the 2026-08-25 Decision
      Log entry), bridge `ToSchema ProblemDetails` through
      the codec's own aeson `Options`, declare the bearer security scheme and require it on every
      operation, add the conformance tests (errors keyed by `application/problem+json` and
      successes not; every documented code present in the catalog at the status it is sent with;
      security on every operation), regenerate and check in `docs/api/openapi.json`.
- [ ] Milestone 7 — Update the documents of record: amend
      `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md` (which specifies the
      `ErrorEnvelopeWire` contract this plan replaces), and mark follow-ups (1) through (4) closed
      in `docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`.


## Surprises & Discoveries

- Discovery (2026-08-25, EP-61 Milestone 1 spike): **the resolved Servant client still has the
  exact runtime failure the plan predicts.** With the throwaway route's verb list temporarily
  narrowed to `'[JSON]`, the wire test passed but the real generated client returned:

  ```text
  Left (UnsupportedContentType application/problem+json (Response {responseStatusCode = 400, ...}))
  ```

  Restoring `'[JSON, ProblemJSON]` makes the client return the typed `ProblemSpikeBad` value.
  The OpenAPI leg simultaneously confirms the released generator keys the `400` only by
  `application/problem+json` and exposes the known success-content pollution for Milestone 6.

- Discovery (2026-08-25, EP-61 Milestone 1): **the plan understated the direct dependencies of
  its own shared WAI renderer.** `problemResponse` necessarily imports `Response` and
  `responseLBS` from `wai`, and building the new module exposed that `http-types` is also needed
  directly for its `Header` and `Status` values. Both packages were already in en's resolved
  closure and test stanza, but Cabal correctly rejected relying on them transitively. The
  library stanza now declares `wai` and `http-types` alongside the planned `http-media`.

- Discovery (2026-08-25, implementation baseline): **the known Biscuit smoke-test timeout is
  still intermittent and remains unrelated to the HTTP-contract work.** The baseline
  `cabal test all` run failed only `en-biscuit-tests` with `authorization rejected: Timeout`;
  all seven other suites passed. EP-63 already recorded the same baseline flake, so milestone
  validation runs the affected suite separately and reports both results rather than
  attributing the timeout to this plan.

- Discovery (2026-07-22, while planning): **the `MultiVerb`-style reference implementation this
  plan was told to follow does not exist as code.** The canonical convention document names
  "kotei (ExecPlan 46 in the kotei repository)" as the `MultiVerb`-style adopter. That repository's
  HEAD commit is `71fcf76 docs(plans): add plan 46 — vertical slices, MultiVerb, RFC 7807`, and it
  adds only the plan document: `kotei-api` contains `Kotei/Api.hs`, `Kotei/Api/Client.hs`,
  `Kotei/Api/Types.hs`, and `test/Spec.hs` — no `Response.hs`, and `grep -rl ProblemDetails` over
  the whole repository matches only the plan file. Shomei's own `MultiVerb` plan (its ExecPlan 48)
  is likewise unimplemented. **What *is* shipped is shomei's `ServerError`-style adoption**
  (`shomei-servant/src/Shomei/Servant/Error.hs`, 482 lines, plus
  `Shomei/Servant/Middleware.hs`), and that is real, running code. The practical consequence for
  this plan: kotei's code blocks are a *design* that has never been compiled, so they are treated
  here as a proposal to verify rather than a pattern to copy — which is why Milestone 1 exists as
  a spike, and why the mechanics below were checked against the servant and OpenAPI package
  sources directly rather than taken on the document's word. Where shomei and kotei disagree,
  this plan follows shomei, because shomei's version has run.
  **Confirmed upstream 2026-08-25**: the canonical document now says this itself — kotei is
  described there as "the `MultiVerb`-style adoption *as a design plan*", with "as of 2026-07-24
  the plan's milestones are unimplemented and no kotei code ships them. For working code, shomei
  is the only reference." Nothing in this plan changes; the finding simply stopped being ours
  alone.

- Discovery (2026-07-22, verified against source): **`RespondAs` does everything this plan needs,
  in stock servant, with no fork and no dependency beyond `http-media`.** From
  `servant/src/Servant/API/MultiVerb.hs`, the combinator is
  `data RespondAs responseContentType (s :: Nat) (description :: Symbol) (a :: Type)` with
  `type instance ResponseType (RespondAs responseContentType s description a) = a` — so the
  payload type is unchanged from `Respond`'s, which is why swapping the combinator leaves the
  `AsUnion` instance's `toUnion`/`fromUnion` bodies and the exhaustiveness witness untouched. The
  server-side instance in `servant-server/src/Servant/Server/Internal/ResponseRender.hs` requires
  only `(KnownStatus s, MimeRender ct a)` and renders via `addContentType @ct`, which is what
  physically stamps the media type on that one response regardless of the verb's content-type
  list; the client-side instance in
  `servant-client-core/src/Servant/Client/Core/MultiVerb/ResponseUnrender.hs` requires only
  `(KnownStatus s, MimeUnrender ct a)`. Both are satisfied by the polymorphic
  `MimeRender`/`MimeUnrender` instances on the `ProblemJSON` marker type.

- Discovery (2026-07-22, verified against source): **`RespondAs` and `RespondEmpty` are
  disambiguated by *kind*, not by overlapping instances, which constrains how the content-type
  marker may be written.** `RespondEmpty s desc` is a synonym for `RespondAs '() s desc ()`, where
  `'()` is the promoted unit of kind `()`, while the general instances restrict the first
  parameter to `(ct :: Type)`. There is no `OVERLAPPING`/`OVERLAPPABLE` pragma anywhere in either
  file. The consequence to respect: **the content-type marker must be a `Type`** — an empty
  `data ProblemJSON` with no constructors is right, and a promoted symbol or type-level list
  would not resolve. `en` uses no `RespondEmpty` today (every operation returns a body), so the
  two never meet here, but the constraint governs how `ProblemJSON` is declared.

- Discovery (2026-07-22, **proved by running the code**, and it falsified the canonical
  document as it then stood): **on the pins en had at the time, a naive `RespondAs ProblemJSON`
  swap breaks the Haskell client at runtime and silently lies in the OpenAPI document. Neither
  failure is a compile error.** **Superseded in part on 2026-08-25**: the *client* half below
  still holds exactly as written and its fix is still required; the *document* half was an
  upstream defect that has since been fixed and released — see the 2026-08-25 entry at the end
  of this section before writing the repair pass (renamed `narrowSuccessContent`).
  The canonical problem-details document stated that "the media type reaches the document
  for free" because the then-pinned `servant-openapi-hs` fork carried
  `IsSwaggerResponse (RespondAs (ct :: Type) s desc a)`. That instance does exist — but the claim
  built on it is wrong, because the *enclosing* instance discards its work. Both failures were
  found by compiling and running probes in `cabal repl en-servant` and `cabal repl en-client`
  against the resolved plan (servant 0.20.3.0, `openapi-hs` 4.1.0, `servant-openapi-hs` 4.1.0,
  read from the pinned unpacks under `dist-newstyle/src/`, which were diffed against the pinned
  tags and confirmed identical).

  **The client.** `HasClient`'s instance for `MultiVerb method cs as r`, in
  `servant-client-core/src/Servant/Client/Core/HasClient.hs`, checks the response's Content-Type
  against `allMime (Proxy @cs)` — the *verb's* content-type list, **not** the per-alternative
  `ct` — and throws when it does not match:

  ```haskell
  c <- getResponseContentType response
  unless (any (M.matches c) accept) $ do
    throwClientError $ UnsupportedContentType c response
    where accept = allMime (Proxy @cs)
  ```

  With `cs = '[JSON]`, `matches "application/problem+json" "application/json"` is `False`
  (http-media compares subtypes), so every error response fails. Run end to end against a real
  warp server, the client returns:

  ```text
  Left (UnsupportedContentType application/problem+json (Response {responseStatusCode =
    Status {statusCode = 400, ...}, responseHeaders = [("Content-Type","application/problem+json")],
    responseBody = "{\"x\":true}"}))
  ```

  The server serves the response perfectly; the client refuses it. Since `En.Client` is built with
  `genericClient`, this would hit **every one of the ten `EnResult` operations** — turning every
  typed error, which is currently a value a caller pattern-matches, into a transport exception.
  That is the exact opposite of what this plan is for.

  **The document.** The fork's `HasOpenApi (MultiVerb method (cs :: [Type]) as r)` instance
  post-processes every response through an `addMime` helper that takes the first value out of the
  response's content map and re-keys the whole map by `allMime cs` — throwing away the media type
  `IsSwaggerResponse (RespondAs …)` just computed. Running `toOpenApi` on a probe API with
  `'[Respond 200 "ok" Int, RespondAs ProblemJSON 400 "bad" Int]`:

  ```text
  cs = '[JSON]              200: application/json, application/json;charset=utf-8
                            400: application/json, application/json;charset=utf-8   <- problem+json erased
  cs = '[JSON, ProblemJSON] 200: application/json, application/json;charset=utf-8, application/problem+json
                            400: application/json, application/json;charset=utf-8, application/problem+json
  ```

  So a naive swap ships a document claiming `application/json` for every error while the wire says
  `application/problem+json` — a divergence between the published contract and the service, with no
  warning. Note this also means Milestone 6's conformance test would *fail* rather than pass, which
  is the good news: the test catches it. The fork's own suite does not — it asserts only that
  certain status codes exist.

  Both failure modes are handled in this plan (see the Decision Log entry on widening the
  content-type list and post-processing the document), and both are the reason Milestone 1's spike
  must exercise the client and the document, not just the wire.

- Discovery (2026-07-22, verified): **`cs = '()` produces a perfect document and is nevertheless
  unusable.** The fork has a second `HasOpenApi` instance for `MultiVerb method '() as r` with no
  `addMime` step, and running it yields exactly the desired output —
  `"400": {"content": {"application/problem+json": …}}` with the 200 still plain JSON. It is a dead
  end anyway: `AllMime` is `[Type]`-kinded, so `HasClient`'s head restricts `cs` to `[Type]` and
  GHC reports `There is no instance for HasClient ClientM (MultiVerb POST '() …)`. It would also
  force every alternative to become a `RespondAs`, since there is no `AllMimeRender '()`. Recorded
  so nobody rediscovers it and thinks it is the answer.

- Discovery (2026-07-22, inherited from shomei's experience): **when a dependency is pinned by
  `source-repository-package`, the local working checkout is the wrong source to read.** Shomei
  hit this concretely: its `cabal.project` pinned `openapi-hs` at one tag while the local checkout
  was ahead, and the two disagreed about a type it depended on (`HttpStatusCode` was a data type
  in the checkout and a type synonym at the pin), so code written from the checkout would not
  compile. `en` was in exactly this position on 2026-07-22 — it pinned `openapi-hs` at
  `965340a3…` from GitHub while `/Users/shinzui/Keikaku/bokuno/openapi-hs-project` existed
  locally. **Superseded 2026-08-25**: `en` no longer pins either package by
  `source-repository-package`; both now resolve from Hackage (commit `673ab4b`, "build(deps):
  consume openapi-hs and servant-openapi-hs from Hackage"). The hazard is unchanged in
  substance, only in shape: the local checkout at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project` is the *development* tree and may be ahead
  of the released version en resolves. Read the source that matches the resolved version — check
  `dist-newstyle/cache/plan.json` for what that is, then either `cabal unpack
  servant-openapi-hs-<version>` or confirm the checkout's `version:` field matches before
  reading it.

- Discovery (2026-07-22, while planning): **kotei's design has one weakness `en` should not
  inherit: the problem document's `status` member is hand-passed and has no mechanical tie to the
  response alternative it lands in.** Kotei's `faultToResult` writes
  `NotFound msg -> KoteiNotFound (problem 404 "Not found" "not_found" msg False)` — the constructor
  (which `AsUnion` maps to the `404` slot) and the literal `404` are two independent statements of
  the same fact, kept in agreement by convention alone. Shomei's shipped code does better: its
  `ProblemSpec` carries the status, and both the rendered body and the response headers derive
  from that one value (`status = spec.problemStatus.errHTTPCode`), so a body whose `status`
  disagrees with the response's status line is unrepresentable. This plan follows shomei: the
  catalog entry owns the status, and the mapping from a spec to an `EnResult` constructor is
  written once rather than at twenty call sites.

- Discovery (2026-07-22, while planning): **`en`'s existing `errorModelTests` is a stronger guard
  than anything in either reference implementation, and must be updated in place rather than
  replaced.** `en-servant/test/Main.hs` already pins the exact `(status, code, retryable)` triple
  for all eleven engine errors, plus the rule that a `store_error` body never leaks the SQL text
  and bound parameters `Hasql.toDetailedText` puts in `StoreError`. Kotei's plan pins codes only
  incidentally, through a `curl` transcript; shomei pins code *membership* in a catalog. Neither
  pins the triple. Keeping en's table — extended with the new `500` mapping from Milestone 3 — is
  the single most valuable regression guard in this migration, because the whole risk of a
  catalog refactor is a code silently changing status or retryability.

- Discovery (2026-08-25, verified against the resolved source): **the upstream document defect is
  fixed, and the plan's own escape clause for that eventuality is wrong.** `en` moved off the
  `shinzui` forks onto the released Hackage cohort and now resolves `openapi-hs` 5.0.0 with
  `servant-openapi-hs` 5.1.0 (`dist-newstyle/cache/plan.json`). In 5.1.0 the `addMime` helper
  that re-keyed every response's content map by the verb's whole content-type list **no longer
  exists** — `grep -rn addMime` over the package source matches nothing — and the per-alternative
  instance now keys the response by that alternative's own media type and nothing else:

  ```haskell
  instance
    (KnownSymbol desc, ToSchema a, Accept ct) =>
    IsSwaggerResponse cs (RespondAs (ct :: Type) s desc a)
    where
    responseSwagger = simpleResponseSwagger @a @'[ct] @desc
  ```

  The Concrete Steps of the 2026-07-22 draft said "if a future pin bump removes `addMime`,
  delete that pass" — **do not do that.** The defect it compensated for is gone, but a *second*
  distortion remains and has the same visible symptom. The client fix (widening every verb's
  content-type list to `'[JSON, ProblemJSON]`) is still required, and `Respond` — unlike
  `RespondAs` — still keys its content map by the whole list:

  ```haskell
  instance
    (KnownSymbol desc, ToSchema a, AllMime cs) =>
    IsSwaggerResponse (cs :: [Type]) (Respond s desc a)
    where
    responseSwagger = simpleResponseSwagger @a @cs @desc
  ```

  So after Milestone 2 the **error** responses are keyed correctly by `application/problem+json`
  alone, and the **success** responses wrongly claim `application/problem+json` alongside
  `application/json`. The repair pass therefore narrows in one direction only, and the conformance
  test's second clause — "and no success response is keyed by `application/problem+json`" — is now
  the clause carrying the weight. Milestone 6 and Concrete Steps are updated accordingly.

- Discovery (2026-08-25, while revising): **`en-servant.cabal` names `openapi-hs` and
  `servant-openapi-hs` with no version bounds at all.** That was defensible while both came from
  `source-repository-package` pins, where the tag *is* the version. It is not defensible now that
  the solver picks from Hackage: the two are a compatibility cohort, and the canonical OpenAPI
  document requires one released cohort per service (`openapi-hs >= 5.0 && < 5.1`,
  `servant-openapi-hs >= 5.1 && < 5.2` at the time it was written, re-verified 2026-07-24). A
  service that silently drifts across the cohort boundary can emit a different document from
  identical types. Milestone 1 now adds the bounds alongside the `http-media` line.


## Decision Log

- Decision: Introduce the pure `narrowSuccessContent` helper during Milestone 1 so the
  throwaway OpenAPI spike can prove both the raw generator defect and the repair, but do not
  apply it to `enOpenApi` until Milestone 6.
  Rationale: widening the spike's verb list fixes the real client and necessarily pollutes its
  raw `200` content map. A test that merely expects the pollution would leave the plan's third
  leg incomplete. Defining the exact one-directional repair now keeps production routes and the
  checked-in artifact unchanged while letting the spike prove the final algorithm; Milestone 6
  still owns wiring the helper into the published document and adding whole-API conformance
  tests.
  Date: 2026-08-25

- Decision: Declare `wai` and `http-types` as direct `en-servant` library dependencies, and
  temporarily declare `servant-client`, `servant-openapi-hs`, `http-client`, `warp`, and
  `sop-core` in the test stanza for Milestone 1's real-client spike.
  Rationale: the plan requires a reusable raw-WAI `problemResponse` and an actual
  `servant-client` round trip. Those APIs cannot be imported legally through transitive
  dependencies. Every package was already present in the project closure; the temporary spike
  dependencies will be removed with the spike at the end of Milestone 2.
  Date: 2026-08-25

- Decision: Re-associate this adopted child plan with MasterPlan 11's active intention,
  `intention_01m0xaavwqeznrgzs3j67m0q21`, replacing the intention under which the standalone
  draft was authored.
  Rationale: MasterPlan implement mode makes the parent's non-empty intention authoritative for
  every child implemented in the session. Keeping the older child-only intention in frontmatter
  and commit examples would make the durable metadata contradict the trailers required by the
  active initiative. The plan's scope and implementation decisions are unchanged.
  Date: 2026-08-25

- Decision: Work around servant's and the OpenAPI generator's two `RespondAs` gaps **inside
  `en`** — widen each `MultiVerb`'s content-type list to `'[JSON, ProblemJSON]`, and re-key the
  document's content maps in `enOpenApi` after derivation — rather than patching
  `servant-openapi-hs` and repinning the cohort. Report the upstream defects separately.
  **Amended 2026-08-25** (see the entry below): the first half stands unchanged; the second half
  is narrowed, because the generator defect it worked around was fixed upstream and released.
  Rationale: The two failures found by experiment (see Surprises) have different fixes and only one
  of them *could* be fixed upstream. The client failure is in Hackage `servant-client-core`, which
  this fleet does not fork; the only lever from inside `en` is the verb's `cs` list, because that is
  what `HasClient` checks the response Content-Type against. Widening it to `'[JSON, ProblemJSON]`
  was verified end to end: both a `200` under `application/json` and a `400` under
  `application/problem+json` round-trip through `genericClient`. The cost is small — the
  `MimeRender`/`MimeUnrender ProblemJSON` instances are already polymorphic in the payload
  (`ToJSON a => MimeRender ProblemJSON a`), so widening `cs` demands nothing new per wire type —
  and the one semantic wart is that a caller who sends `Accept: application/problem+json` and
  nothing else can now receive a `200` labelled with that media type. That is odd but harmless, and
  no real client does it. The document failure *is* fixable upstream, but doing so means a fork
  change, a version bump, a retag, and repinning every repository in the cohort that shares those
  tags — a cross-repository migration attached to what is otherwise an en-local plan. `en` already
  post-processes its document with lenses (`withOperationIds`), so adding one more enrichment pass
  is the cheap, idiomatic, en-local fix, and it is needed *regardless* of the upstream state
  because widening `cs` puts `problem+json` into the `200`'s content map too. Both defects should
  still be reported upstream — the fork's `addMime` bug will hit every service that adopts the
  convention, and the canonical document's "the media type reaches the document for free" claim is
  false as written and needs correcting. That report is a follow-up, not a blocker.
  Date: 2026-07-22

- Decision: Carry every one of the twenty existing `code` strings forward verbatim. Do not
  rename, merge, or split a code in this plan — including the two that have two producers each
  (`not_found` for both an unmatched route and disabled grant minting; `permission_denied` for
  both `requirePermission` and a read-only API key).
  Rationale: `code` is the only member of the body a client is allowed to branch on, so it is the
  one thing that must not move while the envelope around it does. A migration that reshaped the
  body *and* revised the vocabulary would force every client into a re-mapping exercise instead of
  a one-line change ("read `code` out of the new object"). The two double-producer codes are a
  real if mild wart — a client cannot distinguish those cases by `code` alone — but fixing that is
  a vocabulary change with its own deprecation story, and bundling it here would defeat the point.
  Recorded as a follow-up instead.
  Date: 2026-07-22

- Decision: Give `en` a **catalog of problem specifications as values** — one `ProblemSpec` per
  code, carrying the code, its HTTP status, and its stable title, plus a `problemCatalog` listing
  all of them — rather than inlining title and status at each of the twenty construction sites.
  Rationale: RFC 9457 requires `title` to be *stable per code* (dashboards and documentation key
  on it) and `status` to mirror the HTTP status line. Both invariants are trivially violated by
  hand-written call sites: two sites building the same code with different titles, or a body whose
  `status` says 400 while the response line says 403, are silent bugs. A catalog makes both
  properties structural, and — following the shomei reference implementation — lets the OpenAPI
  error documentation be generated from the same list the runtime renders from, with a conformance
  test asserting the two cannot drift. Twenty codes is well past the "a handful can be inlined"
  threshold the canonical document names.
  Date: 2026-07-22

- Decision: The shared response list gains **only** a `500`; `POST /v1/grants` gets its own list
  defined as the shared tail *plus* `403` and `404`, rather than widening the shared list to
  cover them.
  Rationale: There is a genuine tension with the canonical rule "share one response list, even if
  it is slightly over-broad", so the reasoning matters. That rule exists to keep the
  fault-to-result conversion **total**: narrowing the list per operation makes `faultToResult`
  partial, because `En.Error.EnError` is one closed sum that the type system cannot prove a given
  operation will never produce. That argument applies squarely to the `500`: every operation can
  hit an internal store fault, so `EnFault` gains an internal arm and the shared list must gain
  the `500` to receive it. It does *not* apply to the `403` and `404` on grants: those are
  **edge statuses**, raised where the condition is detected (minting is unconfigured; the decision
  came back `Denied`), not routed through `EnFault` at all — so `EnFault` gains no arm for them and
  totality is untouched either way. Widening the shared list would therefore buy nothing and cost
  something real: every read operation would advertise a `403` and a `404` it cannot produce, in
  an artifact whose entire purpose is to be consumed by non-Haskell client generators. Defining
  `MintGrantResponses` as the shared tail plus two keeps one source of truth for the tail.
  If a second operation ever needs those statuses, promote them to the shared list at that point.
  Date: 2026-07-22

- Decision: `GET /readyz` converts to a problem document like everything else; `GET /healthz` and
  `GET /metrics` are exempt, by name.
  Rationale: The canonical document exempts three things and asks that each exemption be a
  recorded decision rather than an accident. Two of them apply cleanly here: `/metrics` serves
  Prometheus text, a non-JSON surface with no error tail to speak of, and `/healthz`'s
  `{"status":"ok"}` is a success body, not an error. The third exemption — "a readiness probe
  answering 503 with a structured probe body is reporting status, not failing" — looks like it
  covers `/readyz`, but does not fit `en`: en's `/readyz` does not answer with a probe report
  (which dependency, since when); it answers with *the error envelope*, code `store_error`, the
  same one a request gets while the store is unreachable. Leaving it alone while every other
  surface converts would leave exactly one endpoint speaking the old dialect — the "don't keep a
  bespoke envelope alongside" anti-pattern. Converting it keeps `en` at one dialect and preserves
  the deliberate symmetry with `store_error`.
  Date: 2026-07-22

- Decision: Rewrite servant's empty-bodied `405 Method Not Allowed` into a problem document with
  a small WAI middleware, and put that middleware **inside `En.Servant.API.app`** rather than in
  `en-server`'s middleware stack.
  Rationale: Servant raises `405` inside `Servant.Server.Internal.methodCheck`, upstream of all
  four `ErrorFormatters` hooks, so no hook can see it. The canonical document says a service must
  choose explicitly between rewriting it with middleware and accepting the empty body as a
  documented limitation, and record which. This plan initially chose to accept it, on the reading
  that a `405` means a misconfigured client — but that reading is wrong *for en specifically*.
  `en` deliberately models tuple deletion as `POST /v1/relationships/delete` rather than
  `DELETE /v1/relationships`, and `en-servant/src/En/Servant/API.hs` says so in its own Haddock:
  "A 405 is what `DELETE /v1/relationships` now yields." A client that reasonably assumes REST
  conventions will send `DELETE /v1/relationships`, which is a *declared path*, and will get an
  empty-bodied `405` telling it nothing. That is a contract answer en expects callers to hit, not
  a misconfiguration, so it deserves a problem document explaining what to call instead. The
  safety condition the middleware needs holds: no `en` handler ever answers `405` itself, so
  rewriting every `405` unconditionally cannot swallow a legitimate one. Placing it inside `app`
  rather than in `en-server` means every embedder gets it — `kikan-en` serves `app` directly, and
  a limitation fixed only in the standalone server would leave embedded deployments with the old
  behavior. `415 Unsupported Media Type` is raised in the same unreachable place and has no
  middleware precedent in either reference implementation; it stays an empty body and is recorded
  as a known gap.
  Date: 2026-07-22

- Decision: Do not add a compatibility shim, a deprecated `ErrorEnvelopeWire` alias, or a
  transitional period in which both shapes are served. Replace outright.
  Rationale: `en`'s two external consumers make this safe in a way it would not be for a service
  with live third-party clients. `kikan-en` imports only `app`, `Env`, and `AppEffects` — it never
  names an error type, so it cannot break. `nagare` pins `en` by a git tag and is already stale
  against current `en` for unrelated reasons (its `checkResponseToDecision` predates the
  `MultiVerb` conversion), so a shim would protect nothing that is not already unprotected.
  Meanwhile a shim has a specific cost here: it would let a surface keep compiling against the old
  shape and therefore let one be forgotten, which is the two-dialect failure this plan exists to
  prevent. A hard cutover makes GHC's error list the migration checklist.
  Date: 2026-07-22

- Decision: Refresh this plan against the pattern catalog as it stands on 2026-08-25 rather than
  executing the 2026-07-22 draft as written, and rename the plan from "RFC 7807" to "RFC 9457" —
  file, `slug`, `title`, heading, and every `ExecPlan:` trailer in the commit-message blocks.
  Rationale: nothing in this plan has been implemented — every Progress box is unchecked,
  `grep -rn ProblemDetails` over the Haskell tree matches nothing, `ErrorEnvelopeWire` is still
  live in `en-servant/src/En/Servant/Seam.hs`, and `docs/api/openapi.json` still keys every error
  on `application/json`. Meanwhile the canonical source moved underneath it in four ways: the
  standard was renamed to RFC 9457 (identical wire format), the catalog was restructured so the
  three governing documents now live under `patterns/api/` and carry canonical `mori://` URIs,
  the OpenAPI packages were released to Hackage and `en` moved onto them, and the generator
  defect this plan works around was fixed in that release. A plan whose Context and Orientation
  cites paths that no longer exist and pins that no longer apply is no longer self-contained,
  which is the one non-negotiable ExecPlan requirement — so refreshing it is not optional
  tidying. The rename is worth its churn precisely because the plan is unstarted: no commit,
  branch, or sibling document references the old filename (`grep -rn 61-adopt-rfc-7807` over the
  repository matches only the plan itself), so the cost is one `git mv` and the benefit is that
  the artifact and the standard it implements share a name.
  Date: 2026-08-25

- Decision: Keep Milestone 6's repair pass — renamed `narrowSuccessContent` — but narrow **only success
  responses**, and delete the 2026-07-22 instruction that said to drop the pass entirely if a
  version bump ever removed `addMime`.
  Rationale: that instruction was written as a conditional and its condition has now fired — and
  following it would ship the exact divergence the pass exists to prevent. `addMime` is indeed
  gone in `servant-openapi-hs` 5.1.0, so a `RespondAs ProblemJSON` alternative now reaches the
  document keyed by `application/problem+json` alone, correctly and for free. But the *client*
  workaround is unrelated to that fix and is still required, and it is what pollutes the success
  side: widening every verb's content-type list to `'[JSON, ProblemJSON]` feeds that whole list
  to `Respond`'s `IsSwaggerResponse` instance, which keys its content map by all of it. So the
  document's errors are now right by construction and its successes are wrong, an exact inversion
  of the 2026-07-22 situation, with the same symptom in a `just openapi` diff. One-directional
  narrowing is also strictly safer than the two-directional version: a pass that force-keys 4xx
  and 5xx to `problem+json` would *manufacture* a correct-looking document over a route
  accidentally written as plain `Respond … ProblemDetails`, hiding the very mistake Milestone 6's
  conformance test exists to catch. Leaving the error side untouched lets that test see the truth.
  Date: 2026-08-25

- Decision: The Kubernetes health-endpoints standard is **out of scope** for this plan. `en` keeps
  `/healthz` and `/readyz` at their current paths and keeps answering them from its own
  `en-server/app/Health.hs`; only the *body* `/readyz` returns on failure converts, exactly as
  Milestone 5 already specifies. Record the migration to `/health/live`, `/health/ready`, and the
  released `servant-health` package as a follow-up for a separate plan.
  Rationale: the standard at `mori://shinzui/haskell-jitsurei/docs/api-health-endpoints` did not
  exist when this plan was written and is a genuine conformance gap, so it must be recorded
  rather than quietly ignored. But it is a different change with a different blast radius: it
  renames two operator-visible URLs that Kubernetes probes, Docker health checks, and
  `just start-server` all reference, adds a dependency, and — most importantly — asks whether
  en's readiness check has the right *contents*, which is a service-behaviour question this plan
  has no opinion on. Folding it in would mix a body-format migration with a URL migration in one
  plan, which is the "never mix a type change with a file move" sequencing rule this plan's own
  Plan of Work opens with, one level up. The two are independent: whichever lands first, the
  other still applies unchanged.
  Date: 2026-08-25

- Decision: Add cohort version bounds for `openapi-hs` and `servant-openapi-hs` to
  `en-servant/en-servant.cabal` as part of Milestone 1, rather than leaving them unbounded or
  treating it as separate housekeeping.
  Rationale: they were unbounded because they used to arrive by `source-repository-package`,
  where the pinned tag is the version and a bound would be noise. Since commit `673ab4b` they
  come from Hackage and the solver is free to move them, and the canonical OpenAPI document is
  explicit that the two are one compatibility cohort that must never be mixed. The risk is not
  hypothetical for this plan specifically: the whole Milestone 6 repair is calibrated to which
  `IsSwaggerResponse` instances the resolved version carries, and this plan has already been
  wrong-footed once by that source changing. It belongs in Milestone 1 because Milestone 1 is
  where the cabal file is already being edited for `http-media`, so it costs one extra stanza
  and no extra commit.
  Date: 2026-08-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

`en` is a Haskell implementation of relationship-based authorization (ReBAC), in the style of
Google Zanzibar. It is built with `cabal` and GHC 9.12.4, pinned by `cabal.project` at the
repository root, `/Users/shinzui/Keikaku/bokuno/en`. The packages, each a directory at the
repository root with its own `.cabal` file:

- `en-core` — the engine: schema, reachability graph, the `check`/`lookup`/`expand` algorithms,
  tuple and caveat domain types, the error type `En.Error.EnError`, and the effect *ports*
  (`TupleStore`, `CachedTupleStore`, `ConsistencyStore` — interfaces with no implementation).
  No HTTP.
- `en-servant` — the HTTP contract as a servant API type, the handlers, the JSON codecs, the
  OpenAPI document, and `requirePermission` (a fail-closed helper for hosts that embed `en`).
  **Most of this plan's work is here.**
- `en-client` — a typed Haskell client (`En.Client`) derived from the API type.
- `en-postgres` — the PostgreSQL adapters implementing the `en-core` ports, on the `hasql`
  database library. **Milestone 3 changes one function here.**
- `en-server` — the deployable standalone executable, including its WAI middleware (bearer-key
  authentication, rate limiting) and its health endpoints. **Milestone 5 changes this.**
- `en-biscuit` — an optional Biscuit-token grant layer (the thing `POST /v1/grants` mints).
- `en-example` — a worked example of embedding `en` via `requirePermission`.
- `en-migrations` — SQL schema migrations. Untouched by this plan.

### Terms used in this plan

**Servant** is the Haskell library `en` uses to describe an HTTP API as a *type*. A route is a
type built from combinators joined by `:>`; a whole API is a record with one field per route
(servant calls this **`NamedRoutes`**), parameterized by a type variable conventionally called
`mode`, with each field joining its name to its route type by the `:-` operator. `en`'s API is
`En.Servant.API.EnApi`, a five-field record whose fields each mount one *slice* sub-record — see
below.

**A vertical slice** means every module belonging to one concept shares one module-path prefix
named for that concept, with the *layer* as the last path component. `en`'s HTTP layer is sliced
this way: `En.Tuple.Api`, `En.Check.Api`, `En.Lookup.Api`, `En.Expand.Api`, `En.Schema.Api`, each
in `en-servant/src/En/<Concept>/Api.hs`, holding that concept's routes, wire types, and handlers
together. Shared vocabulary lives in `En.Servant.Wire`. **This plan does not move any module.**

**`MultiVerb`** is a servant combinator. Instead of a route ending in `Post '[JSON] X` and
throwing an exception to signal an error status, the route ends in a `MultiVerb` whose type-level
list enumerates every status the operation can answer with, and the handler returns a plain sum
type with one constructor per status. In `en` the list is `En.Servant.Response.EnResponses` and
the sum is `En.Servant.Response.EnResult`. The consequence that matters: a status declared this
way appears in the generated OpenAPI document and in the client's result type, whereas a status
thrown as an exception appears nowhere.

**`Respond` and `RespondAs`** are the combinators that name one alternative inside a `MultiVerb`
response list. `Respond status description payload` serves that payload under the verb's own
content-type list (for `en`, `'[JSON]`, i.e. `application/json`).
`RespondAs contentType status description payload` is the same thing with that one alternative's
Content-Type pinned to `contentType` regardless of the verb's list. It ships in stock servant
0.20 — **no fork is involved** — and swapping `Respond` for `RespondAs ProblemJSON` on the error
alternatives is the entire mechanism by which en's error bodies acquire the RFC 9457 media type
while its success bodies stay plain JSON.

**`AsUnion`** is the servant type class that maps a handler's result sum onto the response list.
`en` writes its instance **by hand** (rather than deriving it via `GenericAsUnion`) so that a
change to the response list breaks the build loudly. Its last clause is the *exhaustiveness
witness*: because the union has exactly five positions today, the sixth shift is uninhabited and
matches into the empty case (`S (S (S (S (S impossible)))) -> case impossible of {}`). Growing
the list means growing that clause — which is the point, and this plan grows it deliberately.

**A DTO (data-transfer object)** is an on-the-wire request or response shape — in `en`, the
`…Wire` types (`CheckRequestWire`, `LookupPageWire`, …), each with a hand-written
`ToJSON`/`FromJSON` instance that fixes the exact JSON bytes.

**The seam** is `en-servant/src/En/Servant/Seam.hs`, the module that joins `en`'s `effectful`
engine stack to servant's `Handler` monad. It owns the error vocabulary this plan replaces.

**An RFC 9457 problem document** is the IETF-standard error body. It is a JSON object with four
members from the RFC — `type` (a URI naming the error *kind*; always the literal `"about:blank"`
until a service really hosts error-documentation pages, because a made-up URL that 404s is worse
than none), `title` (a short human phrase that is **stable for a given code**, never
request-specific, so dashboards can key on it), `status` (the HTTP status repeated inside the
body, so the body still identifies itself once separated from its response), and `detail` (the
request-specific prose) — plus two extension members this fleet adds, which the RFC explicitly
permits: `code` (the stable `snake_case` machine key clients branch on) and `retryable` (true
only when retrying the *unchanged* request can succeed, which in practice means the `503`
"a dependency is down" case). It must be served as `application/problem+json`; a problem body
under plain `application/json` is the shape without the self-description. A note on the name:
this convention was first written against **RFC 7807**, which **RFC 9457** obsoletes with an
*identical wire format* — 9457's additions are an IANA registry of common problem types and
guidance on multiple problems and on non-dereferenceable `type` URIs, none of which changes a
byte on the wire. The canonical document and this plan now say 9457; older fleet code and
comments, shomei's included, still say 7807 and should be read as 9457.

### Where the rules come from

The conventions this plan implements are recorded canonically in a separate repository, the
fleet's Haskell pattern catalog. Cite it by its canonical Mori URIs rather than by a path on one
machine — a `mori://` URI survives the repository being restructured, which this one was between
this plan's authoring and its 2026-08-25 revision. Three documents govern this work:

- `mori://shinzui/haskell-jitsurei/docs/api-servant-routes` — routes as a `NamedRoutes` record,
  statuses declared as `MultiVerb` alternatives, modules by concept.
- `mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types` — the OpenAPI document is derived
  from the route types and never hand-written.
- `mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details` — this plan's subject.

Resolve any of them to a file on this machine with `mori path <uri>`; today all three land under
`patterns/api/` in the working copy at `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei`, which is
where they moved from the flat `api/` directory the 2026-07-22 draft of this plan named. Per the
ExecPlan self-containment requirement, everything needed from them is restated here; a reader
does not need that repository — or a working `mori` — to execute this plan.

Two reference implementations are named there and were read while planning: **kotei** (the
`MultiVerb`-style adoption, whose approach `en` follows) and **shomei** (the `ServerError`-style
adopter, whose single rendering function and error catalog `en` borrows). Only shomei ships as
code; see the first entry in Surprises & Discoveries.

`en` already satisfies the first two documents. That work is
`docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`, which converted the API
to a `NamedRoutes` record, split it into vertical slices, and brought the OpenAPI setup to the
full recipe (a checked-in artifact written by an executable, stable `operationId`s, a drift
check, three conformance tests). Its 2026-07-21 audit is what produced this plan; the four gaps
it lists as follow-ups (1) through (4) are exactly this plan's four milestone groups.

The catalog has grown since. Five further standards now sit beside the three above —
Kubernetes health endpoints, Relay pagination, OpenTelemetry integration, production request
logging, and Hurl integration testing. Exactly one of them touches ground this plan stands on:
`mori://shinzui/haskell-jitsurei/docs/api-health-endpoints` requires every service to serve
`/health/live` and `/health/ready` from the released `servant-health` package, whereas `en`
serves hand-written `/healthz` and `/readyz` out of `en-server/app/Health.hs`. That is a real
gap and it is **deliberately out of scope here** — see the 2026-08-25 Decision Log entry. This
plan converts the *body* `/readyz` answers with; a separate plan moves the *endpoints*. The
other four are unrelated to error bodies and are not this plan's business.

### The current error surface, in full

`en` produces error bodies from **six** places. All six emit the same
`{code, message, retryable}` object under `application/json`, and all six must change together —
leaving one behind would give `en` two error dialects, which is worse than one bespoke dialect.

1. **`MultiVerb` response alternatives**, in `en-servant/src/En/Servant/Response.hs`. The shared
   list is `EnResponses`, currently five alternatives: `Respond 200` with the operation's own
   payload, then `400 "Invalid request"`, `412 "Write precondition failed"`,
   `422 "Resolution limit exceeded"`, and `503 "Tuple store unavailable"`, each carrying
   `ErrorEnvelopeWire`. The handler-side sum is `EnResult` with constructors `EnOk`,
   `EnClientError`, `EnPreconditionFailed`, `EnUnprocessable`, `EnUnavailable`. Ten of en's twelve
   routes use this list.
2. **Thrown `ServerError`s**, built by `En.Servant.Seam.envelopeError`, which attaches the encoded
   envelope as `errBody` and sets `Content-Type: application/json` in `errHeaders`. Its callers
   are `faultToServerError` (the same fault vocabulary, for embedded hosts that catch it),
   `notFound` (the router's 404), `permissionDenied` (403, thrown by
   `En.Servant.Authorize.requirePermission`), and — in `en-servant/src/En/Check/Api.hs` —
   `mintingDisabled` (404) and `decisionNotAllowed` (403).
3. **`envelopeFormatters`**, in `en-servant/src/En/Servant/API.hs`. Servant rejects a malformed
   body or an unmatched route *before any handler runs*, so those cannot be response alternatives;
   `ErrorFormatters` is the hook that makes them speak en's envelope anyway. It has exactly four
   hooks and `en` sets three — `bodyParserErrorFormatter`, `urlParseErrorFormatter`, and
   `notFoundErrorFormatter`. The fourth, `headerParseErrorFormatter`, is unset and today
   unreachable, because `en` declares no `Header` combinator anywhere. This plan sets it anyway:
   it is one line, both reference implementations set all four, and leaving one hook unset is a
   latent trap for whoever first adds a `Header` combinator and gets a plain-text body out of an
   otherwise-converted service.
4. **`en-server`'s authentication and rate-limit middleware**, `en-server/app/Middleware.hs`. It
   answers `401 unauthenticated` (with `WWW-Authenticate: Bearer`), `403 permission_denied` for a
   read-only key on a write path, and `429 rate_limited` (with `Retry-After: 1`). Its `errorBody`
   helper hand-builds the same object with `Data.Aeson.object`, deliberately duplicated rather
   than imported because these responses are produced by WAI middleware, outside servant, where
   there is no `ServerError` to attach.
5. **`en-server`'s readiness probe**, `en-server/app/Health.hs`. `GET /readyz` answers `200
   {"status":"ok"}` when the database responds and `503` with the error envelope (code
   `store_error`) when it does not. `GET /healthz` always answers `200 {"status":"ok"}`.
6. **`GET /metrics`**, `en-server/app/Metrics.hs`, which serves Prometheus text — not JSON, and
   not an error surface.

### The twenty error codes, which must all survive verbatim

This is the vocabulary a client branches on, and the migration must not change one character of
it. Listing it here because Milestone 2 turns it into a catalog of values, and because a reviewer
needs the before-picture to check the after-picture against. Format is
`code — status — where it is produced`:

```text
unknown_relation            400  En.Servant.Seam.enErrorToFault (EnError UnknownRelation)
schema_violation            400  enErrorToFault (SchemaViolation)
missing_caveat_context      400  enErrorToFault (MissingCaveatContext)
malformed_consistency_token 400  enErrorToFault (MalformedConsistencyToken)
consistency_token_expired   400  enErrorToFault (ConsistencyTokenExpired)
invalid_consistency_token   400  enErrorToFault (InvalidConsistencyToken)
invalid_cursor              400  enErrorToFault (InvalidCursor)
resolution_limit_exceeded   422  enErrorToFault (ResolutionLimitExceeded)
cycle_detected              422  enErrorToFault (CycleDetected)
write_precondition_failed   412  enErrorToFault (WritePreconditionFailed)
store_error                 503  enErrorToFault (StoreError); also GET /readyz when down
invalid_request             400  En.Servant.Seam.invalidRequest (wire-to-engine conversion)
batch_too_large             400  En.Servant.Seam.batchTooLarge
malformed_request_body      400  En.Servant.API.envelopeFormatters (body and URL parse hooks)
not_found                   404  En.Servant.Seam.notFound (unmatched route)
                            404  En.Check.Api.mintingDisabled (grant minting not configured)
permission_denied           403  En.Servant.Seam.permissionDenied (requirePermission)
                            403  en-server Middleware (a read-only key on a write path)
decision_not_allowed        403  En.Check.Api.decisionNotAllowed
grant_not_mintable          400  En.Check.Api.mintGrantHandler
unauthenticated             401  en-server Middleware
rate_limited                429  en-server Middleware (retryable)
```

Two codes have two producers each (`not_found`, `permission_denied`). That is a mild vocabulary
smell — a client cannot tell "no such endpoint" from "grant minting is disabled" by `code` alone —
but renaming codes is explicitly forbidden during an envelope migration: the canonical rule is
that the move to RFC 9457 changes the envelope and must not simultaneously change the vocabulary,
so that client migration reads "get `code` from the new shape" rather than "re-map every code".
Both are carried forward as-is; disambiguating them, if ever, is its own change with its own
deprecation story.

### What downstream consumers actually touch

Two repositories outside this one depend on `en` as a library, and the audit that produced this
plan established exactly how:

- **`kikan-en`** at `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en` imports only
  `En.Servant.API (app)` and `En.Servant.Seam (AppEffects, Env (..))` in
  `src/Kikan/En/Server.hs`. It never names an error type, so **nothing in this plan breaks its
  compile** — but the bodies its deployment serves do change shape, which is a wire change its
  own callers see. Note that `kikan-en` cannot currently build against the local `en` tree at all,
  for reasons predating this plan: its `cabal.project` lists `en-core`, `en-migrations`,
  `en-postgres`, `en-servant`, and `en-client` as local packages but omits `en-biscuit` (which
  `en-servant` has depended on since the grant-minting work), and it lacks en's
  `biscuit-haskell` fork pin.
- **`nagare`** at `/Users/shinzui/Keikaku/bokuno/nagare`, package `nagare/cli/nagare-access`,
  imports `En.Client (EnClient (..), enClient, …Wire types)` and, in its test, `En.Servant.API`
  (for `app`) and `En.Servant.Seam (Env (..))`. It pins `en` by a `source-repository-package` git
  **tag**, so local `en` changes do not reach it. It is already behind: its
  `src/Nagare/Access/En.hs` applies `checkResponseToDecision :: CheckResponseWire -> AccessDecision`
  directly to the result of `client.check`, which today returns `EnResult CheckResponseWire` — so
  that file has not compiled against current `en` since the `MultiVerb` conversion, long before
  this plan. Repointing its tag is out of scope here and is called out as a follow-up.

The practical consequence: **no downstream repository's compile can be broken by this plan,
because neither currently builds against local `en` anyway.** Validation is therefore by import
review plus en's own suite, exactly as in plan 59. Do not claim a downstream build as evidence
without first repointing the tag or adding local overrides, and record whatever you do.

### Build and test commands

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/en`, inside the nix dev
shell. The project uses a `justfile`.

```bash
cabal build all
cabal test all
```

`cabal test all` runs seven suites, including `en-servant-tests`
(`en-servant/test/Main.hs` — a plain `exitcode-stdio` program of hand-rolled assertions, **not**
hspec, whose `main` calls `wireContractTests`, `errorModelTests`, `openApiDocumentTests`,
`toJsonMatchesToSchema`, and `routingTests` in that order) and `en-postgres-integration-tests`,
which needs a real PostgreSQL. Two more commands matter here:

```bash
just openapi        # regenerate docs/api/openapi.json and fail if it drifted
just start-server   # run migrations, then cabal run en-server
```


## Plan of Work

The order below is deliberate and follows the sequencing rule both reference implementations
record: **never mix a type change with a file move or with an artifact regeneration in one
commit**, because a reviewer cannot then tell a rewrite from a rename. Nothing here moves a file
— plan 59 already put every module where it belongs — so the rule reduces to: build the
machinery first, flip the types second, extend the vocabulary third, and regenerate the document
last, one commit each.

### Milestone 1 — The problem-details machinery, in isolation

Scope: one new module, `en-servant/src/En/Servant/Problem.hs`, plus two unit tests and one
throwaway end-to-end spike. **No route changes, no handler changes, nothing deleted.** At the end
of this milestone `en` still serves exactly what it serves today, and the new machinery is proven
to compile, encode correctly, and actually stamp `application/problem+json` on a real HTTP
response.

The module holds four things. First, the record and its codec, where the only subtlety is that
`type` is a Haskell reserved word, so the field is named `problemType` and one shared aeson
`Options` value renames it on the wire. Everything hangs off that single value — the `ToJSON`, the
`FromJSON`, and later the `ToSchema` — so the codec and the schema cannot disagree:

```haskell
data ProblemDetails = ProblemDetails
    { problemType :: !Text
    , title :: !Text
    , status :: !Int
    , detail :: !Text
    , code :: !Text
    , retryable :: !Bool
    }
    deriving stock (Generic, Eq, Show)

problemJsonOptions :: Options
problemJsonOptions =
    defaultOptions
        { fieldLabelModifier = \case
            "problemType" -> "type"
            other -> other
        }

instance ToJSON ProblemDetails where
    toJSON = genericToJSON problemJsonOptions

instance FromJSON ProblemDetails where
    parseJSON = genericParseJSON problemJsonOptions
```

Note `detail` is total (`Text`, not `Maybe Text`) with no `omitNothingFields`. That is a
deliberate difference from shomei, which omits `detail` when it has nothing request-specific to
say: every one of en's twenty codes already carries prose today in `ErrorEnvelopeWire.message`, so
making the field optional would be a wire regression rather than a simplification. Also note the
codecs are *generic*, unlike the hand-written ones on `ErrorEnvelopeWire` — because the whole
point is that one `Options` value drives codec and schema together.

Second, the content type. This is the mechanism by which error bodies get the RFC media type
while success bodies stay plain JSON:

```haskell
-- | The application/problem+json content type (RFC 9457 §3).
data ProblemJSON

instance Accept ProblemJSON where
    contentType _ = "application" // "problem+json"

instance (ToJSON a) => MimeRender ProblemJSON a where
    mimeRender _ = encode

instance (FromJSON a) => MimeUnrender ProblemJSON a where
    mimeUnrender _ = eitherDecode
```

`(//)` comes from `Network.HTTP.Media` in the `http-media` package, which must be added to the
`en-servant` library's `build-depends`. `ProblemJSON` must be an empty `data` declaration of kind
`Type` — not a promoted symbol, not a type synonym — because servant distinguishes
`RespondAs (ct :: Type) …` from `RespondEmpty`'s `RespondAs '() …` **by kind** rather than by
overlapping instances. Writing it any other way makes the instances fail to resolve.

Third, the catalog: one specification per error code, as a value.

```haskell
-- | One stable error kind: its machine-readable code, the HTTP status it is answered at, the
-- human title that is stable for that code, and whether retrying an unchanged request can help.
data ProblemSpec = ProblemSpec
    { code :: !Text
    , status :: !Int
    , title :: !Text
    , retryable :: !Bool
    }

-- | Build the wire document for a spec, with this request's prose in @detail@.
problem :: ProblemSpec -> Text -> ProblemDetails
problem spec detail =
    ProblemDetails
        { problemType = "about:blank"
        , title = spec.title
        , status = spec.status
        , detail
        , code = spec.code
        , retryable = spec.retryable
        }

-- | Every problem kind en can emit. The OpenAPI error documentation is generated from this
-- list, and a conformance test asserts every documented code appears here.
problemCatalog :: [ProblemSpec]
```

Define one top-level constant per code — all twenty from the list in Context and Orientation,
each carrying forward its existing code string, its existing status, and its existing
retryability, with a newly written stable title. Suggested titles, chosen to be short, human, and
constant across requests: `unknown_relation` → "Unknown relation", `store_error` → "Store
unavailable", `write_precondition_failed` → "Write precondition failed",
`resolution_limit_exceeded` → "Resolution limit exceeded", and so on. The rule to apply
mechanically: **anything request-specific belongs in `detail`, never in `title`** — so
`unknown_relation`'s title is "Unknown relation" and the offending relation name goes in `detail`,
exactly where `enErrorToFault`'s message text already puts it.

Fourth, the two renderers, one per surface. Handlers inside a `MultiVerb` return values, but
three surfaces cannot: thrown `ServerError`s, and WAI middleware that answers before servant
sees the request. Both must attach the media type, and forgetting that header is precisely the
mistake a single shared function exists to prevent:

```haskell
-- | Render a spec as a thrown ServerError. The status in the body is taken from the base
-- error, so a body whose @status@ disagrees with the response's status line is unrepresentable.
problemError :: ServerError -> ProblemSpec -> Text -> ServerError

-- | Render a spec as a raw WAI Response, for middleware that answers before servant runs.
problemResponse :: ProblemSpec -> Text -> Response
```

Both set `Content-Type: application/problem+json`, and both must also carry the status-specific
headers en already sends: `WWW-Authenticate: Bearer` on a `401` and `Retry-After` on a `429`.
Putting that in the renderer rather than at the call site is what stops a future `401` from
losing its `WWW-Authenticate` header.

Two unit tests go in `en-servant/test/Main.hs`. The first **pins the field rename**: encode a
`ProblemDetails`, decode to an `Aeson.Value`, and assert the object's keys are exactly `type`,
`title`, `status`, `detail`, `code`, `retryable` — in particular that the wire key is `type` and
not `problemType` — plus `decode (encode x) == Just x`. Without this, a later "cleanup" to plain
generic derivation ships `problemType` onto the wire and nothing notices. The second **pins the
catalog's internal consistency**: no two entries share a `code` with different `status` or
`title`, and every entry's `retryable` is `True` only for `store_error` and `rate_limited`.

Finally, the spike — and it must exercise **three** legs, not one. Add a throwaway `MultiVerb`
route **in the test file only**, not in the API, whose success alternative is
`Respond 200 "ok" <something>` and whose error alternative is
`RespondAs ProblemJSON 400 "Bad request" ProblemDetails`, and assert all of:

1. **The wire.** Served through `Network.Wai.Test` the way `routingTests` already serves
   `app env`, the `400` carries `Content-Type: application/problem+json` and the `200` carries
   `application/json`.
2. **The client.** Round-trip the same route through `servant-client`'s `client` against a real
   server (or through `runClientM` over the WAI app), and assert the `400` comes back as the
   *value* `UnrenderSuccess`-style — pattern-matched as the error constructor — and **not** as a
   `Left (UnsupportedContentType …)`.
3. **The document.** Call `toOpenApi` on the spike's proxy and assert **two** things, not one:
   the `400` response's `content` map is keyed by `application/problem+json` *and nothing else*,
   and the `200` response's `content` map does **not** contain `application/problem+json`.

Legs 2 and 3 are not padding: each of them **fails** if the route is written the obvious way, for
reasons recorded in Surprises & Discoveries, and each is fixed by a specific measure this plan
adopts. Write the spike first *without* the fixes and watch them go red — that red is the
evidence the fixes are necessary, and it is worth thirty seconds to see. Expect this exact
pattern on the packages `en` resolves today (`openapi-hs` 5.0.0, `servant-openapi-hs` 5.1.0):

- Leg 1 is green from the start. `RespondAs` stamps the media type on the wire in stock servant.
- Leg 2 is **red**, and is fixed by giving the verb the content-type list `'[JSON, ProblemJSON]`.
  Without that the client rejects the response before it ever decodes the body.
- Leg 3's first assertion is **green** from the start — `RespondAs`'s `IsSwaggerResponse`
  instance keys the response by its own `ct` alone. Its second assertion goes **red the moment
  you apply leg 2's fix**, because `Respond`'s instance keys *its* content map by the verb's
  whole list, so the `200` inherits `application/problem+json`. That is what Milestone 6's
  `narrowSuccessContent` pass exists to undo. Run leg 3 before and after the leg-2 fix and watch
  the failure move from nothing to the `200` — that transition is the clearest possible statement
  of why the pass is needed and why it must only touch successes.

Delete the spike at the end of Milestone 2, when ten real routes prove the same properties.

While the cabal file is open, give the OpenAPI cohort explicit bounds in the `en-servant` library
stanza. They are absent today, which was fine when both packages arrived by pinned git tag and is
not fine now that the solver picks them from Hackage:

```cabal
    , openapi-hs         >=5.0 && <5.1
    , servant-openapi-hs >=5.1 && <5.2
```

Those are the released cohort `en` resolves today and the pair the canonical OpenAPI document
names. Re-check Hackage and the upstream release tags before widening them; never let the two
drift into different cohorts.

Acceptance: `cabal build all && cabal test all` passes; the two unit tests and all three legs of
the spike are green; `cabal build all` still resolves `openapi-hs` 5.0.0 and `servant-openapi-hs`
5.1.0 (`grep -A2 '"pkg-name": "openapi-hs"' dist-newstyle/cache/plan.json`); `git diff --stat`
shows one new module, three cabal lines, and test additions; and `docs/api/openapi.json` is
**unchanged**, because no production route changed.

### Milestone 2 — Convert the servant surface

Scope: `en-servant/src/En/Servant/Response.hs`, `en-servant/src/En/Servant/Seam.hs`,
`en-servant/src/En/Servant/API.hs`, `en-servant/src/En/Check/Api.hs`, and the existing tests. At
the end, every error `en-servant` can produce is a problem document, `ErrorEnvelopeWire` no longer
exists, and `grep -rn ErrorEnvelopeWire en-servant/src` is empty.

Start with the response list in `En.Servant.Response`. Change the four error alternatives from
`Respond` to `RespondAs ProblemJSON` and their payload from `ErrorEnvelopeWire` to
`ProblemDetails`, leaving the `200` alternative as a plain `Respond` so success bodies keep
`application/json`:

```haskell
type EnResponses (description :: Symbol) a =
    '[ Respond 200 description a
     , RespondAs ProblemJSON 400 "Invalid request" ProblemDetails
     , RespondAs ProblemJSON 412 "Write precondition failed" ProblemDetails
     , RespondAs ProblemJSON 422 "Resolution limit exceeded" ProblemDetails
     , RespondAs ProblemJSON 503 "Tuple store unavailable" ProblemDetails
     ]
```

Make the same substitution in the `AsUnion` instance head, and change `EnResult`'s four error
constructors to carry `ProblemDetails`. **The `toUnion` and `fromUnion` bodies do not change at
all**, and neither does the exhaustiveness witness, because `RespondAs`'s response type is the
same `a` that `Respond`'s is. If you find yourself editing those bodies in this milestone,
something has gone wrong.

**Then the step that is easy to skip and breaks the client if you do.** Every route that uses
`EnResponses` must have its `MultiVerb`'s content-type list widened from `'[JSON]` to
`'[JSON, ProblemJSON]` — that is one edit per route across the five slice modules
(`En/Tuple/Api.hs`, `En/Check/Api.hs`, `En/Lookup/Api.hs`, `En/Expand/Api.hs`), turning

```haskell
:> MultiVerb 'POST '[JSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
```

into

```haskell
:> MultiVerb 'POST '[JSON, ProblemJSON] (EnResponses "The authorization decision" CheckResponseWire) (EnResult CheckResponseWire)
```

The reason is not aesthetic and is not visible at compile time: servant's client checks a
response's Content-Type against the *verb's* list, not the alternative's, so with `'[JSON]` alone
every error response comes back to `en-client` as
`Left (UnsupportedContentType application/problem+json …)` instead of the typed error value. See
Surprises & Discoveries for the runtime transcript. Nothing else is needed to make this work: the
`MimeRender`/`MimeUnrender ProblemJSON` instances written in Milestone 1 are polymorphic in the
payload, so widening the list imposes no new obligation on any success wire type. `GET /v1/schema`
keeps its plain `Get '[JSON]` — it has no error alternative to carry.

Then `En.Servant.Seam`. Delete `ErrorEnvelopeWire` and its two hand-written instances outright —
no deprecated alias, per the Decision Log. Change `EnFault`'s four constructors to carry
`ProblemDetails`. Rewrite `enErrorToFault` as a dispatch over the catalog constants: each arm
picks its spec and supplies the request-specific prose that is today the `message` argument, so
`UnknownRelation relation` becomes
`BadRequestFault (problem specUnknownRelation ("unknown relation or permission: " <> relation))`.
Diff the old arms against the new constants one by one; every code, status, and retryable flag
must survive unchanged, and `errorModelTests` is what proves it. Replace `envelopeError` with
`problemError` from the new module, updating `notFound`, `permissionDenied`, and
`faultToServerError`. Keep `StoreError`'s deliberate detail-dropping: it carries SQL text and
bound parameters, which must not cross the trust boundary, so its `detail` stays the fixed prose
"the tuple store failed; retry later" and the real detail keeps going to stderr via `logEnError`.

Then `En.Servant.API`. Point the three existing `ErrorFormatters` hooks at `problemError`, and set
the fourth, `headerParseErrorFormatter`, for the reason given in Context. Then add the `405`
middleware and install it inside `app`:

```haskell
app env =
    problemMiddleware (serveWithContext apiProxy (envelopeFormatters :. EmptyContext) (server env))
```

`problemMiddleware` inspects the outgoing response and, when its status is `405`, replaces it with
`problemResponse specMethodNotAllowed` and a `detail` naming what to do instead — for the one case
en expects callers to hit, "use POST /v1/relationships/delete; en models deletion as a POST so a
method mismatch cannot leave an unread body on the wire". Rewriting unconditionally is safe
because no en handler ever answers `405` itself; if that ever changes, make the rewrite
conditional on an empty body.

Finally `En.Check.Api`: `mintingDisabled` and `decisionNotAllowed` become `problemError` calls
over their catalog specs, and the `grant_not_mintable` throw likewise. (These stay *thrown* in
this milestone — Milestone 4 is what turns them into declared alternatives. Doing the body shape
now and the declaration later keeps each diff readable.)

Update the tests as you go: `errorModelTests`'s `mapsTo` table keeps its exact `(status, code,
retryable)` expectations and only changes how it reaches into the fault; its golden assertion
gains the new members; `routingTests`'s two envelope assertions decode `ProblemDetails` instead
of `ErrorEnvelopeWire` and additionally assert the `Content-Type` header and that the body's
`status` member equals the response's status code; and `toJsonMatchesToSchema`'s
`ErrorEnvelopeWire` line becomes a `ProblemDetails` line. The `ToSchema` instance in
`En.Servant.OpenApi` must be updated in this milestone too, or the package will not compile —
give it the bridged form now and leave the rest of the OpenAPI work to Milestone 6:

```haskell
instance ToSchema ProblemDetails where
    declareNamedSchema = genericDeclareNamedSchema (fromAesonOptions problemJsonOptions)
```

Expect the tree not to compile for a while; that is intended, and GHC's error list is the
worklist. Do not add a shim to keep half the tree building.

Acceptance: `cabal build all && cabal test all` passes;
`grep -rn "ErrorEnvelopeWire" en-servant/src en-client/src` is empty; and a live `curl` of a
malformed body returns the transcript shown in Validation. Regenerate the document
(`cabal run en-openapi`) and commit it, but **do not expect it to be right yet**: at this point
every *success* response's `content` map lists both `application/json` and
`application/problem+json`, because widening each verb's content-type list to
`'[JSON, ProblemJSON]` (the client fix from Milestone 1) feeds that whole list to `Respond`'s
OpenAPI instance. The *error* responses are already keyed correctly by `application/problem+json`
alone, because `RespondAs`'s instance uses its own content type. Milestone 6 is what narrows the
successes. Recording the intermediate state here rather than "fixing" it early is what keeps each
commit's diff about one thing.

### Milestone 3 — A 500 for genuine internal faults

Scope: `en-core/src/En/Error.hs`, `en-postgres/src/En/Postgres/TupleStore.hs`,
`en-servant/src/En/Servant/Response.hs`, and `en-servant/src/En/Servant/Seam.hs`. At the end,
`en` answers `500` with `retryable: false` when it has failed itself, and keeps answering `503`
with `retryable: true` when PostgreSQL is unreachable.

Add an `InternalError Text` constructor to `En.Error.EnError`, documented as "en failed, not a
dependency of en — retrying cannot help". Then fix the two producers in `en-postgres` that are
currently mislabelled.

The easy one is `mintToken`, which today does
`either (throwError . StoreError . ("could not mint write token: " <> )) pure`. A freshly built
anchor that will not parse is an en bug, not an outage: change `StoreError` to `InternalError`.

The other needs a classification, because it comes through hasql's `SessionError` and the two
outcomes are mixed together in one `orThrow` helper used at three sites. The relevant hasql
constructors, verified in the pinned source at
`hasql/src/library/Hasql/Engine/Errors.hs`, are `ConnectionSessionError`,
`StatementSessionError` (which wraps a `StatementError`, itself either a `ServerStatementError`
carrying a PostgreSQL `ServerError` with its five-character SQLSTATE, or one of several
decoder-mismatch shapes including `RowStatementError`, `UnexpectedColumnTypeStatementError`, and
`UnexpectedColumnCountStatementError`), `ScriptSessionError`, `MissingTypesSessionError`, and
`DriverSessionError`. Classify structurally:

```text
ConnectionSessionError                       -> StoreError     (the database is unreachable)
StatementSessionError … ServerStatementError -> StoreError     (PostgreSQL rejected it; includes
                                                                deadlock_detected, which en
                                                                already treats as retryable)
StatementSessionError … (row/column decode)  -> InternalError  (our decoder disagrees with the
                                                                schema — the undecodable
                                                                caveat_payload case)
MissingTypesSessionError                     -> InternalError  (a type en expects is not there)
DriverSessionError                           -> InternalError
ScriptSessionError                           -> StoreError     (unreachable at request time; en
                                                                runs no scripts in a handler)
```

Resist the temptation to use hasql's own `isTransient`: it is coarser than en needs. At the
`SessionError` level it answers `False` for every `StatementSessionError`, which would reclassify
`deadlock_detected` — a genuinely retryable arbitration failure that
`en-postgres/src/En/Postgres/TupleStore.hs` deliberately treats as an outage-shaped `StoreError` —
as an internal `500`. Do the structural match instead, and say why in a comment so nobody
"simplifies" it to `isTransient` later.

Then grow the response machinery by exactly one alternative: add
`RespondAs ProblemJSON 500 "Internal error" ProblemDetails` to `EnResponses` after the `422`,
an `EnInternal !ProblemDetails` constructor to `EnResult`, the corresponding `toUnion`/`fromUnion`
clauses, and — the point of the hand-written instance — extend the exhaustiveness witness to
`S (S (S (S (S (S impossible))))) -> case impossible of {}`. Add an `InternalFault` arm to
`EnFault` and a catalog spec for the new code (`internal_error`, `500`, "Internal error",
`retryable = False`), and extend `faultToResult` and `faultToServerError`.

Note the ordering constraint: `500` must go **after** `422` and **before** `503` in the list, and
the `AsUnion` clauses must shift correspondingly, because `AsUnion` maps by position. Getting this
wrong maps a body onto the wrong status, which is exactly the failure the hand-written instance
exists to make loud — if the clauses and the list disagree, it will not compile.

Extend `errorModelTests` with `mapsTo "InternalError" (InternalError "…") (500, "internal_error", False)`
and keep the existing `StoreError` row asserting `(503, "store_error", True)`; the pair of them is
the regression guard.

Acceptance: `cabal build all && cabal test all` passes, including the new mapping row;
`docs/api/openapi.json` lists `500` under all ten `MultiVerb` operations; and the exhaustiveness
witness is at the sixth shift.

### Milestone 4 — `POST /v1/grants` declares its statuses

Scope: `en-servant/src/En/Check/Api.hs`, `en-client/src/En/Client.hs`, and the OpenAPI assertion
in `en-servant/test/Main.hs` that currently pins the deficiency. At the end, every one of en's
twelve routes is a `MultiVerb`, and no en handler throws a domain error.

Define the operation's response list as the shared tail plus its own two statuses, so there is
still one source of truth for the tail:

```haskell
type MintGrantResponses =
    '[ Respond 200 "The minted grant" MintGrantResponseWire
     , RespondAs ProblemJSON 400 "Invalid request" ProblemDetails
     , RespondAs ProblemJSON 403 "The decision was not Allowed" ProblemDetails
     , RespondAs ProblemJSON 404 "Grant minting is not enabled" ProblemDetails
     , RespondAs ProblemJSON 412 "Write precondition failed" ProblemDetails
     , RespondAs ProblemJSON 422 "Resolution limit exceeded" ProblemDetails
     , RespondAs ProblemJSON 500 "Internal error" ProblemDetails
     , RespondAs ProblemJSON 503 "Tuple store unavailable" ProblemDetails
     ]
```

with a matching `MintGrantResult` sum and a hand-written `AsUnion` in the same style — eight
constructors, witness at the ninth shift. Change the route's field in `CheckRoutes` from
`Post '[JSON] MintGrantResponseWire` to
`MultiVerb 'POST '[JSON, ProblemJSON] MintGrantResponses MintGrantResult` — note the widened
content-type list, for the same client-side reason as every other route in Milestone 2 — and
rewrite `mintGrantHandler` to
return rather than throw: `Nothing -> pure (MintNotFound …)` where it currently throws
`mintingDisabled`, `Denied`/`Conditional -> pure (MintForbidden …)` where it throws
`decisionNotAllowed`, and the engine faults routed through the existing conversion. The
check-then-mint logic, the `Allowed`-only rule, and the binding of the grant to the consistency
token and schema hash are all untouched — only the failure channel changes.

In `en-client`, the `mintGrant` field's type becomes
`MintGrantRequestWire -> ClientM MintGrantResult`, and its Haddock — which currently explains that
its failures arrive as `ClientError` — is rewritten to say they now arrive as values, like every
other operation. This is a breaking change for a Haskell caller, and it is the intended one.

Update the OpenAPI test: the assertion that "the grants endpoint is a POST with only a 200 and the
body-parse 400" is the *documentation of the bug this milestone fixes*, so replace it with an
assertion of the full list, and drop `/v1/grants` from the set of paths exempted from the
per-operation error-response check.

Acceptance: `cabal build all && cabal test all` passes; the document lists
`['200','400','403','404','412','422','500','503']` under `POST /v1/grants`; a live `curl` against
a server with minting disabled returns a `404` problem document; and
`grep -rn "throwError" en-servant/src/En/Check/Api.hs` no longer matches a domain error.

### Milestone 5 — Convert `en-server`

Scope: `en-server/app/Middleware.hs` and `en-server/app/Health.hs`. At the end, the three
middleware rejections and the readiness failure are problem documents, and the duplicated
envelope builder is gone.

`en-server` already depends on `en-servant`, so import `problemResponse` and the catalog specs
from `En.Servant.Problem` and delete the local `errorBody` helper entirely. Its own comment admits
the duplication is a hazard ("the field order and names must match, so a change to the envelope
changes both") — this is the change that removes the hazard rather than restating it. Rewrite
`unauthenticated`, `readOnlyKey`, and `rateLimited` in terms of `problemResponse`, keeping their
existing codes (`unauthenticated`, `permission_denied`, `rate_limited`), their statuses, and their
extra headers — `WWW-Authenticate: Bearer` and `Retry-After` now come from the renderer rather
than the call site.

In `Health.hs`, `notReady` becomes a problem document under code `store_error`, per the Decision
Log. `alive` is a success body and stays exactly as it is: plain `application/json`,
`{"status":"ok"}`. Do not touch `Metrics.hs` — Prometheus text is a non-JSON surface and is
exempt by name.

Acceptance: `cabal build all` passes; `grep -rn "errorBody" en-server/app` is empty; a live
`curl` with no API key against an auth-enabled server returns a `401` problem document carrying
`WWW-Authenticate: Bearer`; and `curl /readyz` with the database stopped returns a `503` problem
document while `curl /healthz` still returns `{"status":"ok"}` under plain JSON.

### Milestone 6 — Close the OpenAPI half

Scope: `en-servant/src/En/Servant/OpenApi.hs`, `en-servant/test/Main.hs`, and the regenerated
`docs/api/openapi.json`. At the end the published document tells the truth about both the error
media type and the authentication the server enforces.

Three additions to `enOpenApi`, all post-derivation enrichment in the style of the existing
`withOperationIds`. The first is not enrichment so much as repair, and without it the document
lies about the media type of every successful response.

**Narrow the success responses' content maps.** Read the 2026-08-25 entries in Surprises &
Discoveries before writing this; the situation is the *opposite* of what the 2026-07-22 draft of
this plan described, and the difference decides what the pass may touch.

Error responses need no repair. `servant-openapi-hs` 5.1.0 keys a `RespondAs ct …` alternative by
`ct` and nothing else, so every one of en's error responses arrives in the derived document keyed
by `application/problem+json` already. Success responses do need repair, and for a reason
entirely internal to this plan: Milestone 1's client fix widens every verb's content-type list to
`'[JSON, ProblemJSON]`, `Respond`'s OpenAPI instance keys its content map by that whole list, and
so every `200` claims it may answer with a problem document. It cannot. Fix it where en already
lens-rewrites the document:

```haskell
-- | Drop application/problem+json from non-error responses' content maps.
--
-- Errors need no help: servant-openapi-hs keys a RespondAs alternative by its own content type,
-- so they arrive keyed by application/problem+json alone. Successes do: every verb's
-- content-type list is widened to '[JSON, ProblemJSON] so that servant-client-core's
-- Content-Type check accepts problem responses (it checks the verb's list, not the
-- alternative's), and Respond's OpenAPI instance keys its content map by that whole list. A 200
-- is only ever served as application/json; this says so.
narrowSuccessContent :: OpenApi -> OpenApi
```

keyed on the status code: responses below `400` keep only the JSON entries, and responses at
`400` and above are **left exactly as derived**. Write the comment above it in full — a future
reader finding a hand-written media-type rewrite next to a *derived* document deserves to know
it is compensating for a workaround this plan introduced elsewhere, rather than hand-authoring
the contract, which is otherwise exactly the anti-pattern the OpenAPI recipe forbids.

Do not be tempted to make the pass symmetric and force `4xx`/`5xx` to `application/problem+json`
as well. It would be dead code today, and worse than dead: it would *manufacture* a correct-
looking content key over a route accidentally written as plain `Respond … ProblemDetails`, which
serves the right body under `application/json`. That mistake is invisible in a body diff, and the
conformance test below is the only thing that catches it. A pass that rewrites the error side
would blind the test to the one failure it exists for.

Then the two genuine enrichments, neither of which can come from the route types. First, the
security scheme. `en`'s authentication is WAI middleware wrapped around the servant `Application`, so it
is nowhere in the API type — but the document is what a non-Haskell client is generated from, and
today that client sends no `Authorization` header and gets `401` on every call:

```haskell
withSecurityScheme :: OpenApi -> OpenApi
withSecurityScheme =
    (components . securitySchemes .~ SecurityDefinitions (InsOrdHashMap.singleton "bearerAuth" bearer))
        . (allOperations . security <>~ [SecurityRequirement (InsOrdHashMap.singleton "bearerAuth" [])])
  where
    bearer = SecurityScheme (SecuritySchemeHttp (HttpSchemeBearer Nothing)) Nothing
```

Document in a comment that `en-server` enforces this and `EN_AUTH_DISABLED=true` turns it off for
local development only — a reader of the artifact should not have to guess. Second, generate the
per-operation error documentation from `problemCatalog` rather than restating it, following
shomei: for each error status an operation declares, narrow the response's schema so the `code`
member is an enum of the codes the runtime can actually send at that status. The status and title
then come from the same constants the server renders from, so the document can be incomplete but
never *wrong*.

Then three conformance tests, added to `openApiDocumentTests`. **Every error response's `content`
is keyed by exactly `application/problem+json`, and no success response is** — this is the
assertion that catches a route quietly written with plain `Respond … ProblemDetails`, which would
serve the right body under the wrong media type and is invisible in a body diff, and it is *also*
the assertion that fails loudly if the `narrowSuccessContent` pass is ever dropped or if a future
version bump changes how either `Respond` or `RespondAs` keys its content map. Given that this
plan has twice been wrong-footed by exactly that — once when the generator flattened everything,
once when it stopped — this test is the single most valuable thing in the milestone. **Every code named in the document exists in
`problemCatalog`, at a status the catalog says it is sent with** — assert membership, not
uniqueness, because `not_found` and `permission_denied` each legitimately have two producers.
**Every operation carries the security requirement** — a route that lost it would be a security
bug, and the document is where it shows.

Regenerate and review: `cabal run en-openapi`, then read the diff rather than skimming it. It is
the visible proof of the whole plan, and the one artifact a client generator consumes.

Acceptance: `cabal build all && cabal test all` passes; `just openapi` is clean on a freshly
regenerated tree; and the Python summary in Validation prints `securitySchemes: ['bearerAuth']`,
`sec=True` on all twelve operations, `['application/problem+json']` for every error response, and
no `application/problem+json` on any `200`.

### Milestone 7 — Update the documents of record

Scope: two plan files, no code. `docs/plans/35-version-the-wire-contract-and-type-the-error-model.md`
is the ExecPlan that established `ErrorEnvelopeWire`; its Milestone 3 and 3b code blocks specify a
type that no longer exists, and a novice reading it alone would rebuild the shape this plan
removed. Per the revision protocol, do not rewrite its history: update those blocks in place to
the `ProblemDetails` form, and append a dated revision note naming this plan, stating that the
error *body* moved to RFC 9457 while the `MultiVerb` response model it specifies is unchanged and
every `code` string it lists survives verbatim.

Then mark follow-ups (1) through (4) closed in
`docs/plans/59-convert-en-servant-to-namedroutes-and-vertical-slices.md`'s Outcomes &
Retrospective, naming this plan, and note that its `Re-running the conformance audit` commands now
expect the converted output — the `grep` for `problem+json` that expected `0` should now be
non-zero, and the one for hard-coded `application/json` error content types should now be `0`.
While editing that file, replace its references to `haskell-jitsurei/api/…` filesystem paths with
the canonical `mori://shinzui/haskell-jitsurei/docs/api-…` URIs listed in Context and
Orientation; those paths no longer exist in that repository, so a reader following them today
finds nothing.

Record two follow-ups in this plan's Outcomes & Retrospective rather than acting on them here.
The first is the health-endpoints gap: `en` serves `/healthz` and `/readyz` from hand-written
code, while the fleet standard at `mori://shinzui/haskell-jitsurei/docs/api-health-endpoints`
requires `/health/live` and `/health/ready` from the released `servant-health` package. The
second is the upstream report on `servant-client-core`, whose `HasClient` instance for
`MultiVerb` checks a response's Content-Type against the verb's content-type list rather than the
matching alternative's — the defect that forces this plan's `'[JSON, ProblemJSON]` widening onto
every service that adopts the convention. Its sibling defect in `servant-openapi-hs` was fixed and
released between this plan's authoring and its revision; this one has not been.

Acceptance: neither plan file describes a type that no longer exists; neither cites a
`haskell-jitsurei` path that no longer exists; both carry dated revision notes naming this plan.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/en` inside the nix dev shell. Establish a baseline
first — if these do not pass before you start, fix that before blaming your own changes:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi        # must be clean before you start
```

Before writing any code, **find every error surface mechanically rather than trusting the list in
this plan**. That instruction is not boilerplate: the shomei migration recorded that two sites its
own plan's context section did not name were emitting the old shape, and only a grep found them.

```bash
grep -rn "errBody\|ErrorEnvelopeWire\|\"application/json\"" \
  en-servant/src en-server/app en-client/src en-example/src --include='*.hs' \
  | grep -v dist-newstyle
```

Treat the resulting hit list as the checklist for Milestones 2 and 5, and re-run it at the end of
Milestone 5 — it must then contain only success-path content types.

One more check before relying on any OpenAPI type or instance, and do not skip it: this plan's
Milestone 6 is calibrated to exactly which `IsSwaggerResponse` instances the resolved
`servant-openapi-hs` carries, and that has already changed once underneath this plan. First find
out what the solver actually chose:

```bash
python3 -c 'import json; p=json.load(open("dist-newstyle/cache/plan.json")); \
  print(sorted({(u["pkg-name"], u["pkg-version"]) for u in p["install-plan"] \
  if u.get("pkg-name") in ("openapi-hs","servant-openapi-hs","servant-client-core")}))'
```

Expected as of 2026-08-25: `openapi-hs 5.0.0`, `servant-openapi-hs 5.1.0`,
`servant-client-core 0.20.3.0`. Both OpenAPI packages come from Hackage — `en` moved off the
`shinzui` git pins in commit `673ab4b`. Then read the source of the version that was resolved,
**not** the development checkout at `/Users/shinzui/Keikaku/bokuno/openapi-hs-project`, which may
be ahead of it; shomei lost time to exactly that mistake. Either `cabal unpack
servant-openapi-hs-<version>` into a scratch directory, or verify the checkout's `version:` field
matches before reading it, then:

```bash
grep -rn "IsSwaggerResponse (RespondAs" <source>/src
grep -rn "IsSwaggerResponse (cs :: \[Type\]) (Respond " <source>/src
grep -rn "addMime" <source>/src        # must match nothing on 5.1.0
```

Expected on 5.1.0: `RespondAs`'s instance calls `simpleResponseSwagger @a @'[ct] @desc` — keyed by
that alternative's own content type alone, which is why error responses need no repair.
`Respond`'s instance calls `simpleResponseSwagger @a @cs @desc` — keyed by the verb's whole
content-type list, which is why success responses do. And `addMime`, the helper that used to
flatten both, is gone. If any of those three greps disagrees with this description, stop and
re-derive what Milestone 6's pass must do before writing it; the plan's answer is only correct
for the instances described here.

Then proceed milestone by milestone, building after each file so GHC's errors name the next site.
Every commit on this plan carries both trailers.

Milestone 1 — the new module, the cabal line, two unit tests, and the throwaway spike:

```bash
# create en-servant/src/En/Servant/Problem.hs; add it to exposed-modules and add
# http-media to the en-servant library build-depends in en-servant/en-servant.cabal
cabal build all && cabal test all
git diff --stat docs/api/openapi.json      # must be empty: no route changed
```

```text
feat(en-servant): RFC 9457 problem details, the content type, and the code catalog

Add En.Servant.Problem: the ProblemDetails record with one shared aeson Options
value driving its codec (and later its schema), the application/problem+json
content type, a ProblemSpec catalog carrying every existing code with its status,
title, and retryability, and the two renderers for thrown ServerErrors and for WAI
middleware. Nothing is wired up yet; a throwaway test-only MultiVerb route proves
RespondAs really stamps the media type per alternative.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 2 — the conversion. Expect a long red build; work down GHC's list:

```bash
cabal build all && cabal test all
grep -rn "ErrorEnvelopeWire" en-servant/src en-client/src   # must be empty
just openapi                                                # regenerates; review the diff
git add -A
```

```text
refactor(en-servant)!: serve RFC 9457 problem documents on every error

Convert the shared EnResponses error alternatives from Respond to RespondAs
ProblemJSON, carrying ProblemDetails; rewrite enErrorToFault as a dispatch over
the catalog; replace envelopeError with problemError; set all four ErrorFormatters
hooks; rewrite servant's unreachable empty 405 into a problem document with a WAI
middleware installed inside app, so embedders get it too. ErrorEnvelopeWire is
deleted. Every code string, status, and retryable flag is unchanged.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 3 — the 500 arm:

```bash
cabal build all && cabal test all
python3 -c 'import json; d=json.load(open("docs/api/openapi.json")); \
  print(sorted({c for p in d["paths"].values() for o in p.values() for c in o.get("responses",{})}))'
```

Expected: `['200', '400', '412', '422', '500', '503']` before Milestone 4 adds `403` and `404`.

```text
fix(en)!: report internal faults as 500, not as retryable 503s

Add EnError's InternalError arm and classify hasql SessionErrors structurally: a
connection failure is a dependency outage (503, retryable), a row- or column-decode
mismatch is en's own bug (500, not retryable). An undecodable caveat_payload and an
unparseable freshly-minted write token were both telling clients to retry forever.
Grows EnResponses, EnResult, and the exhaustiveness witness by one.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 4 — grants:

```text
feat(en-servant)!: POST /v1/grants declares its 403 and 404

Give the mint its own response list (the shared tail plus the two statuses only it
can produce), a result sum, and a hand-written AsUnion; the handler returns instead
of throwing. en-client's mintGrant now yields MintGrantResult, so a disabled minter
or a non-Allowed decision is a value rather than an opaque transport error.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 5 — `en-server`:

```bash
cabal build all
grep -rn "errorBody" en-server/app          # must be empty
```

```text
refactor(en-server): render middleware and readiness failures as problem documents

Delete the duplicated envelope builder in favour of En.Servant.Problem's shared
renderer, so the 401, 403, and 429 the auth and rate-limit middleware answer with —
and the 503 from /readyz — speak the same dialect as everything servant serves.
/healthz and /metrics are exempt by name and unchanged.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 6 — the document:

```bash
cabal run en-openapi
just openapi                                 # must be clean on a second run
python3 /dev/stdin <<'PY'
import json
d = json.load(open("docs/api/openapi.json"))
print(sorted(d["components"].get("securitySchemes", {})))
PY
```

```text
feat(en-servant): declare the bearer scheme and pin the problem media type

Add the bearerAuth security scheme and require it on every operation, so a client
generated from docs/api/openapi.json sends the Authorization header en-server
requires. Generate the per-operation error code enums from problemCatalog, and add
the three conformance tests: problem+json on every error response, every documented
code present in the catalog at the status it is sent with, and security on every
operation.

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Milestone 7 — the documents of record:

```text
docs(en): update EP-35 and close EP-59's audit follow-ups

ExecPlan: docs/plans/61-adopt-rfc-9457-problem-details-and-close-the-api-conformance-audit.md
Intention: intention_01m0xaavwqeznrgzs3j67m0q21
```

Finally, run the live transcripts in Validation and Acceptance against a real server, and record
the actual output in this plan's Outcomes & Retrospective — not a claim that they passed.


## Validation and Acceptance

The suite must be green first, but a green suite is not the acceptance criterion — this plan
changes what callers see on the wire, so acceptance is phrased as observable HTTP behavior.

```bash
cd /Users/shinzui/Keikaku/bokuno/en
cabal build all
cabal test all
just openapi        # regenerate + git diff --exit-code; must be clean
```

Expected: all seven suites pass, and `just openapi` prints nothing and exits `0`. A non-empty
diff means the checked-in artifact is stale — regenerate and commit it.

### The live service

Start the standalone server with authentication disabled, so the smoke test needs no bearer key:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
EN_AUTH_DISABLED=true just start-server
```

That applies migrations against the configured PostgreSQL (`EN_DATABASE_URL` /
`PG_CONNECTION_STRING`) and serves on `EN_PORT`, default 8080. In another shell:

**A malformed body is a problem document under the RFC media type.** This is the single most
informative check in the plan: it exercises the `ErrorFormatters` hook (an error raised *before*
any handler runs), the new body shape, and the media type together.

```bash
curl -s -D - -X POST http://localhost:8080/v1/check \
  -H 'content-type: application/json' -d 'not json at all'
```

Expected: status line `HTTP/1.1 400 Bad Request`, a header
`Content-Type: application/problem+json`, and a body of the form

```json
{"type":"about:blank","title":"Bad request","status":400,
 "detail":"Error in $: not enough input","code":"malformed_request_body","retryable":false}
```

The `detail` prose comes from aeson and will differ; everything else is fixed. A
`Content-Type: application/json`, or a body still carrying a `message` member, means a surface
was missed.

**An unmatched route, likewise** — this proves the `notFoundErrorFormatter` hook:

```bash
curl -s -D - -X POST http://localhost:8080/v1/no-such-path -d '{}'
```

Expected: `404`, `application/problem+json`, and `"code":"not_found"` with
`"title":"Not found"`.

**A successful response is still plain JSON.** The media type change must apply to errors only;
if success bodies also became `application/problem+json` the `RespondAs` was put on the wrong
alternative:

```bash
curl -s -D - -X POST http://localhost:8080/v1/check \
  -H 'content-type: application/json' \
  -d '{"consistency":{"mode":"minimizeLatency"},"context":{"values":{}},"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"}}'
```

Expected: `200`, `Content-Type: application/json;charset=utf-8`, and a `CheckResponseWire` body
(`{"decision":{"result":"denied"},"checkedAt":"en1.…"}` against a store with no tuples for this
pair — any `200` decision proves the success path is untouched).

**A declared grant failure (Milestone 4).** On a server with no issuer key configured — the
default unless `EN_GRANT_ISSUER_KEY` and friends are set — minting is disabled:

```bash
curl -s -D - -X POST http://localhost:8080/v1/grants \
  -H 'content-type: application/json' \
  -d '{"subject":{"kind":"id","objectType":"user","objectId":"alice"},"permission":"view","object":{"objectType":"space","objectId":"project-x"},"audience":"example","consistency":{"mode":"minimizeLatency"},"context":{"values":{}}}'
```

Expected: `404`, `application/problem+json`, `"code":"not_found"`,
`"detail":"grant minting is not enabled"`. Before this plan the body was the old envelope; the
observable proof of Milestone 4 is not this response — which looked similar — but its presence in
the document, checked below.

**Authentication rejections are problem documents too (Milestone 5).** Restart the server
*without* `EN_AUTH_DISABLED` and with at least one API key configured, then call it with no key:

```bash
curl -s -D - -X POST http://localhost:8080/v1/check -H 'content-type: application/json' -d '{}'
```

Expected: `401`, `WWW-Authenticate: Bearer`, `Content-Type: application/problem+json`, and
`"code":"unauthenticated"`. This is the surface most likely to be forgotten, because it lives in
WAI middleware in `en-server` rather than in the servant tree.

**The readiness probe.** With the database stopped:

```bash
curl -s -D - http://localhost:8080/readyz
```

Expected: `503`, `application/problem+json`, `"code":"store_error"`, `"retryable":true`. With the
database up: `200` and `{"status":"ok"}` under plain `application/json` — a success body, not a
problem document.

### The generated document

Everything above is also asserted statically in the checked-in artifact, which is what a
non-Haskell client is generated from:

```bash
python3 - <<'PY'
import json
d = json.load(open("docs/api/openapi.json"))
print("openapi:", d["openapi"])
print("securitySchemes:", sorted(d.get("components", {}).get("securitySchemes", {})))
for p in sorted(d["paths"]):
    for m, o in d["paths"][p].items():
        if m in ("get", "post"):
            errs = {c: sorted(r.get("content", {}))
                    for c, r in o.get("responses", {}).items() if c >= "400"}
            oks = {c: sorted(r.get("content", {}))
                   for c, r in o.get("responses", {}).items() if c < "400"}
            print("%-5s %-38s sec=%s ok=%s errors=%s"
                  % (m.upper(), p, bool(o.get("security")), oks, errs))
PY
```

Expected after Milestone 6: `3.1.0`; `securitySchemes: ['bearerAuth']`; `sec=True` on every one
of the twelve operations; every error response's content keyed by `['application/problem+json']`
— never `['application/json']`, which would mean a route was written with plain
`Respond … ProblemDetails` and serves the right body under the wrong media type; and **no `200`
listing `application/problem+json`**, which would mean `narrowSuccessContent` was dropped or
never ran, leaving the document claiming every successful response might be an error document.
Those two failures look alike in a diff and have opposite causes, which is why the summary prints
both columns. `POST /v1/grants` must now list `403` and `404` alongside the shared tail, and every
`MultiVerb` operation must list `500`.

### What the test suite must additionally prove

Beyond the existing golden, error-model, routing, and OpenAPI tests continuing to pass with their
assertions updated to the new shape, four new properties are added and each must fail if broken:

The **field rename is pinned**: encoding a `ProblemDetails` yields an object whose keys are
exactly `type`, `title`, `status`, `detail`, `code`, `retryable`. Without this, a later "cleanup"
to plain generic derivation would silently ship a `problemType` member on the wire, since `type`
is a Haskell reserved word and the rename lives in a shared aeson `Options` value.

The **catalog is complete and consistent**: every `code` that appears anywhere in the generated
document is present in `problemCatalog`, and every catalog entry's `status` matches the status the
response list assigns it. This is what keeps `title` stable per code and stops the runtime and the
document drifting apart.

The **internal-versus-dependency classification is pinned** (Milestone 3): a hasql row-decode
failure maps to `500` with `retryable = False`, and a connection failure maps to `503` with
`retryable = True`. Assert it over `En.Error.EnError` values directly, in the style of the
existing `errorModelTests`, so it does not need a live database.

**Every wire DTO's `ToJSON` still validates against its `ToSchema`**, `ProblemDetails` included —
the existing `toJsonMatchesToSchema` test, extended. This is the test that catches a `ToSchema`
that forgot to bridge the same aeson `Options` the codec uses, which for this one type is the
easiest possible mistake.

### Structural acceptance

```bash
grep -rn "ErrorEnvelopeWire" en-servant/src en-server/app en-client/src en-example/src
grep -rn '"application/json"' en-servant/src en-server/app
```

Expected: the first prints nothing at all — the type is gone, not deprecated. The second prints
only success-path content types (and `/healthz`'s `{"status":"ok"}`); no error response may be
built with it.


## Idempotence and Recovery

Every milestone here is an ordinary source edit plus a regenerated build artifact. Nothing
touches the database: this plan adds no migration, changes no table, and reads no persistent
state that it also writes. `just start-server` runs the existing idempotent migrations before
serving, and the standalone server can be restarted freely at any point.

Re-running any step is safe and converges. `cabal build all` and `cabal test all` are pure
functions of the tree. `cabal run en-openapi` overwrites `docs/api/openapi.json` from the route
types, so running it twice produces the same bytes; `just openapi` is exactly that plus
`git diff --exit-code`, which is *designed* to be run repeatedly and is the check that tells you
whether the artifact is stale.

Commit at each milestone boundary so there is always a clean point to return to.
`git checkout -- .` discards uncommitted work; `git reset --hard HEAD` returns to the last
commit. If a milestone goes wrong mid-way, prefer resetting to its boundary over unwinding by
hand — the type changes in Milestones 2 and 3 touch many call sites at once, and a half-reverted
tree is harder to reason about than a re-done one.

Two specific recovery notes:

**If Milestone 2's conversion stalls part-way through the handlers**, the tree will not compile,
because `EnResult`'s constructors change payload type from `ErrorEnvelopeWire` to
`ProblemDetails` all at once. That is deliberate — GHC's error list *is* the worklist, and each
error names the next site to fix. Work down it; do not introduce a compatibility shim that lets
half the tree keep building, because a shim would let a surface be forgotten, and a forgotten
surface is precisely the two-dialect outcome this plan exists to prevent. If you must stop
mid-milestone, commit nothing and use `git stash`.

**If the OpenAPI document comes back missing its error responses at any point** — that is, if
`just openapi` produces a `docs/api/openapi.json` whose operations list only `200` — stop. It
means the derivation is no longer going through `openapi-hs` / `servant-openapi-hs`, the only
packages that carry a `HasOpenApi` instance for `MultiVerb`. Their upstream ancestors
`openapi3` / `servant-openapi3` do not: against those an API using `MultiVerb` does not
typecheck at all, so a "fix" that gets it compiling again by flattening routes back to plain
`Verb`s would throw away every declared error response. Check what
`en-servant/en-servant.cabal` depends on and what `dist-newstyle/cache/plan.json` resolved
before changing anything else. Do not "fix" it by hand-editing the artifact: it is a build
product, and an edit is lost the next time anyone runs the generator.


## Interfaces and Dependencies

### Libraries

**No new package, no new git pin, and no cohort change** — though not because everything works
out of the box. One defect in the resolved toolchain is worked around inside `en`, for the
reasons in the Decision Log: `servant-client-core`'s `HasClient` instance for `MultiVerb` checks
a response's Content-Type against the *verb's* content-type list rather than the matching
alternative's, so every problem response is rejected before its body is decoded unless the verb's
list is widened to `'[JSON, ProblemJSON]`. Report it upstream as a follow-up. Its sibling defect,
`servant-openapi-hs`'s flattening of per-alternative content types, **was** fixed upstream and
released between this plan's authoring and its 2026-08-25 revision; what remains of Milestone 6's
repair pass is cleaning up after the client workaround, not after the generator.

The versions this revision was verified against, from `dist-newstyle/cache/plan.json`: GHC 9.12.4,
servant / servant-server / servant-client / servant-client-core all 0.20.3.0, `http-media`
0.8.1.1, `openapi-hs` 5.0.0 and `servant-openapi-hs` 5.1.0 — both from **Hackage**, not from a
`source-repository-package` pin. `en` moved onto the released cohort in commit `673ab4b`
("build(deps): consume openapi-hs and servant-openapi-hs from Hackage"), which is a change from
what the 2026-07-22 draft of this plan described.

The Milestone 1 implementation gate re-verified that exact cohort on 2026-08-25. Mori located
the registered source for `mori://shinzui/openapi-hs`,
`mori://shinzui/servant-openapi-hs`, and `mori://haskell-servant/servant`; those source trees
match the resolved versions and the instances described in this plan. Hackage's authoritative
package metadata and the upstream Git tags still list 5.0.0, 5.1.0, 0.20.3.0, and 0.8.1.1 as
the latest releases of `openapi-hs`, `servant-openapi-hs`, Servant, and `http-media`
respectively. `cabal build all` succeeded with the explicit cohort bounds before the new module
was added and again after the full milestone.

The `RespondAs` combinator this plan is built on ships in stock servant 0.20, which `en` already
depends on. The two OpenAPI packages must stay as they are and must not be "simplified" to
`openapi3` / `servant-openapi3`: those carry no `HasOpenApi` instance for `MultiVerb`, so an API
written as en's now is cannot derive a document at all. `cabal.project` needs no edit — the only
`source-repository-package` block it carries is the unrelated `biscuit-haskell` pin.

Two `build-depends` changes are needed, both in the `en-servant` library stanza in
`en-servant/en-servant.cabal`. First, add **`http-media`**: it supplies the `(//)` operator used
to write `contentType _ = "application" // "problem+json"`. Servant depends on it transitively,
but cabal requires the direct dependency to be declared. Second, give the OpenAPI cohort the
version bounds it currently lacks — `openapi-hs >=5.0 && <5.1` and
`servant-openapi-hs >=5.1 && <5.2` — because the two are one compatibility cohort that the solver
is otherwise free to split now that they come from Hackage. Nothing else is added anywhere:
`en-server/en-server.cabal` already depends on `en-servant`, so Milestone 5 imports the shared
renderer rather than growing its dependency list, and the test stanza already has everything it
needs.

### Types and functions that must exist, by milestone

At the end of **Milestone 1**, in `en-servant/src/En/Servant/Problem.hs` (a new module):

```haskell
data ProblemDetails = ProblemDetails
  { problemType :: !Text   -- rendered as "type"; always "about:blank"
  , title :: !Text
  , status :: !Int
  , detail :: !Text
  , code :: !Text
  , retryable :: !Bool
  }

problemJsonOptions :: Options          -- the single field mapping shared by codec and schema
instance ToJSON ProblemDetails         -- via genericToJSON problemJsonOptions
instance FromJSON ProblemDetails       -- via genericParseJSON problemJsonOptions

data ProblemJSON                       -- the application/problem+json content type
instance Accept ProblemJSON
instance (ToJSON a) => MimeRender ProblemJSON a
instance (FromJSON a) => MimeUnrender ProblemJSON a

data ProblemSpec = ProblemSpec { code :: !Text, status :: !Int, title :: !Text }
problemCatalog :: [ProblemSpec]        -- one entry per code; the twenty listed in Context
problem :: ProblemSpec -> Text -> ProblemDetails   -- spec + request-specific detail
```

At the end of **Milestone 2**, every `MultiVerb` in the five slice modules carries the content-type
list `'[JSON, ProblemJSON]` rather than `'[JSON]`, and in
`en-servant/src/En/Servant/Response.hs` and `en-servant/src/En/Servant/Seam.hs`, with
`ErrorEnvelopeWire` **deleted**:

```haskell
-- Response.hs
type EnResponses (description :: Symbol) a
  -- '[ Respond 200 description a
  --  , RespondAs ProblemJSON 400 "Invalid request"            ProblemDetails
  --  , RespondAs ProblemJSON 412 "Write precondition failed"  ProblemDetails
  --  , RespondAs ProblemJSON 422 "Resolution limit exceeded"  ProblemDetails
  --  , RespondAs ProblemJSON 503 "Tuple store unavailable"    ProblemDetails ]
data EnResult a = EnOk a | EnClientError !ProblemDetails | …   -- payloads change type
instance AsUnion (…) (EnResult a)                              -- witness still at the 6th shift
faultToResult :: EnFault -> EnResult a                         -- still total

-- Seam.hs
data EnFault = BadRequestFault !ProblemDetails | …
enErrorToFault :: EnError -> EnFault
problemError :: ServerError -> ProblemDetails -> ServerError   -- replaces envelopeError;
                                                               -- sets body AND Content-Type
```

At the end of **Milestone 3**, `En.Error.EnError` distinguishes a dependency outage from an
internal fault, and the shared list, the result sum, and the witness have each grown by one:

```haskell
-- en-core/src/En/Error.hs
data EnError = … | StoreError Text | InternalError Text

-- en-servant/src/En/Servant/Response.hs
--   … , RespondAs ProblemJSON 500 "Internal error" ProblemDetails , … (six alternatives)
data EnResult a = … | EnInternal !ProblemDetails
--   fromUnion's last clause becomes S (S (S (S (S (S impossible))))) -> case impossible of {}
```

At the end of **Milestone 4**, in `en-servant/src/En/Check/Api.hs`:

```haskell
type MintGrantResponses          -- the shared tail plus 403 and 404, both RespondAs ProblemJSON
data MintGrantResult = MintGrantOk MintGrantResponseWire | MintForbidden !ProblemDetails | …
instance AsUnion MintGrantResponses MintGrantResult
mintGrantHandler :: Env es -> MintGrantRequestWire -> Handler MintGrantResult   -- returns, never throws
```

and correspondingly in `en-client/src/En/Client.hs` the `mintGrant` field becomes
`MintGrantRequestWire -> ClientM MintGrantResult`.

At the end of **Milestone 5**, `en-server/app/Middleware.hs` and `en-server/app/Health.hs` build
their responses from `En.Servant.Problem` and the local `errorBody` helper is gone.

At the end of **Milestone 6**, in `en-servant/src/En/Servant/OpenApi.hs`:

```haskell
instance ToSchema ProblemDetails       -- genericDeclareNamedSchema (fromAesonOptions problemJsonOptions)
narrowSuccessContent :: OpenApi -> OpenApi   -- responses < 400 keep only JSON; 4xx/5xx untouched
withSecurityScheme :: OpenApi -> OpenApi     -- declares bearerAuth and requires it on every operation
enOpenApi :: OpenApi                         -- toOpenApi apiProxy, then withOperationIds,
                                             -- narrowSuccessContent, withSecurityScheme
```

### Modules that must not change

`En.Servant.Authorize` keeps `requirePermission`'s exact signature (only the body of the error it
throws changes), because `en-example` and embedded hosts call it. `En.Servant.Seam` keeps `Env`,
`AppEffects`, `MintEnv`, `ActiveSchema`, `EnServer`, `runEngine`, and `runEngineEither` — `nagare`
and `kikan-en` import that module directly. `En.Servant.API` keeps exporting `app`, `EnApi (..)`,
and the whole re-export umbrella, and no module moves: this plan changes payload types, not
module layout.


## Revision Note — 2026-08-25

**What changed.** This plan was refreshed against the fleet's Haskell pattern catalog as it
stands today, and renamed from "RFC 7807" to "RFC 9457" — file, `slug`, `title`, heading, and the
`ExecPlan:` trailers in every commit-message block. No milestone was added, removed, or
reordered, and the plan's scope, its twenty error codes, and its seven-milestone shape are
unchanged.

**Why.** Nothing in this plan has been implemented — every Progress box is unchecked,
`grep -rn ProblemDetails` over the Haskell tree matches nothing, `ErrorEnvelopeWire` is still the
live error type in `en-servant/src/En/Servant/Seam.hs`, and `docs/api/openapi.json` still keys
every error on `application/json`. In the month it sat unstarted, four things it depends on moved:

1. **The standard was renamed.** RFC 9457 obsoletes RFC 7807 with an identical wire format, and
   the canonical document renamed itself accordingly. Nothing on the wire changes.
2. **The catalog was restructured.** The three governing documents moved from a flat `api/`
   directory into `patterns/api/` and acquired canonical `mori://` URIs. Context and Orientation
   now cites those URIs instead of filesystem paths, per the cross-repository reference rule, and
   Milestone 7 picks up repairing the same stale paths in ExecPlan 59.
3. **The OpenAPI packages were released and `en` moved onto them.** `openapi-hs` and
   `servant-openapi-hs` are no longer `source-repository-package` pins; `en` resolves 5.0.0 and
   5.1.0 from Hackage (commit `673ab4b`). Interfaces and Dependencies, Concrete Steps, and
   Idempotence and Recovery all described the old pinned world and would have sent an implementer
   looking for `dist-newstyle/src/` unpacks and `cabal.project` stanzas that no longer exist.
4. **The upstream generator defect was fixed.** `addMime` — the helper that flattened every
   response's content map onto the verb's whole content-type list — is gone in
   `servant-openapi-hs` 5.1.0. This is the substantive change, and it is *not* the simple
   deletion the old draft anticipated. The 2026-07-22 text said "if a future pin bump removes
   `addMime`, delete that pass"; following that instruction would now ship a document claiming
   every `200` might answer with a problem document, because the still-necessary client
   workaround (widening each verb's list to `'[JSON, ProblemJSON]`) pollutes the success side
   through `Respond`'s OpenAPI instance. The pass is therefore kept, renamed
   `narrowSuccessContent`, and narrowed to touch only responses below `400` — deliberately
   leaving the error side alone so Milestone 6's conformance test can still catch a route
   accidentally written as plain `Respond … ProblemDetails`. Milestone 1's spike, Milestone 2's
   intermediate-state note, Milestone 6, Concrete Steps, Validation, and the Interfaces
   signature block were all updated to match.

**Also recorded.** A fifth catalog change is noted but deliberately not acted on: the new
Kubernetes health-endpoints standard requires `/health/live` and `/health/ready` from the
released `servant-health` package, while `en` serves hand-written `/healthz` and `/readyz`. That
is a genuine conformance gap, it is a URL migration rather than a body-format migration, and it
belongs in its own plan; the Decision Log says so and Milestone 7 records it as a follow-up.
`en-servant/en-servant.cabal`'s missing OpenAPI cohort bounds were folded into Milestone 1, which
already edits that file.

All four living sections were updated: Progress (two milestone bullets restated), Surprises &
Discoveries (three entries marked superseded or confirmed, two new dated entries added), the
Decision Log (one entry amended, four new entries), and this note. Outcomes & Retrospective stays
empty, because the plan remains unimplemented.


## Revision Note — 2026-08-25 (MasterPlan implementation start)

**What changed.** The child plan now carries MasterPlan 11's authoritative intention in its
frontmatter and commit examples. Milestone 1's implementation also corrected the direct
dependency inventory for the shared WAI renderer and the temporary real-client spike.

**Why.** This plan was adopted after its standalone draft was written. Implementing it under
MasterPlan 11 requires one intention across the initiative, and Cabal requires every imported
package to be declared directly even when it is already present transitively. Neither change
alters the wire-contract scope or milestone ordering.
