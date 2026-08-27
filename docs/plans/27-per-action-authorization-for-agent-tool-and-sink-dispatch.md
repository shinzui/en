---
id: 27
slug: per-action-authorization-for-agent-tool-and-sink-dispatch
title: "Per-action authorization for agent tool and sink dispatch"
kind: exec-plan
created_at: 2026-06-27T16:24:02Z
intention: "intention_01kw4y7s4jet8ad44mf6mqa8cr"
---

# Per-action authorization for agent tool and sink dispatch

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kikan already has a working relationship-based authorization model in `shinzui/kikan-en`.
Its schema and conformance executable can grant an agent one exact sink target or workspace and
deny a sibling target of the same kind. What is still missing is the production contract between
that model and `shinzui/shikigami`: Shikigami still enforces only its coarse, database-backed
sink-kind grant, and its newer capability-overlay tool runtime has no per-acquisition or
per-invocation Kikan check.

After this plan is implemented, an agent declaration remains only a request for a capability. A
Shomei-authenticated Shikigami process asks Kikan-En to authorize one verified Meibo agent
principal, one closed action, and one exact typed target. An allowed answer carries a short-lived,
signed En Biscuit decision proof. The dispatch boundary verifies that proof against the same
principal, action, target, audience, schema hash, and expiry before it connects to a capability
provider, invokes a tool, or emits a sink. A missing identity, unknown action, malformed target,
denial, conditional result, expired or tampered proof, or authorization-service outage fails
closed.

The observable proof is deliberately sharper than “the endpoint returned 200.” With one grant,
the conformance suite and live service show all of the following:

- an agent may acquire one immutable capability-overlay provider revision but not a sibling
  revision;
- the agent may invoke one named tool from that provider while another advertised tool remains
  denied;
- the same tool under another capability or another agent principal remains denied;
- a granted sink target proceeds while an ungranted target of the same sink kind is skipped;
- an allowed decision returns a bounded Biscuit that verifies for the exact dispatch and fails
  after expiry or when its subject, operation, resource, audience, schema hash, or bytes change;
- deleting the relationship prevents new proofs immediately, while an already-issued proof can
  live no longer than the documented 60-second ceiling.

This plan is coordinated from `shinzui/en` because it began as an En integration plan, but Kikan
policy is not added to En. The product schema, public action contract, client, service host, and
fixtures belong to `mori://shinzui/kikan-en`; the consuming runtime edits belong to
`mori://shinzui/shikigami`. En remains the generic engine and proof implementation.


## Progress

- [x] 2026-06-29 — Historical foundation: `mori://shinzui/kikan-en` was created with the Kikan
  schema, grant fixtures, embedded conformance executable, PostgreSQL-backed server, and written
  Shikigami hand-off contract.
- [x] 2026-08-26 — Refresh discovery: re-read the current En, Kikan-En, Shikigami, and Shomei
  sources through Mori; verified the released/tagged dependency state; reviewed relevant local
  ADRs; and replaced the June implementation assumptions in this plan.
- [x] 2026-08-26 — M1: verified Kikan-En’s independently-landed rebase on En commit
  `51edaab17473f7b9310f8802ccffd23bac5e4a9e`. `cabal build all --enable-tests`, the unit
  suite, the 16-case conformance executable, `en-migrate up`/`verify`, the live `/v1` Hurl
  suite, and the stateful relationship-adoption flow all pass.
- [x] 2026-08-26 — M2: added the public `kikan-en-contract` package, closed action JSON,
  constructor-enforced canonical targets, capability provider/tool schema relations, Meibo-style
  fixtures, and exact revision/tool/capability/agent denials. Both package test suites pass and
  the conformance executable now reports 24 passing cases.
- [x] 2026-08-26 — M3: added the shared `/v1/agent-actions/authorize` route, bounded Shomei JWKS
  verifier, closed machine scope, En check-and-mint adapter, 30-second/60-second issuer policy,
  generated OpenAPI operation, bounded audit events, and the public proof-verifying
  `kikan-en-client`. Missing/invalid authentication, insufficient scope, and unavailable keys
  fail closed before En.
- [x] 2026-08-27 — M4: verified real Shomei-signed JWTs through an HTTP JWKS stub for the
  401/403/503/200 matrix; verified real En Biscuits for exact and mismatched coordinates,
  expiry, tampering, and revocation; wrote and deleted a mutable exact-tool relationship to prove
  immediate next-mint denial and the old proof’s bounded residual lifetime; and generated/golden-
  checked the action OpenAPI including typed 400/401/403/500/503 problem responses. All three test
  suites and the 24-case conformance executable pass.
- [ ] M5 — Integrate Shikigami’s capability-provider acquisition, exact tool invocation, and sink
  enqueue/publish boundaries while retaining the shipped C11 grant gate.
