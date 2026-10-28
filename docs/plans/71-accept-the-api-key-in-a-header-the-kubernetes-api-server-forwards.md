---
id: 71
slug: accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards
title: "Accept the API key in a header the Kubernetes API server forwards"
kind: exec-plan
created_at: 2026-10-28T20:07:14Z
intention: "intention_01m621z2x8e3nsfz0af3b2xh8m"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-28T20:07:14Z
---

# Accept the API key in a header the Kubernetes API server forwards

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

It implements improvement request IR-1,
[docs/improvement-requests/accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md](../improvement-requests/accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md)
(canonical handle `mori://shinzui/en/okf/improvement-requests/concepts/IR-1`), raised by the
Nagare platform (`mori://shinzui/nagare`). Its four acceptance criteria, AC-1 to AC-4, are the
acceptance of this plan; each milestone below names the criteria it discharges.


## Purpose / Big Picture

`en-server` is the standalone authorization service in this repository. Every request to it
must carry an API key, and today the key can arrive in exactly one place: the HTTP header
`Authorization: Bearer <secret>`. That is a problem for one real deployment. Nagare runs
`en-server` inside a Kubernetes cluster and reaches it through the Kubernetes API server's
*service proxy*, the API server's built-in feature that forwards an HTTP request to a Service
inside the cluster after authenticating the caller with their own kubeconfig credentials. The
API server deletes the `Authorization` header once it has authenticated the caller (the
Kubernetes source is `k8s.io/apiserver/pkg/endpoints/filters/authentication.go`, in
`withAuthentication`: `req.Header.Del("Authorization")`), so En never sees the key and answers
`401`. Nagare's command-line tool therefore opens a `kubectl port-forward` for every single
call, which costs about a second each time and a page of readiness and teardown logic.

After this plan, a caller may present the same key in a second header, `X-En-Api-Key: <secret>`,
which the API server forwards untouched. Both headers authenticate against the same configured
keys with the same roles, the same constant-time comparison and the same caller identity.
`Authorization: Bearer` remains the default and the documented first choice; the new header is
for callers behind a proxy that consumes `Authorization`. The published OpenAPI document declares
the second scheme so a client can discover it before relying on it, and the server documentation
explains when to use it.

The change was reviewed against the user's condition that it must fit En and must not be a hack.
It fits: `en-server/app/Middleware.hs` was written so that "a future verifier replaces the body
of `authenticate` without touching any handler", and this change replaces exactly that body. It
adds no configuration, no new key tier and no new error. The OpenAPI vocabulary it uses, an
`apiKey` security scheme located `in: header`, is a first-class part of OpenAPI 3.1, so the
contract stays honest and machine-readable. The alternatives considered on the Nagare side, a
host port, a subnet route or an ingress on the operator's private network, would expose En's
write API to every device on that network with only the key as the gate, whereas the API server
keeps a client certificate and role-based access control in front of En. The Decision Log records
the rules that keep the second header from weakening the perimeter: a request may carry either
header, or both when they agree, and nothing else.

You can see it working in three ways once the plan is complete. Start a server with the
documented key variables and the request below answers `200`:

```bash
curl -sS -H 'X-En-Api-Key: writer-secret-0123456789' http://127.0.0.1:18081/v1/schema
```

`GET /v1/openapi.json` lists `apiKeyAuth` beside `bearerAuth` under
`components.securitySchemes`, and every authenticated operation accepts either. And the new
`en-server-tests` suite plus the Hurl black-box suites prove, in the repository's own checks,
that both headers behave identically.


## Progress

- [ ] Milestone 1 (AC-1, AC-2): `authenticate` in `en-server/app/Middleware.hs` accepts the
      secret from `Authorization: Bearer` or `X-En-Api-Key`, refuses disagreeing or malformed
      credentials, and a new `en-server-tests` suite proves both headers produce identical
      responses and caller identity. Acceptance: `cabal test en-server-tests` passes with the
      cases listed under Milestone 1, and `cabal build en-server` is warning-free.
- [ ] Milestone 2 (AC-3): `withSecurityScheme` in `en-servant/src/En/Servant/OpenApi.hs`
      declares `apiKeyAuth` (`type: apiKey`, `in: header`, `name: X-En-Api-Key`) beside
      `bearerAuth`, every non-probe operation lists both as alternatives, probes keep none,
      `docs/api/openapi.json` is regenerated, and the en-servant OpenAPI test asserts all of it.
      Acceptance: `cabal test en-servant-tests` passes and `just openapi` reports no drift.
- [ ] Milestone 3 (AC-1, AC-3 over a real socket): the Hurl safe suite authenticates one request
      with the new header and asserts the live document's `apiKeyAuth` scheme; the perimeter
      suite covers the new header's success, read-only refusal, unknown secret, and the
      both-headers rules. Acceptance: `just start-and-test` is green and a perimeter run against a
      two-key server passes every case.
