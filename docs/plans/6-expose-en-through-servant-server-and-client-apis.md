---
id: 6
slug: expose-en-through-servant-server-and-client-apis
title: "Expose en through Servant server and client APIs"
kind: exec-plan
created_at: 2026-06-23T04:05:56Z
intention: "intention_01kvsbcvsfepaafp5x44ykby47"
master_plan: "docs/masterplans/1-build-en-rebac-authorization-toolkit.md"
---

# Expose en through Servant server and client APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan turns the completed library into a usable standalone authorization service and Haskell client. After it is complete, a service can run `en-server`, write tuples over HTTP, receive consistency tokens, call `check`, `lookup`, and `expand`, and use a client package rather than constructing HTTP requests by hand. Servant route guards can compose after `shomei` authentication to protect object-specific endpoints.


## Progress

- [ ] Define JSON/wire types for tuples, subjects, caveats, consistency, decisions, lookup pages, expand trees, and errors.
- [ ] Define the Servant API type in `en-servant/src/En/Servant/API.hs`.
- [ ] Implement handlers that wire schema, reachability graph, tuple store, check, lookup, expand, write, and delete.
- [ ] Implement the `RequirePermission` or `Authorize` combinator in `en-servant/src/En/Servant/Authorize.hs`.
- [ ] Implement `en-server/app/Main.hs` configuration loading, Postgres connection setup, schema loading, migration guidance, and WAI serving.
- [ ] Implement `en-client/src/En/Client.hs` functions derived from or matching the Servant API.
- [ ] Add end-to-end tests or a reproducible local transcript for write-token-check-lookup.
- [ ] Run `cabal build all` and relevant tests.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Make this the final integration plan.
  Rationale: HTTP and client surfaces should serialize stable library semantics. Building them before core decisions settle would freeze placeholder APIs.
  Date: 2026-06-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on the complete library behavior from EP-1, EP-2, EP-3, EP-4, and EP-7. It has a soft dependency on EP-5 because the lookup spike may influence caps or materialization guidance, but the service API can still expose bounded lookup either way after the MasterPlan is updated.

The current files are placeholders: `en-servant/src/En/Servant/API.hs` exports nothing, `en-servant/src/En/Servant/Authorize.hs` exports nothing, `en-server/app/Main.hs` prints a scaffold message, and `en-client/src/En/Client.hs` exports nothing. The Cabal files currently comment out Servant and hasql dependencies until implementation lands.

The service must compose with `shomei` rather than replace it. `shomei` establishes identity and coarse role/scope gates. `en` receives or derives the subject identity and checks object-level permissions against relationship data.


## Plan of Work

Start by using Mori before relying on memory for Servant APIs:

```bash
mori registry search servant
mori registry show haskell-servant/servant --full
```

Read the relevant Servant source or local shomei-servant examples. Mirror shomei's package pattern where it fits, but keep `en`'s object-authorization semantics distinct.

Define wire types in `en-servant` or a shared module if `en-client` also needs them. Prefer reusing core types directly when their JSON instances are appropriate. Make consistency tokens opaque on the wire. Make lookup truncation and next cursors explicit.

Define API routes for check, lookup, expand, write tuples, and delete tuples. The route shapes should match the query surface from `docs/spec/0001-en-overview.md`, not the old placeholder comments.

Implement handlers in `en-servant` or `en-server` depending on the package boundary chosen during implementation. The server should initialize the active schema, compile it, construct the Postgres tuple store, and pass requests to core functions.

Implement a route guard combinator that runs after authentication. It should obtain the verified subject from the surrounding app's auth context, derive the object from the request, call `check`, and reject the request unless the decision is an unconditional allow.

Implement `en-client` functions for each endpoint. If using `servant-client`, keep the client typed and derived from the API type.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/en
```

Inspect API placeholders:

```bash
sed -n '1,220p' en-servant/src/En/Servant/API.hs
sed -n '1,220p' en-servant/src/En/Servant/Authorize.hs
sed -n '1,220p' en-client/src/En/Client.hs
sed -n '1,120p' en-server/app/Main.hs
```

Update Cabal dependencies as needed. Implement the API, handlers, server, and client. Add tests or an executable smoke scenario.

Run:

```bash
cabal build all
```

Run test suites added by this or earlier plans:

```bash
cabal test all
```

If a dev server is runnable locally, document the command and expected health or API response here during implementation.


## Validation and Acceptance

Acceptance requires an end-to-end scenario. A user should be able to start the server against a configured Postgres database and active schema, write a tuple, receive a consistency token, call check with `AtLeastAsFresh token`, and receive an allowed decision. Lookup should return a bounded page with a cursor field, and expand should return an explanatory tree.

The `RequirePermission` or `Authorize` combinator must be tested enough to prove denied decisions reject a request and allowed decisions pass through. Conditional caveat decisions should fail closed unless the route explicitly supports supplying the required context.


## Idempotence and Recovery

Server startup should fail with clear errors for missing configuration, failed schema compilation, invalid database connection, or missing migrations. Client calls should preserve server error information without exposing internal exceptions. Re-running tests should not require manually cleaning unrelated databases.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/1-stabilize-core-authorization-interfaces.md`, `docs/plans/2-implement-postgresql-tuple-store-and-consistency-tokens.md`, `docs/plans/3-implement-schema-validation-and-reachability-compilation.md`, `docs/plans/4-implement-forward-authorization-check.md`, and `docs/plans/7-implement-cursored-reverse-lookup-and-expand.md`.

Soft dependency: `docs/plans/5-validate-bounded-lookup-with-the-kikan-read-filter-spike.md`.

This plan owns `en-servant`, `en-server`, and `en-client` public surfaces.


Revision note 2026-06-23: Added `intention_01kvsbcvsfepaafp5x44ykby47` to the plan frontmatter at the user's request.