- [ ] M6 — Run the cross-repository end-to-end matrix, update operator/consumer documentation,
  refresh Mori metadata, and distill durable decisions into the owning repositories’ ADR corpora.


## Surprises & Discoveries

- Discovery: the work originally described as future Kikan-En scaffolding is already present.
  `mori registry show shinzui/kikan-en --full` reports the `kikan-en`,
  `kikan-en-conformance`, and `kikan-en-server` packages, and commits `f29744b`, `c182121`, and
  `b182b7d` implemented the schema, conformance harness, and server on 2026-06-29.
  Date: 2026-08-26.

- Discovery: Kikan-En’s server wrapper no longer matches the current En host seam. Its
  `src/Kikan/En/Server.hs` constructs the old `En.Servant.Seam.Env` with `graph` and a
  one-argument `runPorts`; current En requires a request-time `ActiveSchema`, a two-argument
  `runPorts`, `CheckOutcome`, lookup-subjects/watch operations, evaluation/deadline settings, and
  optional grant minting. The old unversioned `/check` transcript is also stale; current En serves
  `/v1/check` and `/v1/grants`, returns `checkedAt`, and uses stable hand-written wire JSON and RFC
  9457 problem documents.
  Date: 2026-08-26.

- Discovery: En now ships the proof primitive the newer requirement needs. `en-biscuit` signs a
  successful object decision into a short-lived Biscuit carrying subject, operation, resource,
  consistency token, schema hash, audience, expiry, and optional request id. `En.Biscuit.Verify`
  rejects wrong or tampered values locally, and `POST /v1/grants` performs check-then-mint without
  trusting a caller-asserted decision.
  Date: 2026-08-26.

- Discovery: Shikigami’s “coarse static grant” premise is obsolete but the coarse gate itself is
  still required. `mori://shinzui/shikigami` plan 21 shipped `GrantSource`,
  `shikigami.sink_grants`, runtime grant/revoke commands, verified Meibo principal keys, and two
  checks per sink (enqueue and publish). This C11 gate is defense in depth and must be composed
  with C13, not replaced.
  Date: 2026-08-26.

- Discovery: raw `mcpServers` declarations and the proposed `mcp__<server>__<tool>` identity were
  superseded. Shikigami now declares `capabilityOverlays`; an operator catalog resolves each
  request to an immutable `CapabilityDescriptor {capability, revision, tools}`, the provider
  registry selects the exact `(CapabilityId, CapabilityRevision)`, and the model-facing tool name
  is `overlay__<capability-with-dashes>__<logical-tool>`. Authorization must bind to that stable
  provider/tool identity, not to a mutable endpoint or an agent-authored server record.
  Date: 2026-08-26.

- Discovery: En has no upstream tags and `https://hackage.haskell.org/package/en-core/en-core.cabal`
  returns 404, so there is no released En version to select. Kikan-En currently co-develops against
  sibling En packages in `cabal.project`; implementation must record the exact En commit used.
  Shomei’s source tags `shomei-core-0.1.0.0`, `shomei-jwt-0.1.0.0`, and
  `shomei-servant-0.1.0.0` all resolve to commit
  `65551cb120336b53695c0dd30ebe0e473d6efcb2`, although the corresponding Hackage package URL is
  not yet published. Kikan-En must therefore use that exact upstream tag/commit rather than invent
  a version bound.
  Date: 2026-08-26.

- Discovery: the coordinating En development shell exports its own `EN_DATABASE_URL`, and port
  8080 was already occupied. Those ambient values can redirect Kikan-En’s otherwise-correct local
  lifecycle to En’s PostgreSQL socket or another HTTP server. The isolated validation command was
  `env -u EN_DATABASE_URL KIKAN_EN_CI_PORT=18080 nix develop -c just ci`; it completed with one
  applied migration, zero pending migrations, seven safe Hurl requests, and five stateful
  relationship requests passing.
  Date: 2026-08-26.

- Discovery: Kikan-En gained a plain-filesystem ADR corpus after this plan’s refresh. Its
  `docs/adr/README.md` requires four-digit filenames and Status/Context/Decision/Consequences
  headings without frontmatter, so M2 recorded the new durable contract boundary as ADR 0004
  rather than introducing an OKF profile incidentally.
  Date: 2026-08-26.

- Discovery: En's grant handler supports an explicit consistency mode, so the action adapter can
  request `FullyConsistent` for every mint without adding another store interface. This makes a
  relationship deletion visible to the next proof request rather than accepting the ordinary
  optimized-read staleness window.
  Date: 2026-08-26.

- Discovery: Servant's ordinary `Post` combinator keeps the shared contract and derived client
  small, but its generated OpenAPI response list does not describe every typed problem thrown by
  the handler. Runtime 401/403/400/500/503 bodies are stable `ActionProblem` JSON and the public
  client decodes them; M4 must either move the route to a typed multi-response combinator or add
  equivalent explicit OpenAPI response documentation before acceptance.
  Date: 2026-08-26.

