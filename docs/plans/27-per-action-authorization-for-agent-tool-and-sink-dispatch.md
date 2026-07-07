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

Today an autonomous agent in the portfolio is authorized **coarsely and statically**. When the
agent runtime (`shinzui/shikigami`) wants to send an agent's output somewhere — raise an
awareness signal, record an action against a plan, write a digest back into memory, reply on a
customer channel — it calls one function,
`checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())`, which looks the agent's name
up in a hard-coded table (`defaultGrantTable`) and answers yes/no **per sink *kind***. "May
`heartbeat` raise *any* signal?" is the only question it can ask. It cannot ask "may `heartbeat`
raise a signal **about this particular customer**?", "may this agent record an action against
**intention 42** specifically?", or "may this agent run a **bash** tool inside **this**
repository but not that one?". And there is no check at all when an agent runs a **work tool**
(read/write/edit/bash a file) — only when it emits a sink.

After this change, authorization becomes **fine-grained and relationship-derived**. Each agent
action is checked against the **specific object it touches** through `en`, the portfolio's
relationship-based access-control engine provided by `shinzui/en`. A grant is no
longer a row in a hard-coded Haskell table; it is a **relationship tuple** written into `en` —
for example "`agent:triage` is the *signaler* of `kizashi_recipient:acct-9931`" or
"`agent:repo-bot` is a *writer* of `workspace:shinzui/kikan`". The runtime answers each action
by asking `en` one question: *does this agent have this permission on this exact object?*

This plan was originally drafted in `shinzui/en`, but the implementation belongs in the new
`kikan-en` project at `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`. `en` is the reusable
authorization engine and service library. The Kikan-specific schema vocabulary, Kikan grant
fixtures, Kikan conformance harness, and Kikan deployment wrapper are product policy and must live
in `kikan-en`, which depends on the `en-*` packages instead of adding Kikan product concepts to
`en-core`.

Concretely, after this plan a reader can, from a checkout of
`/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`:

- Run a self-contained conformance harness that **writes grant tuples**, then shows `en` **allows**
  a permitted agent action against the granted object and **denies** the same action against an
  object that was never granted — proving per-object granularity, not per-kind.
- See the **on-behalf-of** case resolve: a delegation tuple
  `(intention:42, act_delegate, agent:triage)` carrying an autonomy/time caveat makes
  `check(agent:triage, can_act, intention:42)` return `Allowed` while the autonomy budget holds and
  `Denied` once the time bound expires or the requested autonomy exceeds the grant.
- Run the Kikan authorization server wrapper and reproduce the **exact HTTP `check` request** the
  agent runtime will send at dispatch time and at tool-execution time, observing `AllowedWire` /
  `DeniedWire`.

The user-visible result: agents act under an **attributable, bounded, per-object** authorization
that a human can grant and revoke by writing/deleting a single relationship, and the same gate now
covers **both** what an agent emits (sinks) **and** what an agent does (work tools).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0.1 — Keep this `shinzui/en` plan as a relocation record and carry the executable
      implementation work into `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`.
- [ ] M1.1 — Add the agent-authorization object types, relations, and permissions to the Kikan
      schema owned by `kikan-en`: sink-target types (`kawa_source`,
      `kizashi_recipient`, `danwa_thread`, `channel_egress`), tool-target type (`workspace`), the
      `act_delegate` caveated relation + `can_act` permission on the existing `intention` type, and
      the `agent` subject namespace.
- [ ] M1.2 — Schema compiles inside `kikan-en`: `compileSchema kikanSchema` succeeds and any
      generic `en` conformance assertions remain untouched in `shinzui/en`.
- [ ] M2.1 — Define the grant-tuple shapes and the object-identifier scheme for every sink kind and
      tool class as named fixtures in a new `kikan-en` module, for example
      `Kikan.En.Conformance.Agent`.
- [ ] M2.2 — Prove tuple writes are idempotent (re-writing a grant is a no-op; one live edge).
- [ ] M3.1 — Per-action conformance harness in `kikan-en` proving
      allow-on-granted-object / deny-on-ungranted-object for each sink kind and tool class.
- [ ] M3.2 — On-behalf-of (`act`) conformance: caveated delegation allows within autonomy/time and
      denies when expired or over-budget.
- [ ] M4.1 — Document and reproduce the exact `en-server` HTTP `check` request the runtime sends,
      for a sink dispatch and a tool invocation, against a live server.
- [ ] M5.1 — Write the shikigami integration contract: the new `checkAction` signature, the
      SinkKind/ToolKind → (permission, objectType) mapping, the two call sites, and the
      consistency/`act`-claim handling. (Downstream edits live in `shinzui/shikigami`; this plan
      owns the contract only.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet from implementation.)

- Discovery: `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en` has been bootstrapped as a git
  repository with Nix/Haskell scaffolding, but no `mori.dhall` was present when this plan was
  revised. Implementation steps should add project metadata if the Kikan repository registration
  depends on it.
  Evidence: `find /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en -maxdepth 2 -type f -print`
  showed `.seihou`, `flake.nix`, `process-compose.yaml`, and Nix files; `test -f mori.dhall &&
  mori show --full || true` produced no project metadata output.
  Date: 2026-06-29


## Decision Log

Record every decision made while working on the plan.

- Decision: Model each agent action as a **permission on the target object**, with the agent as the
  **subject** — never as a relation hung off the agent. So a sink dispatch is
  `check(agent:<name>, can_dispatch, <sinkObject>)` and a tool invocation is
  `check(agent:<name>, <tool-permission>, workspace:<id>)`.
  Rationale: this is exactly `en`'s Zanzibar model (`object#relation@subject`, see
  `en-core/src/En/Tuple.hs` and `En/Check.hs`). Permissions are computed *on* the object from
  relations *on* the object; there is no "relation on a subject". The design-intent shorthand
  `agent#can_dispatch` names the *agent's capability*, which `en` realizes as the permission
  `can_dispatch` on the sink object granted to the agent subject.
  Date: 2026-06-27

