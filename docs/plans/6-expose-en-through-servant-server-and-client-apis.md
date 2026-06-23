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

- [x] Define JSON/wire types for tuples, subjects, caveats, consistency, decisions, lookup pages, expand trees, and errors. Completed 2026-06-23.
- [x] Define the Servant API type in `en-servant/src/En/Servant/API.hs`. Completed 2026-06-23.
- [x] Implement handlers that wire schema, reachability graph, tuple store, check, lookup, expand, write, and delete. Completed 2026-06-23.
- [x] Implement the `RequirePermission` or `Authorize` combinator in `en-servant/src/En/Servant/Authorize.hs`. Completed 2026-06-23 as a fail-closed `requirePermission` helper for authenticated handlers.
- [x] Implement `en-server/app/Main.hs` configuration loading, Postgres connection setup, schema loading, migration guidance, and WAI serving. Completed 2026-06-23 with `EN_DATABASE_URL`, `EN_PORT`, built-in demo schema, and codd migration guidance.
- [x] Implement `en-client/src/En/Client.hs` functions derived from or matching the Servant API. Completed 2026-06-23.
- [x] Add end-to-end tests or a reproducible local transcript for write-token-check-lookup. Completed 2026-06-23 with the demo-schema HTTP transcript below.
- [x] Run `cabal build all` and relevant tests. Completed 2026-06-23 for the API/client/server slice.


## Surprises & Discoveries

- The repository has no runtime schema parser yet. The standalone `en-server` therefore starts with a small built-in demo schema (`user`, `space#viewer`, `space#view`) and clear migration guidance rather than pretending arbitrary schema loading exists.
- `NoFieldSelectors` required enabling `OverloadedRecordDot` in the Servant/client/server packages before using unprefixed record fields ergonomically.


## Decision Log

- Decision: Make this the final integration plan.
  Rationale: HTTP and client surfaces should serialize stable library semantics. Building them before core decisions settle would freeze placeholder APIs.
  Date: 2026-06-23
- Decision: Use explicit wire DTOs in `en-servant`.
  Rationale: Core types intentionally have no JSON instances yet. Dedicated request/response types keep the wire format explicit and let EP-6 expose conditional lookup decisions, cursors, errors, and expand trees without coupling core internals to Aeson.
  Date: 2026-06-23
- Decision: Start `en-server` with a built-in demo schema until schema loading exists.
  Rationale: No schema parser or configuration format is present in the repository. The service can still be runnable and useful for the required write-token-check-lookup scenario over the demo schema, while arbitrary schema loading remains a future extension.
  Date: 2026-06-23


## Outcomes & Retrospective

The integration surface is now usable as a service and as a typed Haskell client. `en-servant` defines explicit wire DTOs, the `EnAPI` route type, WAI application construction, handlers for tuple writes/deletes and `check`/`lookup`/`expand`, and a fail-closed `requirePermission` helper. `en-client` derives typed client functions from the Servant API. `en-server` reads `EN_DATABASE_URL` and `EN_PORT`, connects to PostgreSQL with Hasql, constructs the Postgres tuple and consistency stores, compiles the built-in demo schema, and serves the API with Warp.

The standalone service intentionally ships with the demo schema:

- `user`
- `space#viewer @ user`
- `space#view = space#viewer`

There is no runtime schema parser in the repository yet, so arbitrary schema file loading remains future work rather than hidden implicit behavior.

Reproducible local HTTP transcript against a migrated database:

```bash
cd /Users/shinzui/Keikaku/bokuno/en

# Run the codd migrations in en-migrations/db/migrations first.
export EN_DATABASE_URL='postgresql://user@localhost:5432/en'
export EN_PORT=8080
cabal run en-server
```

In another shell, write a tuple in the demo schema:

```bash
curl -sS -X POST http://localhost:8080/tuples \
  -H 'content-type: application/json' \
  -d '{
    "tuples": [
      {
        "object": { "objectType": "space", "objectId": "project-x" },
        "relation": "viewer",
        "subject": {
          "tag": "SubjectIdWire",
          "contents": { "objectType": "user", "objectId": "alice" }
        },
        "caveat": null
      }
    ]
  }'
```

Expected shape:

```json
{"token":"<opaque-consistency-token>"}
```

Use that token for a read-your-writes check:

```bash
TOKEN='<opaque-consistency-token>'

curl -sS -X POST http://localhost:8080/check \
  -H 'content-type: application/json' \
  -d "{
    \"consistency\": { \"tag\": \"AtLeastAsFreshWire\", \"contents\": \"$TOKEN\" },
    \"context\": { \"values\": {} },
    \"subject\": {
      \"tag\": \"SubjectIdWire\",
      \"contents\": { \"objectType\": \"user\", \"objectId\": \"alice\" }
    },
    \"permission\": \"view\",
    \"object\": { \"objectType\": \"space\", \"objectId\": \"project-x\" }
  }"
```

Expected response:

```json
{"decision":{"tag":"AllowedWire"}}
```

Lookup returns a bounded page with explicit cursor state:

```bash
curl -sS -X POST http://localhost:8080/lookup \
  -H 'content-type: application/json' \
  -d "{
    \"consistency\": { \"tag\": \"AtLeastAsFreshWire\", \"contents\": \"$TOKEN\" },
    \"context\": { \"values\": {} },
    \"cursor\": null,
    \"limit\": 10,
    \"objectType\": \"space\",
    \"permission\": \"view\",
    \"subject\": {
      \"tag\": \"SubjectIdWire\",
      \"contents\": { \"objectType\": \"user\", \"objectId\": \"alice\" }
    }
  }"
```

Expected response shape:

```json
{
  "objects": [
    {
      "object": { "objectType": "space", "objectId": "project-x" },
      "decision": { "tag": "AllowedWire" }
    }
  ],
  "state": { "tag": "LookupExhaustedWire" }
}
```

Expand returns the explanatory tree:

```bash
curl -sS -X POST http://localhost:8080/expand \
  -H 'content-type: application/json' \
  -d "{
    \"consistency\": { \"tag\": \"AtLeastAsFreshWire\", \"contents\": \"$TOKEN\" },
    \"context\": { \"values\": {} },
    \"cursor\": null,
    \"limit\": 10,
    \"object\": { \"objectType\": \"space\", \"objectId\": \"project-x\" },
    \"permission\": \"view\"
  }"
```

Expected response shape:

```json
{
  "root": { "objectType": "space", "objectId": "project-x" },
  "permission": "view",
  "children": [
    {
      "tag": "ExpandUsersetWire",
      "contents": [
        { "objectType": "space", "objectId": "project-x" },
        "viewer",
        [
          {
            "tag": "ExpandSubjectWire",
            "contents": {
              "tag": "SubjectIdWire",
              "contents": { "objectType": "user", "objectId": "alice" }
            }
          }
        ]
      ]
    }
  ],
  "state": { "tag": "ExpandExhaustedWire" }
}
```


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