- Discovery: the first live proof lifecycle exposed two unit-fixture blind spots. En schema hashes
  use an algorithm prefix such as `sha256:…`, which the initial contract validator rejected, and
  Biscuit Datalog dates round to whole seconds while En’s pre-existing `MintedGrant` metadata
  retained the issuer clock’s fractional seconds. The latter made a genuine HTTP response fail
  the client’s signed-metadata comparison. Kikan-En now accepts canonical prefixed hashes and
  normalizes its public expiry to Biscuit precision; En commits
  `mori://shinzui/en/commits/da3e0b7df886625b23846a0f20779112b0ba75dd` and
  `mori://shinzui/en/commits/07e0d2650cbdaa893b854c57c9fbc940a5b679f0` make the generic
  mint result report that same signed precision.
  Date: 2026-08-27.


## Decision Log

- Decision: Keep Kikan-specific authorization in `mori://shinzui/kikan-en`; make no product-schema
  additions to En.
  Rationale: En is schema-parametric infrastructure. Capability, sink, workspace, and intention
  names are Kikan product policy.
  Date: 2026-06-29; reaffirmed 2026-08-26.

- Decision: Continue to model the agent as the En subject and the touched thing as the En object.
  Do not duplicate the agent principal inside every object id merely to distinguish two agents.
  Rationale: a check is already `(subject, permission, object)`. The same tool under another agent
  is denied because the subject differs; copying the subject into the object id creates two sources
  of identity that can disagree.
  Date: 2026-08-26.

- Decision: Preserve Shikigami’s C11 lifecycle and coarse sink-kind checks and add Kikan-En C13
  after them. Re-check both gates at enqueue and publish.
  Rationale: C11 answers whether the verified agent may use the action class at all; C13 answers
  whether it may touch this exact target. The existing second check closes the revoke-after-enqueue
  race and should not be weakened.
  Date: 2026-08-26.

- Decision: Use En Biscuit object grants as the only allow proof. The Kikan endpoint performs the
  check and mint atomically at one `checkedAt` token; neither the client nor Shikigami may submit a
  precomputed “allowed” decision.
  Rationale: the shipped generic primitive already signs every required decision coordinate and
  has a fail-closed verifier. A second Kikan proof format would duplicate cryptography and drift.
  Date: 2026-08-26.

- Decision: Define capability resources from the operator-owned overlay snapshot:
  `capability_provider:<capability>@<revision>` and
  `capability_tool:<capability>@<revision>/<logical-tool-name>`. Give provider objects
  `can_connect` and `can_discover`; give tool objects `can_invoke`. A provider grant never implies
  a tool grant.
  Rationale: the capability id and immutable revision are the current stable provider key. The
  logical tool name is what the descriptor and lease both validate. Mutable URLs, credentials,
  model-facing renamed tools, and agent-authored declarations are not authorization identities.
  Date: 2026-08-26.

- Decision: Put the stable action/target/proof vocabulary in a dependency-light
  `kikan-en-contract` package and the HTTP wrapper in `kikan-en-client`; do not make Shikigami
  depend on Kikan-En’s PostgreSQL server library or internal schema module.
  Rationale: the consumer request explicitly requires a versioned public contract. Separate
  packages make the dependency boundary enforceable by Cabal and Mori.
  Date: 2026-08-26.

- Decision: Authenticate the Kikan action endpoint with a Shomei machine token carrying the closed
  scope `kikan-en:authorize-agent-action`. The token authenticates the Shikigami service account;
  the request names a validated Meibo `agent_…` principal. Kikan logs both identities. Only service
  accounts configured with that Shomei scope may assert an agent principal.
  Rationale: Shikigami hosts many agents, so its machine-token subject cannot equal every agent.
  Restricting the assertion right to one coarse Shomei scope preserves the C11/C13 split while En
  still decides the asserted agent’s exact relationship.
  Date: 2026-08-26.

- Decision: Fix the proof audience to `shikigami`, default the TTL to 30 seconds, and cap it at 60
  seconds in the Kikan host. The public action request does not choose its own audience or TTL.
  Rationale: these are issuer policy, not caller-controlled capabilities. A short ceiling bounds
  how long a proof can survive relationship revocation without requiring a new revocation service.
  Date: 2026-08-26.

- Decision: Authorize provider connection immediately before acquisition and authorize every
  logical tool immediately before its `SomeTool.run` callback. Do not treat catalog resolution,
  descriptor presence, provider acquisition, or discovery as permission to invoke every tool.
  Rationale: Shikigami’s current pure catalog resolver cannot make a fresh network decision, and a
  server/provider can expose tools with materially different authority. Wrapping the two actual IO
  boundaries is both current and non-bypassable.
  Date: 2026-08-26.

