---
title: "Fail-closed authorization guard for host routes"
type: Capability
description: "requirePermission wraps a check for a Servant handler so that denied, conditional, and engine-error outcomes all refuse the request, with a worked resolver pattern for GraphQL hosts."
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-24T14:35:00Z"
capabilityId: CAP-19
provider: mori://shinzui/en
status: shipped
stability: experimental
since: unreleased
packages:
  - en-servant
interface:
  - En.Servant.Authorize
requires:
  - CAP-6
evidence:
  - kind: test
    resource: en-example/test/Main.hs
    proves: An allowed route succeeds; a denied route returns 403; a conditional route returns 403; a store-error route returns 503; and the GraphQL resolver variants fail closed on denied, conditional, and engine-error outcomes alike.
  - kind: example
    resource: en-example/app/Main.hs
    proves: A guarded route and a guarded resolver wired over in-memory store interpreters.
  - kind: guide
    resource: docs/user/graphql-integration.md
    proves: Where to place enforcement boundaries in a GraphQL gateway without creating authorization fan-out.
---

# Fail-closed authorization guard for host routes

`requirePermission` is the call-discipline helper for a host's own routes. It runs a
[check](check-decisions-with-caveats.md) and throws unless the answer is `Allowed`.

The load-bearing detail is that **`Conditional` refuses**. A caveat that could not be discharged
is not a grant, and the tests assert the conditional route returns 403 exactly as the denied one
does. An engine or store failure returns 503 rather than falling open.

## Usage

```haskell
viewDocument env subject docId = do
    requirePermission env MinimizeLatency noCaveatContext subject (RelationName "view") (objectRef "document" docId)
    loadDocument docId
```

The `Consistency` and `CaveatContext` arguments are explicit: a gate has to say which snapshot
it is deciding at and what caveat context it can offer.

## Limits

- This is **call discipline, not route enforcement**. Nothing in the Servant route type forces a
  handler to call it; a handler that forgets is unguarded.
- It answers one triple per call. For per-field or per-row enforcement use
  [batch check](batch-check.md) and avoid fan-out.