- [ ] Milestone 4 (AC-4, closure): `docs/user/service-and-operations.md` documents the header
      with a runnable curl example and the proxy path, the capability catalog entry is updated,
      ADR 9 records the two-carrier decision, and IR-1 is marked `completed` with evidence.
      Acceptance: the documented curl succeeds against a server started with the documented
      variables; both OKF bundles validate; ADR file exists and is linked from here.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Accept IR-1 and implement it in En rather than asking Nagare to work around it.
  Rationale: the request needs a server-side change by construction, since the proxy deletes
  the only header En reads. The change is confined to the credential-parsing step the middleware
  was designed to let evolve, uses standard OpenAPI vocabulary, adds no configuration or key
  tier, and the rejected alternative (exposing En on a private network) replaces a client
  certificate plus RBAC with a bare key as the only gate.
  Date: 2026-10-28

- Decision: A request authenticates only when every credential it presents is the same secret.
  Concretely, `authenticate` collects one candidate secret from each `Authorization` header
  (which must parse as `Bearer <secret>`) and each `X-En-Api-Key` header (taken verbatim). If
  there are no candidates, if any `Authorization` header is not a well-formed bearer credential,
  or if two candidates differ, the request is unauthenticated. Identical duplicates are allowed.
  Only then is the single candidate compared, in constant time, against the configured keys.
  Rationale: this satisfies AC-2 and closes the gaps AC-2 does not spell out. A request that
  would be rejected today (malformed or wrong `Authorization`) can never be rescued by adding a
  second header, and a request carrying two different valid keys does not get to pick the
  stronger one. The proxy case never carries `Authorization` at all, so the strict rule costs it
  nothing. The candidates are compared to each other with the same constant-time primitive as
  the key check, so there is one comparison discipline to reason about.
  Date: 2026-10-28

- Decision: Keep the header name `X-En-Api-Key`, owned by one exported constant,
  `apiKeyHeaderName` in `En.Servant.OpenApi`, that both the OpenAPI declaration and the
  middleware use.
  Rationale: RFC 6648 discourages new `X-` header names, but the consumer contract in
  `mori://shinzui/nagare/plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward`
  already names this header, En's existing own headers (`X-En-Caller`, `X-Request-Id`) use the
  prefix, and `X-API-Key` is the de-facto convention the `apiKey` scheme was designed for.
  Renaming would buy conformance with a recommendation at the price of a cross-repository
  coordination. One constant stops the contract and the enforcement from drifting apart; the
  en-servant test pins its literal value and the Hurl suites pin both ends over a socket.
  Date: 2026-10-28

- Decision: The `401` response is unchanged, including `WWW-Authenticate: Bearer`.
  Rationale: RFC 7235 requires a `401` to carry at least one challenge naming an authentication
  *scheme*. `Bearer` is the one registered scheme En supports; a secret in a custom header is not
  a scheme and has no challenge syntax. Bearer remains the documented default, so advertising it
  alone is accurate.
  Date: 2026-10-28