- Decision: Keep the JSON action sum split by concrete sink operation (`dispatch_kawa`,
  `dispatch_kizashi`, `attach_danwa`, and `dispatch_channel`) and require each tag’s matching
  target kind. Principal construction mirrors Shikigami’s current edge hygiene—nonempty
  `agent_` text plus bounded, tuple-safe characters—while Meibo remains responsible for existence
  and lifecycle verification.
  Rationale: the action-to-permission mapping in this plan is closed and sink-specific. Typed
  constructors make mismatches unrepresentable in Haskell, explicit target-kind checks make them
  fail JSON decoding, and duplicating Meibo’s directory lookup or minting rules in a transport
  package would create a second identity authority.
  Date: 2026-08-26.

- Decision: Use a fully consistent En read for every action proof mint, even though Kikan's legacy
  check endpoints retain their caller-selected consistency behavior.
  Rationale: the public contract promises that deleting an exact relationship prevents the next
  mint immediately. The proof's short expiry bounds only already-issued allows; it must not also
  absorb optimized-read lag on new decisions.
  Date: 2026-08-26.

- Decision: Treat the action signing key and Shomei issuer, audience, and JWKS URL as one grouped
  host configuration. When the entire group is absent, retain the existing loopback En routes but
  make action authorization unavailable; reject partial groups at startup.
  Rationale: this preserves local administration and migration diagnostics without silently
  exposing an unauthenticated action route or minting proofs with only half of the trust boundary
  configured.
  Date: 2026-08-26.


## Outcomes & Retrospective

The 2026-06-29 foundation succeeded: Kikan policy moved out of En, the schema compiles, the
embedded conformance matrix proves per-object behavior, and a PostgreSQL-backed Kikan server was
built. The original plan stopped at a document-only Shikigami hand-off, so no runtime dispatch
uses it yet.

This 2026-08-26 refresh converts that stale hand-off into executable remaining work. It reuses
En’s since-shipped proof layer, preserves Shikigami’s since-shipped identity and grant gates, and
targets the since-shipped capability-overlay provider boundary. No production implementation or
ADR was changed during the refresh.


## Context and Orientation

En is a relationship-based access-control engine. Its stored fact is a relationship tuple of the
form `(object, relation, subject)`. A schema defines writable relations and computed permissions;
`check` asks whether one subject has one permission on one exact object. `CheckDecision` is
three-valued: `Allowed`, `Denied`, or `Conditional` when a caveat path exists but required context
is missing. Every boundary in this plan treats only `Allowed` as permission.

The current En checkout is `mori://shinzui/en`. The interfaces used here are:

- `en-core/src/En/Check.hs`, `En.Decision`, `En.Tuple`, `En.Schema`, and
  `En.Store.InMemory` for the engine, typed targets, decisions, and test store;
- `en-servant/src/En/Check/Api.hs` for `/v1/check`, `/v1/grants`, `checkedAt`, and the current wire
  types;
- `en-servant/src/En/Servant/Seam.hs` for `ActiveSchema`, the current host `Env`, and `MintEnv`;
- `en-client/src/En/Client.hs` for the Servant-derived client;
- `en-biscuit/src/En/Biscuit/Grant.hs` and `En.Biscuit.Verify` for the stable proof facts and local
  verifier.

Relevant local durable decisions are [ADR 1](../adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md),
which requires the `en-migrate` pg-migrate plan instead of Kikan-En’s old probe scripts;
[ADR 3](../adr/0003-the-in-memory-store-is-for-tests-and-demos-only.md), which permits the current public
in-memory interpreter only for conformance and tests; [ADR 5](../adr/0005-telemetry-configuration-and-provider-lifetimes-belong-to-the-standalone-host.md), which makes
the Kikan host responsible for its own telemetry providers and middleware; and
[ADR 7](../adr/0007-generic-lens-labels-are-en-s-record-access-idiom.md), which governs record access in
new En-facing Haskell code. Kikan-En has no `docs/adr/` corpus today, so M6 must inspect its then
current ADR convention before distilling new product decisions.

Kikan-En is `mori://shinzui/kikan-en`. Its current important files are
`src/Kikan/En/Schema.hs`, `src/Kikan/En/Conformance/Agent.hs`,
`src/Kikan/En/Testing/InMemory.hs`, `src/Kikan/En/Server.hs`,
`app/kikan-en-conformance/Main.hs`, `app/kikan-en-server/Main.hs`, `kikan-en.cabal`,
`cabal.project`, and `Justfile`. The repository-local plans that built those files have intended
handles under `mori://shinzui/kikan-en/plans/`; current Mori releases do not yet resolve that
artifact kind, so use the project URI plus paths `docs/plans/2-kikan-agent-authorization-schema.md`,
`docs/plans/4-kikan-authorization-service-and-live-http-check-contract.md`, and
`docs/plans/5-shikigami-per-action-authorization-integration-contract.md` until plan handles are
indexed. The active requirement is
`mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3`; the broader dispatch blocker is
`mori://shinzui/kikan-en/okf/shikigami-blockers/concepts/IR-1`.