- Decision: Use **one object type per sink kind** (`kawa_source`, `kizashi_recipient`,
  `danwa_thread`, `channel_egress`) plus the existing `intention` for `ReiAction`, each with a
  uniform writable relation and a uniform `can_dispatch` permission — except `intention`, whose
  `ReiAction` permission is `can_act` (caveated). For tools, **one `workspace` type** with three
  graded relations (`reader` ⊆ `writer` ⊆ `executor`) and three permissions (`can_read`,
  `can_write`, `can_bash`).
  Rationale: a uniform permission name per concern keeps the runtime's mapping table tiny while the
  *object type + object id* carries the per-action granularity. Graded tool relations demonstrate
  fine-grained, per-verb authorization without a permission explosion.
  Date: 2026-06-27

- Decision: Object-identifier scheme. Sinks: `kawa_source:<source>` (e.g.
  `kawa_source:shinzui/shikigami`), `kizashi_recipient:<recipientId>`, `intention:<intentionId>`,
  `danwa_thread:<threadId>`, `channel_egress:<provider>/<conversationKey>` (e.g.
  `channel_egress:zendesk/ticket-4815`). Tools: `workspace:<repo-or-path-id>` (e.g.
  `workspace:shinzui/kikan`). Subjects: `agent:<name>`, where `<name>` is the agent's
  `shomei` loginId tail (the verified `agent:<name>` identity from C11/C13).
  Rationale: object ids mirror the identifiers the runtime already has in hand at dispatch time (the
  sink's destination) and at tool-execution time (the `ToolEnv` workspace), so no extra resolution
  step is needed.
  Date: 2026-06-27

- Decision: Represent **on-behalf-of** (`act`) as a graph-derived delegation, not an asserted claim.
  The grant is a tuple `(intention:<id>, act_delegate, agent:<name>)` with the existing
  `within_autonomy` caveat carrying `{autonomy, until}`; the runtime supplies request context
  `{requested_autonomy, current_time}` on the `check`. The human the agent serves (`act.sub` on the
  shomei token) is carried for **attribution/audit** and may additionally be checked as the
  intention owner, but the agent's authority itself comes from the delegation edge, per C13 ("on-
  behalf-of authority is graph-derived, not asserted").
  Rationale: matches the C13 contract and uses the same `within_autonomy` caveat model in the
  `kikan-en` Kikan schema.
  Date: 2026-06-27

- Decision: Keep the **coarse / fine split**. `shomei` (C11) stays the *first* gate — identity plus
  coarse scopes (`signal:raise`, `channel:egress`, …) checked with `requireScope`. `en` (C13) is the
  *second* gate — the per-object check. This plan owns only the second gate; it does **not** absorb
  shomei's static per-agent scope grants.
  Rationale: defense in depth, and the explicit division of labor in C11/C13
  (`shinzui/kikan → docs/architecture/evolution/contracts.md`).
  Date: 2026-06-27

- Decision: shikigami consumes `en` over **HTTP** (the `en-server` `/check` endpoint), not as a
  linked library, in its first integration. Rationale: shikigami already mirrors wire DTOs and uses
  `http-client` to avoid servant version-coherence pins (see its EP-3 Surprises); an HTTP `check` is
  the lowest-friction swap for the current `checkGrant` body. The embedded-library path
  (`En.Check.check`) remains available and is what this plan's conformance harness uses directly.
  Date: 2026-06-27

- Decision: Implement this plan in the new `kikan-en` project, not in `shinzui/en`.
  Rationale: `shinzui/en` is registered as a reusable Haskell ReBAC toolkit and standalone
  authorization service. The object types and relations in this plan (`kawa_source`,
  `kizashi_recipient`, `danwa_thread`, `channel_egress`, `workspace`, `intention`, and
  agent/tool-dispatch semantics) are Kikan product policy. Keeping them in `kikan-en` lets Kikan
  depend on `en-core`, `en-postgres`, `en-servant`, `en-server`, and `en-client` without making the
  generic engine carry portfolio-specific vocabulary.
  Date: 2026-06-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of `en`, of the agent runtime, or of the surrounding
architecture. Read it before touching code.

### What `en` is, in plain terms

`en` (縁, "the ties that bind") is a **relationship-based access-control (ReBAC) toolkit** written in
Haskell, in the **Zanzibar lineage** (the family of Google's Zanzibar paper → OpenFGA → SpiceDB).
"ReBAC" means access is decided by **relationships between principals and objects**, not by static
roles. The core question `en` answers is *"may **this** subject do **this** to **THIS** object,
given how they are related?"* — the **object-level** question, as opposed to coarse identity
questions like "is this caller logged in" or "does this caller have the `signal:raise` scope".

The unit of data is a **relationship tuple**: `(object, relation, subject)` — read as "*subject*
has *relation* on *object*". For example `(space:eng, member, user:bob)` means "bob is a member of
the eng space". A tuple may carry a **caveat**: a small bounded condition (e.g. a time limit or an
autonomy level) evaluated at query time. Tuples are the only authorization data; everything else is
computed from them.

A **schema** declares the object types, their relations, and **permissions**. A *relation* is
writable (you store tuples for it); a *permission* is **computed** from relations by **rewrite
rules** — unions, intersections, exclusions, and "arrows" that follow a relation to another object.
For example `permission view = owner ∪ member` says "you may view if you are an owner or a member".
`en` is **schema-parametric**: it ships no built-in model; each consumer supplies a schema as a
Haskell value (built with `En.Schema.Builder`). Earlier Kikan conformance examples may exist in
`shinzui/en`, but this plan's production Kikan schema belongs in
`/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`, not in `en-core`.

The query surface (all over a compiled schema plus a tuple store):

- `check(subject, permission, object) → CheckDecision` — the gate; the one this plan uses.
- `lookup(subject, permission, objectType) → [object]` — "what may this subject reach?" (read-filter).
- `expand(object, permission) → tree` — "who can reach this object?" (audit).
- `write` / `delete` tuples → return a `ConsistencyToken`.

A `CheckDecision` (`en-core/src/En/Decision.hs`) is three-valued: `Allowed`, `Denied`, or
`Conditional [obligations]` (a path exists but a caveat needs context the caller did not supply).
**Fail closed**: treat anything that is not `Allowed` as a denial unless you can supply the missing
caveat context and retry.

### The two gates: `shomei` (C11) and `en` (C13)

The architecture splits authorization into two composed gates, documented in
`shinzui/kikan → docs/architecture/evolution/contracts.md` as **C11** and **C13**, and in
`shinzui/kikan → docs/architecture/evolution/trust-grants.md`:

- **C11 / `shomei` (証明, "proof") — *who you are* and *may you do this class of thing at all*.**
  `shomei` is the portfolio's JWT/JWKS authentication service. It issues tokens carrying a verified
  `sub` (a user-id), coarse `scopes` (e.g. `signal:raise`, `channel:egress`), and an `act` claim
  (on-behalf-of attribution). It can mint **scoped service tokens** for machine callers
  (`POST /auth/service-token`, see `shinzui/shomei → docs/user/service-tokens.md`). The verified
  `sub` resolves to a stable **loginId**; an agent's loginId has the form `agent:<name>`.
- **C13 / `en` — *may you do this to **THIS** object, given how you are related to it*.** This plan.
  A request passes `shomei`'s coarse gate **first**, then `en`'s object gate **second** — two gates,
  never one in place of the other.

This plan is the realization of **gap #7** in
`shinzui/kikan → docs/architecture/evolution/agent-infrastructure-gaps.md` ("Per-action
authorization — extend `checkGrant` from sink-level to per-action via `en` ReBAC, the C13 seam").

### What exists today on the consumer side (the thing being replaced)

The agent runtime is `shinzui/shikigami`. Its current authorization seam is one module:
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Sink/Permission.hs`. It defines:

- `data SinkKind = SKawaDigest | SKizashiSignal | SReiAction | SDanwaConversation | SChannelEgress`
  — the five sink *kinds* an agent can emit. (`SChannelEgress` is reserved for a not-yet-added
  channel egress sink variant.)
- `newtype AgentIdentity = AgentIdentity { agentName :: Text }` — who is asking (the agent's name;
  destined to become the shomei-verified `sub`/loginId).
- `newtype Denied = Denied { deniedReason :: Text }`.
- `defaultGrantTable :: Map Text (Set SinkKind)` — a **hard-coded** allow-list keyed by agent name.
- `checkGrant :: AgentIdentity -> SinkKind -> IO (Either Denied ())` — looks the agent up in the
  table and returns `Right ()` if the *kind* is granted, else `Left Denied`. A denied sink is
  recorded and skipped; the run never crashes.

This is gated **only at sink level**, **only by agent name**, **statically**, and **only at sink
dispatch** (never at tool execution). The shikigami EP-3 plan
(`shinzui/shikigami → docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md`) that built it
explicitly anticipates this swap.

### Repository boundaries and modules this plan relies on

This plan is implemented in `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`. The concrete
module names in that repo may be adjusted to its package layout as it is scaffolded, but the
ownership boundary is fixed: Kikan object types and grant fixtures are `kikan-en` code.

- `kikan-en/src/Kikan/En/Schema.hs` — proposed home for the Kikan schema (`kikanSchema`,
  `kikanGraph`) containing `agent`, sink-target objects, `workspace`, and `intention` delegation.
  If the bootstrapped package uses a different module tree, keep the same responsibility in the
  nearest equivalent schema module.
- `kikan-en/src/Kikan/En/Conformance/Agent.hs` — proposed home for agent grant-tuple fixtures,
  object-id fixtures, and helper values used by the conformance executable.
- `kikan-en/app` or `kikan-en/src/Kikan/En/Server.hs` — proposed wrapper around `en-server` or the
  `en-servant` application wiring so Kikan can serve the Kikan schema without modifying `en-server`
  itself.
- `en-core/src/En/Schema/Builder.hs` — the reusable schema constructors: `object`, `relation`,
  `permission`, `subject`, `userset`, `this`, `computed`, `arrow`, `anyOf`, `allOf`, `minus`,
  `caveated`, `caveat`/`caveatWith`, `parameter`, the comparison/predicate combinators. Used to
  author the new object types from `kikan-en`.
- `en-core/src/En/Tuple.hs` — `Tuple{object, relation, subject, caveat}`,
  `ObjectRef{objectType, objectId}`, `Subject = SubjectId ObjectRef | SubjectSet ObjectRef RelationName | SubjectWildcard ObjectType`,
  `TupleCaveat{name, payload}`, `CaveatPayload`, `CaveatContext`, `CaveatValue`.
- `en-core/src/En/Check.hs` — `check :: ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Eff es CheckDecision`
  (the embedded gate, requires `ConsistencyStore`, `TupleStore`, `Error EnError` effects).
- `en-core/src/En/Revision.hs` — `data Consistency = MinimizeLatency | AtLeastAsFresh ConsistencyToken | AtExactSnapshot ConsistencyToken | FullyConsistent`,
  `newtype ConsistencyToken`.
- `en-core/src/En/Decision.hs` — `CheckDecision = Allowed | Denied | Conditional [CaveatObligation]`.
- `en-servant/src/En/Servant/API.hs` — the HTTP wire types and API: `/tuples` (POST write / DELETE),
  `/check`, `/batch-check`, `/lookup`, `/expand`; the wire DTOs `CheckRequestWire`,
  `CheckResponseWire`, `SubjectWire`, `ObjectRefWire`, `ConsistencyWire`, `CaveatContextWire`,
  `WriteTuplesRequestWire`, etc. **Read by** the shikigami integration contract (M4/M5).
- `en-client/src/En/Client.hs` — the typed Haskell client (`EnClient{ check, writeTuples, … }`) for
  the standalone service; an alternative to raw HTTP for a Haskell consumer.

### Terms of art defined

- **Sink** — an agent *output*: the thing it produces. The five kinds are kawa digest, kizashi
  signal, rei action, danwa conversation, channel egress (see `SinkKind` above).
- **Work tool / ToolEnv** — the agent's *execution* surface: read/write/edit a file, run a shell
  command, fetch a URL, scoped to *some* environment (the "ToolEnv"). This is gap #1 in the gap
  analysis; its concrete tool targets are defined by the shikigami/shikumi plan **"Built-in agent
  work tools and ToolEnv execution seam"** (a named dependency — see Interfaces and Dependencies).
- **Grant** — a relationship tuple that authorizes an agent for an action on an object. Written by
  a human/operator (the relationship's birthplace), read by the runtime via `check`.
- **Caveat** — a bounded condition on a tuple, evaluated against request context at query time. Used
  here for **autonomy-leveled** and **time-bounded** delegation (the `within_autonomy` caveat).
- **Consistency token** — an opaque string returned by a write; presenting it on a later read with
  `AtLeastAsFresh` guarantees the read observes that write (read-your-writes). Needed because `en`
  is a standalone multi-writer service.


## Plan of Work

The work is primarily in `kikan-en`: scaffold a thin Haskell package/application that depends on
the reusable `en-*` packages, define the Kikan schema with the agent-authorization vocabulary,
define the grant-tuple shapes, and prove — through a conformance harness and a live HTTP transcript
— that per-action checks behave correctly and that on-behalf-of resolves. The `shikigami`-side
wiring (swapping `checkGrant`'s body, extending it to tool execution) is a downstream
**dependency/integration** contract this plan specifies precisely but does not implement here.

No Kikan product object types should be added to `shinzui/en`. If work in `en` is discovered to be
necessary, it must be a generic engine/API capability, covered by its own `en` plan or a clearly
separate prerequisite milestone.

### Milestone 1 — The agent-authorization vocabulary (schema)

Scope: add the object types, relations, permissions, and the caveated delegation to the Kikan schema
in `kikan-en` so `en` can model every agent sink and the work-tool surface. At the end,
`compileSchema kikanSchema` succeeds inside the `kikan-en` package.

Create or edit the Kikan schema module in `kikan-en`, preferably
`src/Kikan/En/Schema.hs` unless the bootstrapped package establishes another module layout. Define
`kikanSchema` and `kikanGraph` there using `En.Schema.Builder`. Add:

- An **`agent`** object type with no relations: `Schema.object "agent" []`. (Like `user`, it is only
  ever a *subject*. Declaring it makes `Schema.subject "agent"` legal as an allowed subject.)
- A **`kawa_source`** object: `relation "digester" [subject "agent"] this`, and
  `permission "can_dispatch" (computed "digester")`. (Backs `SKawaDigest`.)
- A **`kizashi_recipient`** object: `relation "signaler" [subject "agent"] this`,
  `permission "can_dispatch" (computed "signaler")`. (Backs `SKizashiSignal`.)
- A **`danwa_thread`** object: `relation "attacher" [subject "agent"] this`,
  `permission "can_dispatch" (computed "attacher")`. (Backs `SDanwaConversation`.)
- A **`channel_egress`** object: `relation "egress_actor" [subject "agent"] this`,
  `permission "can_dispatch" (computed "egress_actor")`. (Backs `SChannelEgress`.)
- A **`workspace`** object (the work-tool target) with three graded relations and three permissions:
  `relation "reader" [subject "agent"] this`, `relation "writer" [subject "agent"] this`,
  `relation "executor" [subject "agent"] this`; then
  `permission "can_read" (anyOf (computed "reader") [computed "writer", computed "executor"])`,
  `permission "can_write" (anyOf (computed "writer") [computed "executor"])`,
  `permission "can_bash" (computed "executor")`. (Graded so a `writer` implies `can_read`, an
  `executor` implies all three. Backs the work-tool surface — read/write/edit/bash.)
- Define or extend the **`intention`** object with the on-behalf-of path: add
  `relation "act_delegate" [subject "agent"] (caveated "within_autonomy" this)` and
  `permission "can_act" (computed "act_delegate")`. Define the `within_autonomy` caveat in
  `kikan-en` if it is not already provided by a shared Kikan schema module. Its parameters are
  `requested_autonomy`, `autonomy`, `current_time`, and `until`; its predicate is
  `requested_autonomy <= autonomy && current_time <= until`. (Backs `SReiAction`, with
  autonomy/time bounds.)

Acceptance: from `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`, the Kikan package builds,
and evaluating `kikanGraph` (which is `either (error . show) id (compileSchema kikanSchema)`) does
not error.

### Milestone 2 — Grant-tuple shapes, object-id scheme, and idempotence

Scope: pin the exact tuple every grant becomes, and the object-id scheme, as named fixtures the
conformance harness reuses; and confirm writes are idempotent. At the end, a `kikan-en` module
exports the agent subjects, target objects, and grant tuples.

Create `src/Kikan/En/Conformance/Agent.hs` in `kikan-en` (or the equivalent module selected by the
package layout) and add it to the `kikan-en` cabal file. Export:

- Agent subjects, e.g. `triageAgent = ObjectRef (ObjectType "agent") "triage"`,
  `repoBot = ObjectRef (ObjectType "agent") "repo-bot"`.
- Target objects, e.g. `acctRecipient = ObjectRef (ObjectType "kizashi_recipient") "acct-9931"`,
  `otherRecipient = ObjectRef (ObjectType "kizashi_recipient") "acct-0001"`,
  `shikigamiSource = ObjectRef (ObjectType "kawa_source") "shinzui/shikigami"`,
  `kikanWorkspace = ObjectRef (ObjectType "workspace") "shinzui/kikan"`,
  `intention42 = ObjectRef (ObjectType "intention") "42"`,
  `zendeskEgress = ObjectRef (ObjectType "channel_egress") "zendesk/ticket-4815"`.
- Grant tuples, e.g.
  `(kizashi_recipient:acct-9931, signaler, agent:triage)`,
  `(kawa_source:shinzui/shikigami, digester, agent:triage)`,
  `(workspace:shinzui/kikan, writer, agent:repo-bot)`,
  `(channel_egress:zendesk/ticket-4815, egress_actor, agent:triage)`,
  and the delegation `(intention:42, act_delegate, agent:triage)` with caveat
  `TupleCaveat (CaveatName "within_autonomy") (CaveatPayload {autonomy = ValueEnum "act", until = ValueTimestamp <T>})`
  (create a local helper such as `autonomyCaveat` in `Kikan.En.Schema` or
  `Kikan.En.Conformance.Agent`).

Idempotence is a property of the store, not the fixtures: `en-postgres`'s `writeTuples` issues
`INSERT … ON CONFLICT DO NOTHING` against the `relation_tuple_live_unique` unique index (over live
rows), so re-writing an identical grant is a no-op and produces exactly one live edge. M2.2 records
this and the acceptance test in M4 demonstrates it (write the same grant twice; `expand` shows one
edge; `check` is `Allowed`). Revocation is `deleteTuples` on the same tuple.

Acceptance: the `kikan-en` package compiles the new module; the grant fixtures type-check as
`[Tuple]`.

### Milestone 3 — Per-action and on-behalf-of conformance (embedded `check`)

Scope: prove, with the in-memory store, that `check` is **per object** and that the autonomy/time
caveat governs the `act` path. At the end, a conformance harness runs green and fails if the schema
or rewrite rules regress.

Add scenarios to a `kikan-en` conformance executable, preferably `app/kikan-en-conformance/Main.hs`
or `test/Kikan/En/ConformanceSpec.hs` depending on the package scaffold. Reuse the generic `en`
in-memory interpreters. If the current `en` in-memory store runners are not exposed from a reusable
module, first move or expose that generic test support from `en` in a separate prerequisite change;
do not put Kikan policy back into `en-core`. Assert, with the agent grant fixtures from M2 loaded:

- **Per-object allow vs deny (each sink kind).** With `(kizashi_recipient:acct-9931, signaler,
  agent:triage)` granted:
  `check(agent:triage, can_dispatch, kizashi_recipient:acct-9931) == Allowed`, and
  `check(agent:triage, can_dispatch, kizashi_recipient:acct-0001) == Denied` (same agent, same
  permission, **different object** — the granularity the static table cannot express). Repeat the
  allow/deny pair for `kawa_source`, `danwa_thread`, and `channel_egress`.
- **Graded tool permissions.** With `(workspace:shinzui/kikan, writer, agent:repo-bot)` granted:
  `can_read == Allowed`, `can_write == Allowed`, `can_bash == Denied` (writer implies read+write but
  not bash); and all three `Denied` against `workspace:other`.
- **On-behalf-of within bounds.** With the delegation tuple + `within_autonomy {autonomy=act,
  until=2026-07-01}` and request context `{requested_autonomy=act, current_time=2026-06-23}`:
  `check(agent:triage, can_act, intention:42) == Allowed`.
- **On-behalf-of denied (expired / over-budget).** Same delegation, context
  `{requested_autonomy=act, current_time=2026-08-01}` → `Denied` (time bound exceeded); and context
  `{requested_autonomy=admin, current_time=2026-06-23}` → `Denied` (autonomy budget exceeded). Define
  local helpers such as `requestContext`, `expiredContext`, and `adminContext` in `kikan-en`.
- **Unrelated agent denied.** `check(agent:other, can_dispatch, kizashi_recipient:acct-9931) ==
  Denied`.

Acceptance: `cabal run kikan-en-conformance` (or the selected test executable) prints all
assertions passing and exits 0.

### Milestone 4 — The live HTTP `check` contract

Scope: reproduce, against a running Kikan authorization server backed by the reusable `en` HTTP
surface, the **exact** write-then-check the runtime will perform, so the shikigami integration has a
concrete wire transcript to code against. At the end, a reader can paste two `curl`s and see
`AllowedWire` on the granted object and `DeniedWire` on an ungranted one, plus the on-behalf-of
pair.

There is nothing to build in `shinzui/en` for this milestone beyond depending on its existing HTTP
surface. `kikan-en` must provide a way to run `en-server` or an equivalent `en-servant` application
with the Kikan schema loaded. The runtime sends, for a **sink dispatch** (e.g. a kizashi signal to
recipient `acct-9931` by agent `triage`):

```json
{
  "consistency": {"tag": "AtLeastAsFreshWire", "contents": "<token-from-grant-write>"},
  "context": {"values": {}},
  "subject": {"tag": "SubjectIdWire", "contents": {"objectType": "agent", "objectId": "triage"}},
  "permission": "can_dispatch",
  "object": {"objectType": "kizashi_recipient", "objectId": "acct-9931"}
}
```

For a **tool invocation** (agent `repo-bot` running a write tool in `shinzui/kikan`), the same shape
with `subject.objectId = "repo-bot"`, `permission = "can_write"`,
`object = {"objectType": "workspace", "objectId": "shinzui/kikan"}`.

For the **on-behalf-of** rei action, `permission = "can_act"`,
`object = {"objectType": "intention", "objectId": "42"}`, and `context.values` carries the autonomy
context:

```json
"context": {"values": {
  "requested_autonomy": {"tag": "ValueEnumWire", "contents": "act"},
  "current_time": {"tag": "ValueTimestampWire", "contents": "2026-06-27T00:00:00Z"}
}}
```

The grant is written first via `POST /tuples` (shape per `WriteTuplesRequestWire`, exactly like the
smoke test in the `Justfile`), and its returned `token` is fed into `AtLeastAsFreshWire` so the
check observes the just-written grant (read-your-writes). The response is
`{"decision": {"tag": "AllowedWire"}}` or `{"tag": "DeniedWire"}`.

Acceptance: see Concrete Steps — the transcript shows `AllowedWire` for the granted object and
`DeniedWire` for an ungranted object, and the on-behalf-of `Allowed`/`Denied` pair.

### Milestone 5 — The shikigami integration contract (downstream)

Scope: specify precisely what changes in `shinzui/shikigami` so the next contributor (working in that
repo) can do the swap. **No `shinzui/en` code changes for M5**; it is the contract.

The contract (to be implemented in
`/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Sink/Permission.hs` and a new
tool-permission call site):

1. Keep `AgentIdentity` but treat `agentName` as the shomei-verified `agent:<name>` loginId tail.
2. Replace `defaultGrantTable` + the `Map`-lookup body of `checkGrant` with an `en` `check` call
   (HTTP via `http-client`, mirroring shikigami's existing wire-DTO approach, or `En.Client`):
   - **Sink path** — generalize `checkGrant` to take the sink's **target object**, not just its
     kind. Map `SinkKind` → `(permission, objectType)`:
     `SKawaDigest → ("can_dispatch","kawa_source")`,
     `SKizashiSignal → ("can_dispatch","kizashi_recipient")`,
     `SReiAction → ("can_act","intention")`,
     `SDanwaConversation → ("can_dispatch","danwa_thread")`,
     `SChannelEgress → ("can_dispatch","channel_egress")`. The object id is the sink's destination
     (the kawa source, the recipient, the intention id, the thread id, the `provider/conversationKey`).
   - **Tool path** — a **new** call at tool execution: map the tool's verb →
     `(permission, "workspace")` (`read → can_read`, `write|edit → can_write`, `bash → can_bash`),
     object id = the `ToolEnv` workspace identity. This is the second call site gap #7 requires.
   - **On-behalf-of** — for `SReiAction`, pass `context = {requested_autonomy, current_time}` and use
     the shomei `act.sub` for attribution in the recorded outcome.
   - **Consistency** — use `MinimizeLatency` for ordinary checks; use `AtLeastAsFresh token` only
     immediately after the runtime itself wrote a grant.
3. Map the `en` decision to the existing `Either Denied ()`: `Allowed → Right ()`; `Denied` and
   `Conditional _ → Left (Denied reason)`. The existing "record denial, skip the sink, never crash"
   behavior is preserved.

The renamed/generalized signature (illustrative) is
`checkAction :: AgentIdentity -> Permission -> ObjectRef -> IO (Either Denied ())`, with thin
wrappers `checkSink :: AgentIdentity -> SinkKind -> SinkTarget -> IO (Either Denied ())` and
`checkTool :: AgentIdentity -> ToolVerb -> WorkspaceId -> IO (Either Denied ())`. This milestone is
marked **dependency/integration**: it is completed in the shikigami repo, tracked there, and
referenced from this plan's Progress as the hand-off.


## Concrete Steps

All implementation commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en` inside that project's Nix dev shell. Enter it
first:

```bash
cd /Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en
nix develop            # or rely on direnv; provides GHC, cabal, just, psql, curl, jq
```

### Build and run the Kikan conformance (M1–M3)

```bash
cabal build all
cabal run kikan-en-conformance
```

Expected (after M1–M3; existing lines plus the new agent assertions):

```text
ok - triage can dispatch the granted kizashi recipient
ok - triage cannot dispatch an ungranted kizashi recipient
ok - repo-bot writer can read and write the workspace
ok - repo-bot writer cannot bash the workspace
ok - triage can act on intention 42 within autonomy
ok - triage cannot act on intention 42 after expiry
ok - unrelated agent is denied
```

If the bootstrapped project uses a different executable name, use that name consistently in the
cabal file and in this plan before implementation starts.

### Run the unit/property test suite

```bash
cabal test all
```

Expected: all `kikan-en` tests pass, including any schema compilation and grant-shape assertions.

### Bring up Postgres + the Kikan authorization server and reproduce the HTTP `check` (M4)

```bash
just process-up         # start local process-compose Postgres (detached)
just run-migrations     # idempotent: applies relation_tuple + history-index migrations
```

Start the Kikan authorization server pointed at the Kikan schema. The preferred implementation is a
`kikan-en` executable or `just` target that wires the Haskell `kikanSchema` into the reusable
`en-server`/`en-servant` machinery. If that wrapper does not exist yet, create it in `kikan-en`
rather than modifying `shinzui/en`. For local proof only, an `.en` text schema can express the
non-caveated subset of the model:

```bash
cat > /tmp/kikan-agent.en <<'EOF'
object user {}
object agent {}

object kawa_source       { relation digester:    agent  permission can_dispatch = digester }
object kizashi_recipient { relation signaler:     agent  permission can_dispatch = signaler }
object danwa_thread      { relation attacher:     agent  permission can_dispatch = attacher }
object channel_egress    { relation egress_actor: agent  permission can_dispatch = egress_actor }

object workspace {
  relation reader:   agent
  relation writer:   agent
  relation executor: agent
  permission can_read  = reader | writer | executor
  permission can_write = writer | executor
  permission can_bash  = executor
}
EOF

EN_DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" \
EN_SCHEMA_PATH=/tmp/kikan-agent.en \
  cabal run kikan-en-server &      # serves on http://localhost:${EN_PORT:-8080}
```

Note: the `.en` text-schema parser may not yet express **caveats**; the on-behalf-of (`can_act`)
case is therefore proven by the embedded harness (M3) and by an in-Haskell server schema. If the
text parser supports caveats, add the `intention` object with `act_delegate` + `within_autonomy`;
otherwise prove `can_act` via `cabal run kikan-en-conformance`. (Confirm parser caveat support in
`shinzui/en`'s `en-core/src/En/Schema/Parse.hs`; record the finding in Surprises.)

Write a grant, capture the token, and check the **granted** object then an **ungranted** one:

```bash
url="http://localhost:${EN_PORT:-8080}"

token=$(curl -sS -X POST "$url/tuples" -H 'content-type: application/json' -d '{
  "tuples":[{"object":{"objectType":"kizashi_recipient","objectId":"acct-9931"},
             "relation":"signaler",
             "subject":{"tag":"SubjectIdWire","contents":{"objectType":"agent","objectId":"triage"}},
             "caveat":null}]}' | jq -r '.token')

# Granted object → AllowedWire
curl -sS -X POST "$url/check" -H 'content-type: application/json' -d "{
  \"consistency\":{\"tag\":\"AtLeastAsFreshWire\",\"contents\":\"$token\"},
  \"context\":{\"values\":{}},
  \"subject\":{\"tag\":\"SubjectIdWire\",\"contents\":{\"objectType\":\"agent\",\"objectId\":\"triage\"}},
  \"permission\":\"can_dispatch\",
  \"object\":{\"objectType\":\"kizashi_recipient\",\"objectId\":\"acct-9931\"}}" | jq '.decision.tag'

# Ungranted object → DeniedWire
curl -sS -X POST "$url/check" -H 'content-type: application/json' -d "{
  \"consistency\":{\"tag\":\"AtLeastAsFreshWire\",\"contents\":\"$token\"},
  \"context\":{\"values\":{}},
  \"subject\":{\"tag\":\"SubjectIdWire\",\"contents\":{\"objectType\":\"agent\",\"objectId\":\"triage\"}},
  \"permission\":\"can_dispatch\",
  \"object\":{\"objectType\":\"kizashi_recipient\",\"objectId\":\"acct-0001\"}}" | jq '.decision.tag'
```

Expected:

```text
"AllowedWire"
"DeniedWire"
```

Idempotence check (write the same grant twice; second write is a no-op; check still allows):

```bash
curl -sS -X POST "$url/tuples" -H 'content-type: application/json' -d '{
  "tuples":[{"object":{"objectType":"kizashi_recipient","objectId":"acct-9931"},
             "relation":"signaler",
             "subject":{"tag":"SubjectIdWire","contents":{"objectType":"agent","objectId":"triage"}},
             "caveat":null}]}' | jq -r '.token'   # returns a token; no duplicate edge created
```

Tear down when finished:

```bash
just process-down
```

### Workspace tool check transcript (M4)

```bash
url="http://localhost:${EN_PORT:-8080}"
wtoken=$(curl -sS -X POST "$url/tuples" -H 'content-type: application/json' -d '{
  "tuples":[{"object":{"objectType":"workspace","objectId":"shinzui/kikan"},
             "relation":"writer",
             "subject":{"tag":"SubjectIdWire","contents":{"objectType":"agent","objectId":"repo-bot"}},
             "caveat":null}]}' | jq -r '.token')

for perm in can_read can_write can_bash; do
  printf '%s ' "$perm"
  curl -sS -X POST "$url/check" -H 'content-type: application/json' -d "{
    \"consistency\":{\"tag\":\"AtLeastAsFreshWire\",\"contents\":\"$wtoken\"},
    \"context\":{\"values\":{}},
    \"subject\":{\"tag\":\"SubjectIdWire\",\"contents\":{\"objectType\":\"agent\",\"objectId\":\"repo-bot\"}},
    \"permission\":\"$perm\",
    \"object\":{\"objectType\":\"workspace\",\"objectId\":\"shinzui/kikan\"}}" | jq -c '.decision.tag'
done
```

Expected:

```text
can_read "AllowedWire"
can_write "AllowedWire"
can_bash "DeniedWire"
```


## Validation and Acceptance

The change is effective beyond compilation when all of the following are observable:

1. **Per-object granularity (the core claim).** With a grant for one specific object, `check`
   returns `Allowed` for that object and `Denied` for a *different* object of the same type under the
   same agent and permission. Demonstrated by `cabal run kikan-en-conformance` (the
   "granted/ungranted kizashi recipient" assertions) and by the live `curl` transcript
   (`"AllowedWire"` then `"DeniedWire"`).
2. **Both surfaces covered.** Both a **sink** permission (`can_dispatch` on `kizashi_recipient`,
   `kawa_source`, `danwa_thread`, `channel_egress`) and a **tool** permission (`can_read`/`can_write`/
   `can_bash` on `workspace`) decide correctly — proving gap #7's "call at tool *and* sink dispatch".
3. **Graded tools.** A `writer` grant yields `can_read=Allowed`, `can_write=Allowed`,
   `can_bash=Denied`, proving per-verb granularity, not all-or-nothing.
4. **On-behalf-of resolution.** With the caveated delegation, `can_act` is `Allowed` within the
   autonomy/time budget and `Denied` once `current_time > until` or `requested_autonomy > autonomy`.
   Demonstrated by the M3 conformance assertions using the local `kikan-en` request-context helpers.
5. **Read-your-writes.** A `check` issued with `AtLeastAsFresh <write-token>` observes a grant
   written milliseconds earlier (the live transcript depends on this).
6. **Repository-boundary non-regression.** `git diff` in `shinzui/en` shows no Kikan policy
   implementation changes beyond this relocation note, and `cabal test all` in `kikan-en` passes.
   If a generic `en` prerequisite was required, its own tests in `shinzui/en` must also pass.

Test commands and their pass criteria: `cabal run kikan-en-conformance` exits 0 with every assertion
line printed `ok`; `cabal test all` in `kikan-en` reports all suites passed; the `curl` transcript
prints the exact decision tags shown above.


## Idempotence and Recovery

- **Schema edits (M1)** are pure additions to a Haskell value in `kikan-en`; re-running the build recompiles
  deterministically. If `compileSchema` throws (e.g. a permission references a missing relation),
  the error names the offending `objectType#relation`; fix the builder call and rebuild.
- **Tuple writes (grants)** are idempotent: `en-postgres.writeTuples` uses `INSERT … ON CONFLICT DO
  NOTHING` against the `relation_tuple_live_unique` unique index, so writing the same grant any
  number of times yields exactly one live edge and a fresh token each time. Re-running the M4
  `curl`s is safe.
- **Revocation / rollback** is `DELETE /tuples` (or `tupleStore.deleteTuples`) on the same tuple; it
  soft-deletes (stamps `deleted_xid`) so point-in-time reads remain correct. Deleting a
  never-written tuple is a no-op.
- **Migrations** are idempotent: `just run-migrations` checks `to_regclass` before applying each
  file and prints "already applied" otherwise.
- **Server startup** fails fast and non-zero if `EN_SCHEMA_PATH` cannot be read/parsed/validated, so
  a bad schema never serves traffic; fix the file and restart.
- A **denied** decision at the consumer (shikigami) is recorded and the action skipped — never a
  crash — preserving the existing fail-closed-but-keep-running behavior.


## Interfaces and Dependencies

### `en` interfaces this plan relies on from `kikan-en`

- Schema authoring — `En.Schema.Builder` (`en-core/src/En/Schema/Builder.hs`):
  `object :: Text -> [SchemaRelation] -> Either EnError SchemaObject`,
  `relation :: Text -> [SubjectSpec] -> Rewrite -> SchemaRelation`,
  `permission :: Text -> PermissionRewrite -> SchemaRelation`,
  `subject :: Text -> SubjectSpec`, `this :: Rewrite`, and the `RewriteExpr` combinators
  `computed`, `arrow`, `anyOf`, `allOf`, `minus`, `caveated`; caveats via
  `caveatWith :: Text -> [ParameterSpec] -> CaveatPredicate -> Either EnError CaveatSpec`,
  `parameter`, `ctxParam`, `payloadParam`, `cmpLe`, `predAnd`; assembled with
  `buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Either EnError Schema`.
- Tuples — `En.Tuple` (`en-core/src/En/Tuple.hs`):
  `Tuple{object :: ObjectRef, relation :: RelationName, subject :: Subject, caveat :: Maybe TupleCaveat}`,
  `ObjectRef{objectType :: ObjectType, objectId :: Text}`,
  `Subject = SubjectId ObjectRef | SubjectSet ObjectRef RelationName | SubjectWildcard ObjectType`,
  `TupleCaveat{name :: CaveatName, payload :: CaveatPayload}`.
- The gate — `En.Check`
  (`check :: ReachabilityGraph -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Eff es CheckDecision`,
  effects `ConsistencyStore`, `TupleStore`, `Error EnError`).
- Decision — `En.Decision.CheckDecision = Allowed | Denied | Conditional [CaveatObligation]`.
- Consistency — `En.Revision.Consistency = MinimizeLatency | AtLeastAsFresh ConsistencyToken | AtExactSnapshot ConsistencyToken | FullyConsistent`.
- Compilation — `En.Reachability.compileSchema :: Schema -> Either EnError ReachabilityGraph`.
- In-memory test interpreters — use reusable `en` in-memory `TupleStore` and `ConsistencyStore`
  interpreters. If they are currently only available through `En.Conformance.Kikan`, expose or move
  the generic interpreters in a separate `shinzui/en` prerequisite instead of importing Kikan
  conformance modules as production dependencies.
- HTTP surface (consumer-facing) — `En.Servant.API`: API `/tuples` (POST/DELETE), `/check`,
  `/batch-check`, `/lookup`, `/expand`; DTOs `CheckRequestWire{consistency, context, subject,
  permission, object}`, `CheckResponseWire{decision :: CheckDecisionWire}`,
  `SubjectWire = SubjectIdWire ObjectRefWire | …`, `ObjectRefWire{objectType, objectId}`,
  `ConsistencyWire = MinimizeLatencyWire | AtLeastAsFreshWire Text | …`,
  `CaveatContextWire{values :: Map Text CaveatValueWire}`,
  `WriteTuplesRequestWire{tuples :: [TupleWire]}`,
  `WriteTuplesResponseWire{token :: Text}`. Typed client alternative: `En.Client.EnClient`.

### Types/signatures that must exist at the end of each milestone

- M1: a `kikan-en` module such as `Kikan.En.Schema` exports `kikanSchema`; it includes object types
  `agent`, `kawa_source`, `kizashi_recipient`,
  `danwa_thread`, `channel_egress`, `workspace`, and the extended `intention`; permissions
  `can_dispatch` (per sink object), `can_read`/`can_write`/`can_bash` (workspace), `can_act`
  (intention). `compileSchema kikanSchema` is `Right _`.
- M2: a `kikan-en` module such as `Kikan.En.Conformance.Agent` exports the agent subjects, target
  `ObjectRef`s, and `agentGrantTuples :: [Tuple]` (including the caveated delegation).
- M3: a `kikan-en` conformance entrypoint, for example `kikan-en-conformance`, whose assertions
  encode the allow/deny matrix and the on-behalf-of pair.
- M4: a reproducible HTTP transcript (the `curl`s above) demonstrating the wire contract.
- M5: the shikigami contract — `checkAction :: AgentIdentity -> RelationName -> ObjectRef -> IO (Either Denied ())`
  plus `checkSink`/`checkTool` wrappers and the SinkKind/ToolVerb → (permission, objectType) maps.

### Cross-plan / cross-repo dependencies

- **`shomei` — scoped service tokens for agent actors** (kikan project-status gap #6, contract C11 in
  `shinzui/kikan → docs/architecture/evolution/trust-grants.md`). Prerequisite for a *verified* agent
  `sub` → `agent:<name>` loginId and for the `act` (on-behalf-of) claim. The issuance path exists
  (`POST /auth/service-token`, `shinzui/shomei → docs/user/service-tokens.md`); wiring shikigami to
  obtain and present these tokens is tracked under shomei/shikigami, not here. Until then the
  conformance harness uses literal `agent:<name>` subjects.
- **`shikigami` — "Built-in agent work tools and ToolEnv execution seam"** (the shikumi/shikigami
  plan for gap #1). Defines the **tool targets** — the `ToolEnv` workspace identity that becomes the
  `workspace:<id>` object id and the tool verbs that map to `can_read`/`can_write`/`can_bash`. This
  plan models the targets; that plan supplies them and is where the **tool-execution** `check` call
  site lives. The sink `check` call site lives in shikigami's sink dispatcher / run plans
  (`shinzui/shikigami → docs/plans/3-sink-dispatcher-permission-gate-and-kawa-stub.md` and the
  run-orchestration plan).
- **`shikigami` — `Shikigami.Sink.Permission`** (the consumer being upgraded; full path
  `/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Sink/Permission.hs`). M5 is
  implemented there.

### Build/test tooling

In `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en`, use `nix develop` (GHC + cabal + just +
psql + curl + jq), `cabal build all`, `cabal run kikan-en-conformance`, and `cabal test all`. The
project should depend on the local `en-*` packages through the workspace/cabal/Nix configuration
rather than copying their code. Use `just process-up` / `just run-migrations` /
`just process-down` if the bootstrapped `kikan-en` justfile exposes those targets; otherwise add
equivalent targets that start Postgres, run the reusable `en` migrations, and launch the Kikan
authorization server.

## Revision Notes

- 2026-06-29: Revised the plan to move implementation ownership from `shinzui/en` to the newly
  bootstrapped `/Users/shinzui/Keikaku/bokuno/kikan-project/kikan-en` repository. The change keeps
  `shinzui/en` as the reusable ReBAC engine and moves Kikan schema, fixtures, conformance, and
  service wiring into the thin Kikan wrapper project.
