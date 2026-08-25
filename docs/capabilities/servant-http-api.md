---
title: "Servant HTTP API with a generated OpenAPI document"
type: Capability
description: "The whole read and write surface as a typed Servant API under /v1, with wire types, a structured error envelope, and an OpenAPI 3 document generated from the same types and checked against them."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-18
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-servant
interface:
  - En.Servant.API
  - En.Servant.Seam
  - En.Servant.OpenApi
  - en-openapi
evidence:
  - kind: test
    resource: en-servant/test/Main.hs
    proves: wireContractTests, errorModelTests, openApiDocumentTests, and toJsonMatchesToSchema — every wire type round-trips, every fault maps to its documented status, and the generated OpenAPI schema agrees with the JSON encoding.
  - kind: module
    resource: docs/api/openapi.json
    proves: The checked-in OpenAPI 3 document the en-openapi executable regenerates.
  - kind: guide
    resource: docs/user/service-and-operations.md
    proves: "The Servant API section: routes, versioning, error responses, write preconditions, and lookup deadlines."
---

# Servant HTTP API

One `NamedRoutes` record covers the whole surface under `/v1`:

| Route | Capability |
| --- | --- |
| `POST /v1/check`, `POST /v1/batch-check` | [check](check-decisions-with-caveats.md), [batch check](batch-check.md) |
| `POST /v1/lookup`, `POST /v1/lookup-subjects` | [lookup](lookup-objects.md), [lookup-subjects](lookup-subjects.md) |
| `POST /v1/expand` | [expand](expand-subject-tree.md) |
| `POST /v1/relationships` and its `delete`, `delete-by-filter`, `query` siblings | [writes](relationship-writes.md) |
| `POST /v1/watch` | [watch feed](watch-feed.md) |
| `GET /v1/schema` | [schema reload and preflight](schema-reload-and-preflight.md) |
| `POST /v1/grants` | [Biscuit decision tokens](biscuit-decision-tokens.md) |

`En.Servant.Seam` is the boundary a host implements: supply an `Env`, get a `Server EnAPI` or a
WAI `Application`. The `en-openapi` executable regenerates `docs/api/openapi.json`.

## Limits

- Errors are a structured `ErrorEnvelopeWire`, **not** RFC 7807 `application/problem+json`. The
  migration to problem details is planned but not shipped.
- Versioning is by path prefix (`/v1`) only; there is no content negotiation on version.
- The API type is transport plumbing. It performs no authentication — that lives in
  [the standalone server](standalone-authorization-server.md) or in the host.