Shikigami is `mori://shinzui/shikigami`. Its present boundaries are materially different from the
June plan:

- `shikigami-core/src/Shikigami/Agent/Principal.hs` defines verified Meibo principals as
  `VerifiedIdentity AgentPrincipal`, whose canonical text starts with `agent_`;
- `shikigami-core/src/Shikigami/Sink/GrantStore.hs` owns the C11 `GrantSource` and
  `checkGrant :: GrantSource -> AgentIdentity -> SinkKind -> IO (Either Denied ())`;
- `shikigami-core/src/Shikigami/Sink/Intent.hs` checks C11 before enqueue, while the sink publisher
  checks again before external delivery;
- `shikigami-core/src/Shikigami/Capability/Overlay.hs` defines immutable capability descriptors;
- `Shikigami.Capability.Provider` selects exact provider revisions and brackets provider leases;
- `Shikigami.Capability.Tools` produces `overlay__…` model-facing names while retaining logical
  tool names inside each descriptor and lease.

Shomei is `mori://shinzui/shomei`. Its tagged 0.1.0.0 source already supports OAuth2
`client_credentials`, allowed-scope ceilings, signed JWTs, JWKS publication, and local
`verifyToken`. Kikan-En should follow the downstream verifier and cache pattern in
`mori://shinzui/shomei` at `examples/microservice-auth-stack/src/Downstream/Service.hs`. The
machine token’s `sub` authenticates Shikigami; the action request’s validated `agent_…` value is
the En subject. The two values are intentionally logged separately.


## Plan of Work

### Milestone 1 — Rebase the existing Kikan host without changing policy

First make the existing repository build against the exact current En source. Add `en-biscuit` to
Kikan-En’s sibling package set. Replace the stale `En.Servant.Seam.Env` construction with one
request-time `ActiveSchema` whose graph is `kikanGraph`, whose source/origin clearly identify the
built-in Kikan schema, and whose `runPorts` threads that snapshot’s schema hash into the current
PostgreSQL interpreters. Supply current check, lookup, lookup-subjects, watch, evaluation budget,
deadline, batch, and mint fields. Keep production authorization data in PostgreSQL; use
`En.Store.InMemory` only in tests.

Replace `Justfile`’s old `to_regclass`/raw-SQL migration probes with the current pg-migrate
component: build or invoke `en-migrate`, run `up`, and expose `verify`. Do not edit an applied En
migration or copy its SQL into Kikan-En. This follows local ADR 1.

At the end, the old Kikan conformance assertions still pass, the server starts on `/v1`, and a
plain check response includes both the decision and `checkedAt`. Record the exact En commit in
Kikan-En’s dependency documentation and Mori metadata; there is no release bound to choose yet.


### Milestone 2 — Add closed actions and immutable capability targets

Create `kikan-en-contract` as a small Cabal package with no server or PostgreSQL dependency. In
`Kikan.En.Action`, define smart constructors and JSON codecs for `AgentPrincipal`, `RequestId`,
`CapabilityTarget`, `CapabilityToolTarget`, `SinkTarget`, and the closed `AgentAction` sum. Unknown
JSON action tags fail decoding; object ids are produced only by constructors.

The action mapping is total:

```text
ConnectCapability       -> can_connect  on capability_provider:<capability>@<revision>
DiscoverCapabilityTools -> can_discover on capability_provider:<capability>@<revision>
InvokeCapabilityTool    -> can_invoke   on capability_tool:<capability>@<revision>/<logical-name>
ReadWorkspace           -> can_read     on workspace:<workspace-id>
WriteWorkspace          -> can_write    on workspace:<workspace-id>
ExecuteWorkspace        -> can_bash     on workspace:<workspace-id>
DispatchKawa            -> can_dispatch on kawa_source:<source-id>
DispatchKizashi         -> can_dispatch on kizashi_recipient:<recipient-id>
ActOnIntention          -> can_act      on intention:<intention-id>
AttachDanwa             -> can_dispatch on danwa_thread:<thread-id>
DispatchChannel         -> can_dispatch on channel_egress:<provider>/<conversation-key>
```

Extend `Kikan.En.Schema` with `capability_provider` and `capability_tool`. A provider has explicit
`connector` and `discoverer` relations; a tool has an explicit `invoker` relation and may carry a
non-authorizing `provider` relationship for audit/expansion. `can_invoke` is computed only from
`invoker`; never arrow from provider connection. Keep the existing workspace, sink, and intention
vocabulary.

Update fixtures to use current Meibo-style agent ids. Add sibling-revision, sibling-tool,
sibling-capability, and sibling-agent denials. Add constructor tests for empty names, separators
that would make the encoding ambiguous, malformed principals, mismatched action/target pairs, and
unknown action JSON.


### Milestone 3 — Serve a narrow authenticated check-and-mint contract