- Decision: Test the middleware with a new `en-server-tests` suite that compiles
  `en-server/app/Middleware.hs` directly (`hs-source-dirs: test app`), rather than moving the
  module into `en-servant` or splitting `en-server` into an internal library and an executable.
  Rationale: `en-server` has no test suite today, and AC-1 asks for one. The middleware is an
  `en-server` concern (its key tiers come from `en-server`'s environment), so it does not belong
  in the library package an embedding host uses. Splitting the executable is a larger
  restructuring with no other motivation. Compiling one small module twice is the standard Cabal
  pattern and costs nothing observable.
  Date: 2026-10-28

- Decision: `en-client` is unchanged.
  Rationale: IR-1 does not ask for it. `En.Client` leaves credentials to the caller's
  `ClientEnv` (its module header says a rejected key surfaces as a transport error), so a caller
  that wants the new header sets it where it sets `Authorization` today.
  Date: 2026-10-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Vocabulary.** *en-server* is the deployable service built from `en-server/app/`. A *WAI
middleware* is a function that wraps the whole HTTP application and may inspect or answer a
request before the application sees it; En's authentication is one such wrapper. An *API key* is
a shared secret configured by name in two tiers: `EN_API_KEYS_READ_WRITE` holders may call every
endpoint, `EN_API_KEYS_READ_ONLY` holders only the query endpoints. The *caller header* is
`X-En-Caller`: after a key is verified the middleware deletes any client-supplied value and sets
it to the key's name, so inner layers (rate limiting, logging) know who is calling without
seeing the secret. A *security scheme* is OpenAPI's description of how a client authenticates;
an operation's `security` list names the schemes it accepts, and several entries mean "any one of
these". *Hurl* is the command-line HTTP test tool the repository uses for black-box API checks.
An *OKF bundle* is a directory of Markdown documents governed by a profile that `okf validate`
enforces; `docs/improvement-requests/` and `docs/capabilities/` are two such bundles.

**The authentication path today.** `en-server/app/Middleware.hs` exports `authMiddleware`,
which `en-server/app/Main.hs` places outside rate limiting and the request logger (see the
"Outermost first" comment near `wrappedApp`). For every request whose raw path is not one of the
health probes (`isExemptPath`, sourced from `Servant.Health.Paths.healthRawPaths`),
`authenticate` looks up the `Authorization` header, requires `Bearer <secret>` via
`bearerSecret` (case-insensitive scheme, exactly two words), and compares the secret with each
configured key using `Data.ByteArray.constEq` from the `ram` package. No match answers the
`401` problem document built by `En.Servant.Problem.problemResponse specUnauthenticated`, whose
headers (`problemHeaders` in `en-servant/src/En/Servant/Problem.hs`) attach
`WWW-Authenticate: Bearer` to every `401`. A match with a `ReadOnly` key on a write route
(`isWriteRequest`: `POST` under `/v1/relationships`) answers the `403` problem; otherwise
`withCaller` rewrites `X-En-Caller` and the request continues. Keys are parsed once at startup
by `parseAuth` in `en-server/app/Config.hs`; nothing in that file changes.

**The OpenAPI contract today.** `En.Servant.OpenApi.enOpenApi` in
`en-servant/src/En/Servant/OpenApi.hs` derives the document from the API type, then
`withSecurityScheme` adds the one fact the types cannot carry: it sets
`components.securitySchemes` to exactly `bearerAuth` (`SecuritySchemeHttp (HttpSchemeBearer
Nothing)`), prepends a `bearerAuth` requirement to every operation, and clears `security` on
the probe paths. The executable `en-openapi` (`en-servant/app/OpenApi.hs`) writes the document
to `docs/api/openapi.json` with sorted keys; `just openapi` regenerates it and fails if the
checked-in file drifts. The test `openApiDocumentTests` in `en-servant/test/Main.hs` asserts
"openapi defines exactly the bearerAuth security scheme", that every `POST` path and
`GET /v1/schema` carries `expectedSecurity` (`[{"bearerAuth": []}]`), and that the probe routes
have `security` equal to `null`. The checked-in document currently reads:

```json
"securitySchemes": {
  "bearerAuth": {
    "scheme": "bearer",
    "type": "http"
  }
}
```

**Black-box suites.** `en-servant/test/hurl/run.sh` (invoked by `just hurl`, and by
`just start-and-test` in `.github/workflows/hurl.yml`) formats every `.hurl` file with
`hurlfmt --check` and runs the read-only families `health`, `openapi`, `checks`, `lookups`,
`expands` and `schema` against a running server, injecting the key as the Hurl secret
`api_key`. `en-servant/test/hurl/perimeter/perimeter.hurl` is an opt-in suite run by hand
against a server started with separate read-write and read-only keys; its README gives the exact
startup and `--secret` commands. It already covers the public probe, missing and unknown bearer
credentials, a successful bearer read, and a read-only bearer refused on a write.

**What must not change, and why it does not.** The request logger (`logLine` in
`en-server/app/Observability.hs`) emits method, path, status, duration and `user_agent` only,
so a secret in the new header is never logged. The OpenTelemetry WAI middleware
(`hs-opentelemetry-instrumentation-wai`, constructed in `en-server/app/Telemetry.hs`) records
`User-Agent` and `Host` as span attributes and reads the other headers only to extract trace
context, so the new header does not reach traces either. Rate limiting keys its buckets by the
verified key name, which both headers produce identically. Metrics label by path. `en-client`
sets no credential header of its own.

**Documentation that describes authentication.** `docs/user/service-and-operations.md`,
section "Authentication, rate limiting, and TLS" (around line 678), has the variable table, the
bearer `curl` example, the three-row failure table whose `401` row says "No `Authorization`
header, a non-bearer scheme, or an unknown secret", and a "Transport security" subsection that
opens "Bearer keys are only as secret as the transport that carries them". The
"Machine-readable description" subsection (around line 838) says the OpenAPI endpoint "requires a
bearer key like any other endpoint". `docs/capabilities/standalone-authorization-server.md`
(CAP-20) lists `en-server/app/Middleware.hs` as evidence proving "Constant-time bearer-key
authentication" and has a bullet "Bearer API keys compared in constant time".

**The improvement request's lifecycle.** The IR bundle is governed by the
`coordination.improvementRequests` profile pinned at okf-profiles v0.12.0, whose `status` values
are `proposed`, `accepted`, `in-progress`, `completed`, `rejected`, `withdrawn` and
`superseded`; `completed` requires `completedAt` (RFC 3339 UTC) and recommends `resolution`;
`targetPlan` names the implementing plan. This plan's creation moved IR-1 from `proposed` to
`accepted` with `targetPlan` pointing here. Every content change to a bundle document bumps its
`generated.at` and appends a `log.md` entry with `okf log add`; the strict validation command is
in Concrete Steps.

**Architecture decision records.** `docs/adr/` is a plain filesystem corpus (no OKF profile):
one `NNNN-slug.md` per decision with `title`, `status`, `date`, `authors` and `related`
frontmatter, as in
[docs/adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md](../adr/0004-en-s-health-probe-surface-is-owned-by-servant-health.md).
Two existing records bear on this work. ADR 4 fixes that the probe routes under `/health` stay
unauthenticated and that middleware must take their paths from
`Servant.Health.Paths.healthRawPaths` rather than restating literals; this plan keeps the probes
exempt from both schemes and keeps using that constant.
[docs/adr/0007-generic-lens-labels-are-en-s-record-access-idiom.md](../adr/0007-generic-lens-labels-are-en-s-record-access-idiom.md)
fixes the record-access idiom new code must follow (`key ^. #keySecret`, never a field
selector). No ADR describes which headers may carry a credential; Milestone 4 adds ADR 9 for
that. The relevant fleet patterns are `mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`
(the security scheme lives in the one generator module, as it does here),
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing` (authentication cases belong
in an opt-in perimeter suite fed by `--secret`), and
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details` (a `401` carries
`WWW-Authenticate: Bearer`).

**Prior plans that built what this plan touches**, all checked in under `docs/plans/`: plan 33
added the key tiers and this middleware, plan 61 added `bearerAuth` to the OpenAPI document and
the problem-details `401`, plan 64 moved the probes to `servant-health`, and plan 66 wrote the
Hurl suites.

**The consumer.** Nagare's plan 216 (handle above) will, once an En release with this change is
deployed, send `X-En-Api-Key` through
`/api/v1/namespaces/<namespace>/services/en:80/proxy/<path>` and stop spawning port-forwards. It
will first read `/v1/openapi.json` and refuse to use the header unless
`components.securitySchemes.apiKeyAuth` is present, which is why Milestone 2's shape is part of
the contract and not a nicety. Whether the API server forwards the new header end to end is
verified by that plan on a real cluster; this plan's acceptance is against En directly.


## Plan of Work

### Milestone 1: the middleware accepts the second header, with a test suite to prove it

Scope: `en-servant/src/En/Servant/OpenApi.hs` gains one exported constant;
`en-server/app/Middleware.hs` changes `authenticate` and its documentation;
`en-server/en-server.cabal` gains a test suite; `en-server/test/Main.hs` is new. At the end,
`cabal test en-server-tests` demonstrates every AC-1 and AC-2 behaviour against the real
middleware without a database or a socket.

Add to `En.Servant.OpenApi`'s export list and body:

```haskell
-- | The header that carries an API key for callers behind a proxy that consumes
-- @Authorization@. Declared here because this module publishes it as the @apiKeyAuth@
-- security scheme; @en-server@'s middleware imports it so the contract and its
-- enforcement cannot name different headers.
apiKeyHeaderName :: HeaderName
apiKeyHeaderName = "X-En-Api-Key"
```

(`HeaderName` comes from `Network.HTTP.Types`, which `en-servant` already depends on.) Milestone 2
uses the constant in the scheme declaration; in this milestone it is only exported.

In `Middleware.hs`, import `apiKeyHeaderName` from `En.Servant.OpenApi` and replace
`authenticate` so it implements the agreement rule from the Decision Log. The shape to aim for:

```haskell
-- | Constant-time credential check. Returns the matching key, if any.
--
-- The secret may be presented as @Authorization: Bearer <secret>@ or, for callers
-- behind a proxy that consumes @Authorization@, as @X-En-Api-Key: <secret>@. A request
-- may carry either, or both when they agree. A malformed @Authorization@ header or two
-- headers presenting different secrets leave the request unauthenticated: adding a
-- header can never rescue a request that would otherwise be refused.
authenticate :: [ApiKey] -> Request -> Maybe ApiKey
authenticate keys request = do
  candidates <- traverse presented credentialHeaders
  secret <- agreeing candidates
  find (\key -> constEq (key ^. #keySecret) secret) keys
  where
    credentialHeaders =
      [ header
      | header@(name, _) <- requestHeaders request,
        name == hAuthorization || name == apiKeyHeaderName
      ]
    presented (name, value)
      | name == hAuthorization = bearerSecret value
      | otherwise = Just value
    agreeing [] = Nothing
    agreeing (first : rest)
      | all (constEq first) rest = Just first
      | otherwise = Nothing
```

`bearerSecret` is unchanged. Header names are case-insensitive by type (`HeaderName` is a
`CI ByteString`), so `x-en-api-key` from an HTTP/2 client matches. Update the module header
comment (it currently opens "Bearer-key authentication") and the `keySecret` field comment ("The
bearer secret presented in the Authorization header") so they describe both carriers. Nothing
else in the module changes: the exempt paths, the write-route check, the caller rewrite and the
`401`/`403` responses are shared by both carriers by construction.

Add the test suite to `en-server/en-server.cabal`, importing the same `warnings, shared` common
stanzas as the executable (the fleet core standard asks every stanza to import the shared
settings):

```text
test-suite en-server-tests
  import: warnings, shared
  type: exitcode-stdio-1.0
  hs-source-dirs: test app
  main-is: Main.hs
  other-modules: Middleware
  build-depends:
    base >=4.19 && <5,
    bytestring,
    containers,
    en-core,
    en-servant,
    generic-lens >=2.2 && <2.4,
    http-types,
    ram,
    servant-health ^>=0.1,
    text,
    wai,
    wai-extra,
```

`cabal-gild` formats the file (it runs under `treefmt`), so do not fight its layout. Write
`en-server/test/Main.hs` in the house style of `en-servant/test/Main.hs`: a plain `main :: IO ()`
that runs a sequence of assertions and fails with a labelled message (copy the small
`assertEqual`/`assertBool` helpers; they are twelve lines). Drive `authMiddleware (AuthKeys keys)`
with `Network.Wai.Test` (`runSession`, `srequest`, `SRequest`, `defaultRequest`, `setPath`)
around an inner application that answers `200` with the value of `X-En-Caller` as its body, or
`none` when absent. Configure two keys, `writer` (`ReadWrite`) and `reader` (`ReadOnly`), with
secrets of at least sixteen bytes. Cover, as pairs where the bearer form and the api-key form of
the same request must produce the same status, headers and body:

- a read (`GET /v1/schema`) with the writer key: `200`, body `writer`, including when the client
  also sends a forged `X-En-Caller`;
- a read with the reader key: `200`, body `reader`;
- a write (`POST /v1/relationships`) with the reader key: `403` with code `permission_denied`;
- an unknown secret: `401`, header `WWW-Authenticate: Bearer`, body containing
  `unauthenticated`, byte-identical across the bearer form, the api-key form and no credential;
- an empty `X-En-Api-Key` value: `401`.

And the combination rules, which have no bearer-only twin:

- both headers naming the writer key: `200`, body `writer`;
- a valid bearer writer with an api-key reader (and the reverse): `401`;
- a valid api-key writer with `Authorization: Basic d3JpdGVy`: `401`;
- two `X-En-Api-Key` headers with the same valid secret: `200`; with two different valid
  secrets: `401`;
- `GET /health/live` with no credential: passes through to the inner application (`200`,
  body `none`).

Acceptance: `cabal test en-server-tests` prints `Test suite en-server-tests: PASS`;
`cabal build en-server` compiles with no warnings; the existing `cabal test en-servant-tests`
still passes (nothing in it exercises the constant yet).

### Milestone 2: the contract declares the second scheme

Scope: `withSecurityScheme` in `en-servant/src/En/Servant/OpenApi.hs`, the OpenAPI assertions in
`en-servant/test/Main.hs`, and the regenerated `docs/api/openapi.json`. At the end a client can
discover `apiKeyAuth` and every authenticated operation lists both schemes as alternatives.

Change `withSecurityScheme` so the definitions hold both schemes and the per-operation
requirement list gains both entries, bearer first:

```haskell
    authenticated =
      document
        & components
        . securitySchemes
        .~ SecurityDefinitions
          ( InsOrdHashMap.fromList
              [ ("bearerAuth", bearer),
                ("apiKeyAuth", apiKey)
              ]
          )
        & allOperations
        . security
        %~ ([bearerRequirement, apiKeyRequirement] <>)
    bearer = SecurityScheme (SecuritySchemeHttp (HttpSchemeBearer Nothing)) Nothing
    apiKey =
      SecurityScheme
        (SecuritySchemeApiKey (ApiKeyParams (decodeUtf8 (CI.original apiKeyHeaderName)) ApiKeyHeader))
        (Just "The same API key as bearerAuth, for callers behind a proxy that consumes the Authorization header (for example the Kubernetes API server's service proxy). Present at most one secret: a request carrying both headers must name the same key.")
    bearerRequirement = SecurityRequirement (InsOrdHashMap.singleton "bearerAuth" [])
    apiKeyRequirement = SecurityRequirement (InsOrdHashMap.singleton "apiKeyAuth" [])
```

`SecuritySchemeApiKey`, `ApiKeyParams` (name first, location second) and `ApiKeyHeader` are
exported by `Data.OpenApi` in the `openapi-hs` library En already uses (verified in its
`Data.OpenApi.Internal`). `CI.original` comes from `Data.CaseInsensitive`: add `case-insensitive` to the
library's `build-depends` in `en-servant/en-servant.cabal` (it is already in the build plan
through `http-types`, but a module can only be imported from a direct dependency) and import
`decodeUtf8` from `Data.Text.Encoding`. The `clearProbeSecurity` fold already empties the whole `security` list
on each probe path, so the probes lose both requirements without further change. Update the
function's Haddock, which currently says "Declare the bearer authentication enforced by
en-server".

In `en-servant/test/Main.hs`, change the three security assertions: the scheme set becomes
`["apiKeyAuth", "bearerAuth"]` (sort the keys, since the key map is unordered), `expectedSecurity`
becomes the two-element list `[{"bearerAuth": []}, {"apiKeyAuth": []}]` in that order, and add
assertions that `components.securitySchemes.apiKeyAuth` has `type` `apiKey`, `in` `header` and
`name` `X-En-Api-Key`. The probe assertion (`security` is `null`) is unchanged and must still
pass.

Regenerate the document with `cabal run en-openapi`, then read `git diff docs/api/openapi.json`
in full. The only changes must be the new `apiKeyAuth` object under `components.securitySchemes`
(keys sorted: `description`, `in`, `name`, `type`) and a second element in each non-probe
operation's `security` array; the probe operations must not gain one. Commit the regenerated file
with the code.

Acceptance: `cabal test en-servant-tests` passes; `just openapi` exits `0` (no drift);
the Python one-liner in Validation prints both schemes and `sec=2` for every path except the two
probes.

### Milestone 3: the black-box suites prove it over a socket

Scope: `en-servant/test/hurl/openapi.hurl`, `en-servant/test/hurl/schema.hurl`,
`en-servant/test/hurl/perimeter/perimeter.hurl` and `perimeter/README.md`. At the end the CI
workflow exercises the new header against the packaged server, and the opt-in perimeter suite
pins every refusal rule.

In `openapi.hurl`, extend the first request's assertions with the discovery check the consumer
will perform:

```text
jsonpath "$.components.securitySchemes.apiKeyAuth.type" == "apiKey"
jsonpath "$.components.securitySchemes.apiKeyAuth.in" == "header"
jsonpath "$.components.securitySchemes.apiKeyAuth.name" == "X-En-Api-Key"
jsonpath "$.components.securitySchemes.bearerAuth.scheme" == "bearer"
```

In `schema.hurl`, add one request that authenticates with the new header using the same secret
the runner already injects, so the default suite (and therefore CI) proves the header works
against the real server:

```text
# The same key is accepted in X-En-Api-Key, the carrier for callers behind a proxy
# that consumes Authorization.
GET {{base_url}}/v1/schema
X-En-Api-Key: {{api_key}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.hash" startsWith "fnv1a64:"
```

In `perimeter/perimeter.hurl`, add cases mirroring the existing bearer ones and the combination
rules: an unknown secret in `X-En-Api-Key` answers `401` with `WWW-Authenticate: Bearer` and
code `unauthenticated`; the read-write secret in `X-En-Api-Key` reads `/v1/schema` with `200`;
the read-only secret in `X-En-Api-Key` on `POST /v1/relationships` answers `403`
`permission_denied`; a bearer `{{api_key}}` together with `X-En-Api-Key: {{read_only_api_key}}`
answers `401`; and both headers carrying `{{api_key}}` answers `200`. Keep every secret flowing
through `--secret`; never write one into `vars.env`. Run `hurlfmt --in-place` on each edited file
because `run.sh` enforces `hurlfmt --check`. Update `perimeter/README.md`'s summary sentence to
list the new header's cases.

Acceptance: `just start-and-test` (or `just process-up` followed by `just hurl`) is green, which
now includes the api-key-authenticated schema read and the scheme assertions; a perimeter run
using the README's commands reports every request succeeded.

### Milestone 4: documentation, catalog, ADR, and closing the request

Scope: `docs/user/service-and-operations.md`, `docs/capabilities/standalone-authorization-server.md`
plus `docs/capabilities/log.md`, a new `docs/adr/0009-*.md`, and the IR document plus
`docs/improvement-requests/log.md`. At the end an operator reading the server guide knows when
and how to use the header, the catalog is truthful, the decision is durable, and IR-1 is closed
with evidence.

In the "Authentication, rate limiting, and TLS" section, directly after the bearer `curl`
example, add a short subsection (a level-3 heading such as "Behind a proxy that consumes
Authorization"). Say that the same secret may be sent as `X-En-Api-Key`, that it exists for
callers whose proxy authenticates them with `Authorization` and removes it before forwarding,
that the Kubernetes API server's service proxy is the known case, and that bearer remains the
default. Show a direct example that runs against any server:

```shell
curl -sS -X POST https://en.internal:8080/v1/check \
  -H 'X-En-Api-Key: a-long-random-read-secret' \
  -H 'content-type: application/json' \
  -d '{ ... }'
```

and the proxy form, using `kubectl proxy` so it needs no certificate flags:

```shell
kubectl proxy --port 8001 &
curl -sS -X POST \
  http://127.0.0.1:8001/api/v1/namespaces/<namespace>/services/en:80/proxy/v1/check \
  -H 'X-En-Api-Key: a-long-random-read-secret' \
  -H 'content-type: application/json' \
  -d '{ ... }'
```

State the rules: a request may carry either header or both naming the same key, anything else is
`401`; a secret in `X-En-Api-Key` is exactly as sensitive as a bearer token and must never cross
a plaintext network; the proxy path adds the API server's own authorization (RBAC on the
`services/proxy` subresource) in front of En's key, which is why it is preferable to exposing En
on a wider network. Then adjust the surrounding prose: the `401` row's cause becomes "No
credential in `Authorization` or `X-En-Api-Key`, a non-bearer `Authorization` scheme, an unknown
secret, or two headers naming different keys"; "Transport security" opens with "API keys,
whichever header carries them, are only as secret as the transport"; and the "Machine-readable
description" subsection says the endpoint requires an API key like any other and that
`components.securitySchemes` lists both `bearerAuth` and `apiKeyAuth`.

In `docs/capabilities/standalone-authorization-server.md`, change the Middleware evidence line to
"Constant-time API-key authentication from `Authorization: Bearer` or `X-En-Api-Key`, ..." and
the "Authentication and rate limiting" bullet to match; set `generated.at` to the edit time and
`generated.by` to your own identity in the bundle's existing form; append a log entry with
`okf log add docs/capabilities --kind Update -m "..."`. The capabilities bundle already fails
`--strict` validation for a pre-existing reason (every concept lacks the recommended `reviews`
field); run the non-strict profile validation in Concrete Steps and confirm you added no new
diagnostic.

Write `docs/adr/0009-en-accepts-its-api-key-in-x-en-api-key-beside-bearer.md` in the format of
ADR 4: status accepted, date, `related` listing this plan, the IR, and
`mori://shinzui/nagare/plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward`.
Its Context is the proxy that deletes `Authorization`; its Decision is the two carriers, the
agreement rule, the unchanged `Bearer` challenge, the constant that owns the name, and that the
key is never accepted in a query string or cookie; its Consequences are that the OpenAPI
document advertises both schemes, that any future credential carrier must go through
`authenticate` and this ADR, and that log and trace surfaces must keep excluding both headers.

Finally close IR-1: set `status: completed`, add `completedAt` (UTC, RFC 3339) and a
`resolution` naming the commits and the test commands that proved AC-1 to AC-4, bump
`generated.at`, append a `log.md` entry with `okf log add`, and run the strict validation. Update
this plan's Progress, Outcomes & Retrospective, and (if anything surprised you) Surprises &
Discoveries.

Acceptance: with a server started as in Concrete Steps, the documented direct `curl` with
`X-En-Api-Key` answers `200` and the same request with the header removed answers `401`; the IR
bundle passes strict validation; the capabilities bundle produces no diagnostic it did not
produce before; ADR 9 exists and this plan links to it from Context and Orientation.


## Concrete Steps

All commands run from the repository root inside the Nix development shell (`nix develop`),
which provides GHC 9.12.4, `cabal`, `hurl`, `hurlfmt`, `okf`, `process-compose` and `treefmt`.

Build and unit tests, after Milestone 1 and again after Milestone 2:

```bash
cabal build en-server
cabal test en-server-tests
cabal test en-servant-tests
```

Expected tail of each test run:

```text
Test suite en-server-tests: PASS
```

Regenerate and check the OpenAPI document (Milestone 2). The first command rewrites the file; the
second is the drift check that must pass once the regenerated file is staged or committed:

```bash
cabal run -v0 en-openapi
git diff --stat docs/api/openapi.json
just openapi
```

Inspect the regenerated document's security shape:

```bash
python3 -c '
import json
d = json.load(open("docs/api/openapi.json"))
print(sorted(d["components"]["securitySchemes"]))
print(d["components"]["securitySchemes"]["apiKeyAuth"])
for p, item in sorted(d["paths"].items()):
    for m, op in item.items():
        print(p, m, "sec=" + str(len(op.get("security") or [])))'
```

Expected: `['apiKeyAuth', 'bearerAuth']`; the scheme object with `in: header`,
`name: X-En-Api-Key`, `type: apiKey`; `sec=2` on every line except `/health/live` and
`/health/ready`, which print `sec=0`.

Black-box suites (Milestone 3). The safe suite against the process-compose server:

```bash
just process-up
just start-and-test
just process-down
```

The perimeter suite needs a second server with two keys. In one shell:

```bash
just process-up
EN_PORT=18081 \
  EN_DATABASE_URL="$PG_CONNECTION_STRING" \
  EN_API_KEYS_READ_WRITE='writer:writer-secret-0123456789' \
  EN_API_KEYS_READ_ONLY='reader:reader-secret-0123456789' \
  EN_TELEMETRY_ENABLED=false \
  cabal run en-server
```

In another:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env \
  --variable base_url=http://127.0.0.1:18081 \
  --secret api_key='writer-secret-0123456789' \
  --secret read_only_api_key='reader-secret-0123456789' \
  --secret invalid_api_key='invalid-secret-0123456789' \
  perimeter/perimeter.hurl
```

Expected last line: `Succeeded files: 1/1 (100.0%)`, with the request count increased by the
cases you added.

The documented example (Milestone 4), against the same two-key server:

```bash
curl -si -H 'X-En-Api-Key: writer-secret-0123456789' http://127.0.0.1:18081/v1/schema | head -1
curl -si http://127.0.0.1:18081/v1/schema | head -1
```

Expected: `HTTP/1.1 200 OK` then `HTTP/1.1 401 Unauthorized`.

Bundle validation (Milestone 4):

```bash
okf validate docs/improvement-requests --strict \
  --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce
```

Expected for the first: `OK: 1 concepts (okf_version 0.2)`. For the second, no line naming
`standalone-authorization-server` beyond the pre-existing "missing profile-recommended field:
reviews".

Formatting runs as a pre-commit hook (`treefmt --fail-on-change`: fourmolu for Haskell,
cabal-gild for Cabal files, nixpkgs-fmt for Nix). Run `treefmt` before each commit so the hook
does not rewrite files under you; Hurl files are formatted separately with
`hurlfmt --in-place <file>`.

Commit at each milestone boundary with a Conventional Commits subject and both trailers, for
example:

```text
feat(server): accept the API key in X-En-Api-Key beside Authorization: Bearer

ExecPlan: docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md
Intention: intention_01m621z2x8e3nsfz0af3b2xh8m
```


## Validation and Acceptance

AC-1 is proved by `cabal test en-server-tests`: for each of the writer read, reader read, reader
write and unknown-secret requests, the response produced through `X-En-Api-Key` is equal to the
response produced through `Authorization: Bearer` (status, headers and body), the inner
application observes the caller name set from the key, and the `401` carries
`WWW-Authenticate: Bearer` with the unchanged problem body. The Hurl safe suite repeats the
successful read over a real socket in CI, and the perimeter suite repeats the refusals.

AC-2 is proved by the same suites: two different valid keys across the two headers answer `401`
in the unit test and in the perimeter suite; the same key in both answers `200` in both. The unit
test additionally pins the stricter edges the request leaves implicit (malformed `Authorization`
with a valid api key, duplicate api-key headers).

AC-3 is proved by `cabal test en-servant-tests` (both schemes present, two-alternative
`security` on every non-probe operation, probes explicitly unauthenticated, the `apiKeyAuth`
scheme's three fields), by `just openapi` reporting no drift between the generator and
`docs/api/openapi.json`, and by `openapi.hurl` asserting the live document from the packaged
server.

AC-4 is proved by reading the "Authentication, rate limiting, and TLS" section, which names the
header, its purpose, the Kubernetes API server's service proxy and the bearer default, and by
running its direct example against a server started with the documented variables (the two
`curl` lines in Concrete Steps). The proxy-form example cannot run without a cluster and is
documentation, not acceptance; the consumer plan verifies it end to end.

The representative producer/consumer check for the uncertain interface (the published scheme
shape nagarectl will look for) is the `openapi.hurl` assertion on
`components.securitySchemes.apiKeyAuth.name`; it runs in the first `just hurl` after Milestone 3
and should be exercised before any Nagare work starts.

Proposed, not required: a case in the unit test that `authMiddleware AuthDisabled` ignores both
headers (it is the identity middleware, so this is trivially true today).


## Idempotence and Recovery

Every step is repeatable. `cabal run en-openapi` is deterministic (sorted keys, trailing newline),
so running it twice yields no further diff; if it ever produces an unexpected change, `git
checkout -- docs/api/openapi.json` restores the committed document and the generator change
should be revisited. The unit and en-servant tests have no external state. The Hurl safe suite
and the perimeter suite do not mutate the database: the only write-shaped request is refused by
authorization before a handler runs. The server started on port 18081 is disposable; stop it
with Ctrl-C and `just process-down` stops the supervised services.

If a milestone is interrupted, the working tree is the source of truth: re-run the milestone's
acceptance commands, finish what fails, and record the result in Progress. The IR document edits
are plain frontmatter changes; if `okf validate` rejects one, the message names the field, fix it
and re-run. `okf log add` appends, so run it once per content change rather than per attempt.


## Interfaces and Dependencies

New or changed interfaces:

- `En.Servant.OpenApi.apiKeyHeaderName :: Network.HTTP.Types.HeaderName`, value
  `"X-En-Api-Key"`, exported from `en-servant`. Owner of the header name; imported by
  `en-server/app/Middleware.hs`.
- `Middleware.authenticate :: [ApiKey] -> Request -> Maybe ApiKey` (internal to `en-server`)
  now implements the agreement rule over both headers. Its callers and the exported
  `authMiddleware` signature are unchanged.
- The OpenAPI contract at `GET /v1/openapi.json` and in `docs/api/openapi.json`:
  `components.securitySchemes.apiKeyAuth = {type: apiKey, in: header, name: X-En-Api-Key,
  description: ...}` and `security: [{bearerAuth: []}, {apiKeyAuth: []}]` on every non-probe
  operation. This is the shape the consumer detects; do not rename the scheme.
- A new Cabal target `en-server:test:en-server-tests`.

Libraries whose choice matters, all already in the build plan: `openapi-hs` (constructors
`SecuritySchemeApiKey`, `ApiKeyParams`, `ApiKeyLocation (ApiKeyHeader)` from `Data.OpenApi`);
`ram` (`Data.ByteArray.constEq`, the constant-time comparison used for both the key check and
the agreement check); `wai-extra` (`Network.Wai.Test` for the unit suite); `http-types`
(`HeaderName`, `hAuthorization`); `servant-health` (`Servant.Health.Paths.healthRawPaths`, the
single source of the exempt probe paths per ADR 4); `case-insensitive`
(`Data.CaseInsensitive.original`, to render the header name into the scheme), which Milestone 2
adds to `en-servant`'s direct dependencies.

External facts this plan relies on: the Kubernetes API server removes `Authorization` after
authenticating a proxied request (cited above) and forwards other request headers to the
Service; the former is established by the IR's probe, the latter is verified by the consumer
plan on a real cluster. En's acceptance does not depend on either.
