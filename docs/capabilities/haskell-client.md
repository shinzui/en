---
title: "Typed Haskell client for the standalone service"
type: Capability
description: "A servant-client-backed Haskell client mirroring the whole /v1 surface, with a helper for chaining a read against the consistency token a previous call returned."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-23
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-client
interface:
  - En.Client
requires:
  - CAP-18
evidence:
  - kind: module
    resource: en-client/src/En/Client.hs
    proves: enClient derives the full route record from the shared En.Servant.API type, so client and server cannot drift; chainFrom builds the consistency wire value for a token-pinned follow-up read.
  - kind: guide
    resource: docs/user/production-deployment-and-performance.md
    proves: When to choose the dedicated-service shape (and therefore this client) over embedding the libraries.
---

# Typed Haskell client for the standalone service

`En.Client` derives its routes from the same `En.Servant.API` type
[the server](servant-http-api.md) serves, so a route change breaks the client at compile time
rather than at runtime.

`chainFrom` turns a returned token into the consistency argument for the next call, which is the
read-your-own-writes pattern in one function:

```haskell
token <- writeTuples client …
result <- check client (chainFrom token) subject permission object
```

## Limits

- It mirrors the service. An embedded host that links [en-core](check-decisions-with-caveats.md)
  directly does not need it and should not use it.
- Retries, connection pooling, and circuit-breaking are the caller's concern; this is a typed
  wrapper over `servant-client`, not a resilience layer.
- Authentication headers are supplied by the caller's `ClientEnv`; the client has no key
  management of its own.