Add `Kikan.En.Action.Api` and mount `POST /v1/agent-actions/authorize`. The request carries a
validated agent principal, one closed action/target value, caveat context only for actions that
need it, and a request id. It does not accept raw En subject types, raw permission strings, an
audience, a TTL, or a caller-asserted decision.

Add a host-owned Shomei JWT verifier with a refresh-ahead, single-flight JWKS cache and a bounded
last-known-good interval, following the Shomei downstream example. A verifiable token without the
`kikan-en:authorize-agent-action` scope receives 403. Missing/invalid tokens receive 401. When no
sufficiently fresh JWKS is available, answer 503 rather than mislabeling a valid token as bad.
Never log the bearer token.

The handler maps the validated request through `Kikan.En.Action`, constructs an En
`MintGrantRequestWire`, fixes `audience = "shikigami"`, uses the host’s 30-second default and
60-second maximum, and delegates to En’s check-then-mint handler. The allowed wire response carries
only the issued Biscuit, expiry, revocation ids, and `checkedAt`; it does not echo unsigned copies
of the subject, action, resource, or schema hash. Those coordinates are signed inside the Biscuit
and are recovered by verification. Return typed deny, invalid-request, and unavailable problem
responses; do not collapse a store outage into an ordinary deny.

Create `kikan-en-client` with `authorizeAgentAction` derived from the shared Kikan API type. It
depends on `kikan-en-contract` and the transport client packages, not on `Kikan.En.Server`,
`en-postgres`, or Kikan’s internal schema module. Expose a verifier wrapper that builds
`En.Biscuit.Verify.VerifyRequest` from the original `AuthorizeActionRequest`, the issued proof, an
issuer public-key set, accepted schema hashes, and the current clock. The high-level client returns
`AuthorizedAction` only after that verification succeeds; a 200 response with an invalid proof is
a fail-closed client error, not an allow.


### Milestone 4 — Prove the public contract and proof lifecycle

Use En’s public in-memory store for unit/conformance tests and PostgreSQL for live service tests.
The matrix must show exact provider revision, tool, capability, agent, sink, and workspace
allow/deny behavior. Mint a real Biscuit for one allowed tool. Verify it successfully, then prove
wrong subject, operation, resource, audience, schema hash, expiry, token bytes, and revocation id
all fail closed with distinct typed errors.

Write a provider/tool relationship, mint a proof, delete the relationship, and show a new mint is
denied. Then document that the old proof remains locally valid only until its expiry unless the
verifier consults a revocation list; assert its expiry is at most 60 seconds after minting. This is
the explicit revocation bound required by the improvement request.

Run a live Shomei fixture or signed-JWKS stub so the endpoint’s 401, 403, 503, and allowed paths are
tested through WAI/HTTP. Generate the Kikan OpenAPI document from the same API types and add a
golden/round-trip check so client and server cannot drift.


### Milestone 5 — Gate Shikigami at the actual IO boundaries

Add an `ActionAuthorizer` dependency to Shikigami’s composition root. Its production interpreter
uses `kikan-en-client` plus a Shomei `client_credentials` token for the closed scope. Tests use an
in-memory fake that returns real-shaped allowed/denied/unavailable results and, where proof
verification is under test, real signed Biscuits.

Keep `Capability.Catalog.resolveCapabilityOverlays` pure and retain its existing local admission
callback as an additional gate. Wrap each `CapabilityProvider.acquire` so it authorizes
`ConnectCapability` for the exact descriptor before any network connection or discovery. When a
provider performs separate discovery, authorize `DiscoverCapabilityTools` before that operation.
Wrap every leased `SomeTool` before registry composition so its `run` callback authorizes
`InvokeCapabilityTool` for the descriptor’s logical tool name and locally verifies the returned
proof immediately before invoking the underlying callback. The model-facing `overlay__…` name is
presentation only and is never used as the authorization resource id.

For sinks, retain lifecycle admission and `checkGrant`. After both succeed, derive the exact target
from the fully resolved `SinkIntent` and call the Kikan authorizer. Do this before enqueue and again
before publish, minting a fresh short-lived proof each time rather than storing a Biscuit in the
journal or outbox. On denial, preserve the current `DeniedOutcome`/no-delivery behavior. On Kikan
unavailability or proof-verification failure, produce a distinct fail-closed outcome that an
operator can distinguish from a policy denial without exposing credentials or token bytes.

Log only bounded audit coordinates: Shomei caller id, Meibo agent principal, action, canonical
resource, request id, decision, `checkedAt`, schema hash, and expiry. Do not log the Biscuit,
Shomei JWT, tool arguments/results, provider credentials, or sink payload.


### Milestone 6 — End-to-end validation and durable hand-off

Run Kikan-En with PostgreSQL migrations applied and a real or fixture Shomei issuer. Register one
fake capability provider revision with two logical tools in Shikigami. Grant connection and one
tool to one agent. Demonstrate that acquisition succeeds, the granted tool runs, the sibling tool
does not run, and another agent cannot reuse the proof. Revoke the tool relationship and show the
next invocation is denied. Repeat the exact-target contrast for one sink, including the enqueue to
publish revocation window.

Update Kikan-En’s user/operator docs, Shikigami’s capability/sink docs, dependency metadata, and
Mori registry descriptions. Before completion, inspect each owning repository’s current ADR
contract and distill stable identity, proof, TTL/revocation, and gate-composition decisions there.
Do not create a Kikan policy ADR in En merely because this coordinating plan lives here.


## Concrete Steps

Resolve the repositories through Mori rather than relying on remembered checkout paths:

```bash
mori registry show shinzui/en --full
mori registry show shinzui/kikan-en --full
mori registry show shinzui/shikigami --full
mori registry show shinzui/shomei --full
mori path mori://shinzui/kikan-en/repos/kikan-en
mori path mori://shinzui/shikigami/repos/shikigami
```

Before changing dependency bounds or pins, repeat the release check. As of 2026-08-26 the expected
result is no En tags, a 404 for the En Hackage package, and Shomei 0.1.0.0 tags at the recorded
commit:

```bash
git ls-remote --tags https://github.com/shinzui/en.git
curl -fsSL https://hackage.haskell.org/package/en-core/en-core.cabal
git ls-remote --tags https://github.com/shinzui/shomei.git
```

In the Kikan-En checkout, preserve unrelated working-tree changes, update the packages and host,
then build the old behavior before adding the new behavior:

```bash
git status --short
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all
nix develop -c cabal run kikan-en-conformance
```

Apply the canonical En migration plan, never the old copied SQL probes:

```bash
nix develop -c just process-up
nix develop -c just create-database
nix develop -c cabal run en-migrate -- verify
nix develop -c cabal run en-migrate -- up
```

After M2–M4, run all contract, client, server, conformance, and black-box tests and regenerate the
OpenAPI artifact with the repository’s new named target:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all
nix develop -c cabal run kikan-en-conformance
nix develop -c cabal run kikan-en-openapi
git diff --exit-code -- docs/api/openapi.json
```

In the Shikigami checkout, first prove the current baseline, then run the focused capability and
sink suites followed by the whole project:

```bash
git status --short
nix develop -c cabal build all --enable-tests
nix develop -c cabal test shikigami-core-test
nix develop -c cabal test all
```

The implementation commits in Kikan-En and Shikigami must use Conventional Commits and carry the
cross-repository plan and intention trailers. Mori cannot yet resolve plan artifacts, but the
intended canonical plan URI is still the durable reference:

```text
feat(authz): authorize exact capability tool invocations

ExecPlan: mori://shinzui/en/plans/27-per-action-authorization-for-agent-tool-and-sink-dispatch
Intention: intention_01kw4y7s4jet8ad44mf6mqa8cr
```


## Validation and Acceptance

The plan is complete only when all of these behaviors are observable through public boundaries:

1. Kikan-En builds against the recorded En commit, uses `en-migrate`, serves under `/v1`, and the
   pre-existing sink/workspace/intention conformance matrix remains green.
2. A request without a Shomei bearer token receives 401; one without the closed machine scope
   receives 403; insufficiently fresh JWKS state receives 503; none reaches En.
3. One agent granted `can_connect` on one capability revision may acquire it. A sibling revision
   and another agent are denied.
4. One agent granted `can_invoke` on one logical tool may invoke it. Another advertised tool from
   the same provider and the same logical name under another capability are denied. Provider
   connection or discovery alone never grants invocation.
5. An allow returns a Biscuit with the exact subject, operation, resource, schema hash,
   consistency token, audience, expiry, and request id. The client verifies it locally only for
   the exact dispatch.
6. Expired, tampered, wrong-subject, wrong-operation, wrong-resource, wrong-audience,
   wrong-schema, and revoked proofs fail closed and never run the wrapped IO action.
7. Relationship deletion prevents the next mint. An already-issued proof expires within 60
   seconds, and the documentation states that bounded window explicitly.
8. Shikigami keeps the C11 database gate and adds C13 at capability acquisition, tool invocation,
   sink enqueue, and sink publish. A denial or outage produces no provider connection, tool call,
   or sink delivery.
9. The generated OpenAPI artifact matches the public client, all focused and full test suites
   pass, and logs contain decision coordinates but no credentials, proof bytes, tool payloads, or
   sink payloads.

Record concise output from the successful conformance run and end-to-end run in Progress and
Outcomes & Retrospective while implementing. A compile-only result is not acceptance.


## Idempotence and Recovery

Schema values and contract types are pure, additive Haskell changes and can be rebuilt repeatedly.
Relationship writes remain idempotent under En’s live-tuple uniqueness rule. Revocation deletes
the exact relationship; deleting an absent relationship is a no-op.

Database setup is forward-only through pg-migrate. `en-migrate up` may be retried and concurrent
callers serialize on the migration lock. Never edit an applied migration or repair a real database
by dropping it. Add a new migration and use `en-migrate verify` before deployment.

JWKS refresh keeps the last valid key set only within the configured maximum staleness. Cold-start
failure and expiry of that window fail closed with unavailable. Biscuit issuer rotation is staged:
publish/trust the new public key first, switch the Kikan issuer second, and retain the old public
key until every proof it signed has exceeded the 60-second maximum lifetime.

The client may retry unavailable authorization before any protected IO occurs. It must not retry a
policy denial as though it were an outage, and it must generate or preserve a request id so repeated
attempts remain attributable. A provider or sink action is never retried merely because local proof
verification failed; obtain a fresh decision and verify it first.

Rollback is fail-closed. Removing the production action authorizer or its configuration must not
fall back to `emptyCapabilityRuntime`, static grants, declaration authority, or unchecked IO.
Disable affected capability/sink execution until the authorizer is restored. Existing short-lived
proofs die at their bounded expiry without a cleanup migration.


## Interfaces and Dependencies

`kikan-en-contract` must expose an interface equivalent to:

```haskell
data AgentAction
  = ConnectCapability CapabilityTarget
  | DiscoverCapabilityTools CapabilityTarget
  | InvokeCapabilityTool CapabilityToolTarget
  | ReadWorkspace WorkspaceTarget
  | WriteWorkspace WorkspaceTarget
  | ExecuteWorkspace WorkspaceTarget
  | DispatchSink SinkTarget
  | ActOnIntention IntentionTarget AutonomyContext

data AuthorizeActionRequest = AuthorizeActionRequest
  { principal :: AgentPrincipal
  , action :: AgentAction
  , requestId :: RequestId
  }

data AuthorizedAction = AuthorizedAction
  { principal :: AgentPrincipal
  , action :: AgentAction
  , resource :: CanonicalResource
  , requestId :: RequestId
  , schemaHash :: SchemaHash
  , checkedAt :: ConsistencyToken
  , expiresAt :: UTCTime
  , proof :: DecisionProof
  }

data IssuedActionProof = IssuedActionProof
  { proof :: DecisionProof
  , expiresAt :: UTCTime
  , revocationIds :: [RevocationId]
  , checkedAt :: ConsistencyToken
  }

data AuthorizeActionError
  = ActionDenied Denial
  | ActionRequestInvalid Problem
  | ActionAuthorizationUnavailable Problem
```

Constructors for principals, capability ids/revisions, logical tool names, and sink targets must be
smart constructors. The actual record access syntax follows the owning repository’s prelude and
generic-lens conventions; the shapes above define semantics, not permission to add partial record
construction.

`kikan-en-client` must expose an interface equivalent to:

```haskell
authorizeAgentAction
  :: KikanEnClient
  -> ShomeiAccessToken
  -> AuthorizeActionRequest
  -> IO (Either AuthorizeActionError AuthorizedAction)

verifyIssuedAction
  :: ActionProofVerifier
  -> UTCTime
  -> AuthorizeActionRequest
  -> IssuedActionProof
  -> IO (Either ActionProofError AuthorizedAction)
```

Kikan-En consumes En at exact commit
`51edaab17473f7b9310f8802ccffd23bac5e4a9e` until a real En release is verified. It consumes the
Shomei JWT verification vocabulary from the 0.1.0.0 tags at
`65551cb120336b53695c0dd30ebe0e473d6efcb2`; do not claim a Hackage bound while the authoritative
registry returns 404. Re-run both registry/tag checks immediately before implementation and update
this section if a release appears.

Shikigami’s integration consumes only `kikan-en-contract` and `kikan-en-client`. Its current
capability descriptor, provider, lease, tool registry, Meibo principal, C11 grant store, sink
intent, and outbox publisher stay owned by `mori://shinzui/shikigami`. MCP transport and credential
resolution remain outside this plan; a future MCP provider automatically inherits these checks by
registering through the already-gated capability provider/lease boundary.


## Revision Notes

- 2026-06-29: Relocated Kikan-specific schema, fixtures, conformance, and service work from En to
  the newly bootstrapped `mori://shinzui/kikan-en` project.
- 2026-08-26: Refreshed the plan against current En, Kikan-En, Shikigami, and Shomei source before
  implementation. Marked the already-delivered Kikan foundation as historical progress; replaced
  the stale raw `/check`, static-grant replacement, agent-name, raw MCP-server, and workspace-only
  assumptions with the current `/v1/grants` Biscuit proof, preserved C11 database gate, verified
  Meibo principals, immutable capability overlays, exact provider/tool actions, authenticated
  public client contract, and current migration/host seams. The revision implements
  `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-3` without putting Kikan policy in
  En.
