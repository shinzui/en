---
type: Improvement Request
title: Accept the API key in a header the Kubernetes API server forwards
description: >-
  Let a caller present its En API key as `X-En-Api-Key` in addition to `Authorization: Bearer`, so a client that reaches En through the Kubernetes API server's service proxy, which deletes the Authorization header after authenticating the caller, can authenticate without a port-forward.
timestamp: "2026-10-28T20:15:15Z"
generated:
  by: process:claude-code
  at: "2026-10-28T20:15:15Z"
requestId: IR-1
status: accepted
targetPlan: docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md
origin: mori://shinzui/nagare
acceptanceCriteria:
  - id: AC-1
    statement: >-
      A request that carries `X-En-Api-Key: <secret>` and no Authorization header authenticates exactly as `Authorization: Bearer <secret>` does, against the same EN_API_KEYS_READ_WRITE and EN_API_KEYS_READ_ONLY entries, with the same constant-time comparison, the same read-only refusal of write requests, and the same caller header set to the key's name.
    verification: en-server tests send the same read-write and read-only keys through each header and assert identical handler reachability, caller header, read-only-key problem and 401 problem body; an unknown secret in the new header yields the unchanged 401 with WWW-Authenticate Bearer.
  - id: AC-2
    statement: When both headers are present they must name the same key; otherwise the request is unauthenticated.
    verification: A test with a valid bearer and a different valid X-En-Api-Key answers 401; a test with both naming the same key succeeds.
  - id: AC-3
    statement: The OpenAPI document declares an `apiKeyAuth` security scheme (type apiKey, in header, name X-En-Api-Key) beside `bearerAuth`, every authenticated operation lists both as alternatives, health probes keep no requirement, and docs/api/openapi.json is regenerated.
    verification: The en-servant OpenAPI test that today asserts exactly bearerAuth asserts both schemes and the two-alternative requirement on every non-probe operation; the checked-in document matches the generator.
  - id: AC-4
    statement: The server documentation describes the header, states that it exists for proxies that consume Authorization, names the Kubernetes API server's service proxy as the case, and keeps Bearer as the default.
    verification: docs/user/service-and-operations.md, section "Authentication, rate limiting, and TLS", shows a curl example with X-En-Api-Key and the proxy path, and the example runs against a server started with the documented key variables.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-22T21:28:49Z"
    document_timestamp: "2026-10-22T21:28:49Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: >-
      Author review against en master e3dd21f (en-server/app/Middleware.hs,
      en-servant/src/En/Servant/OpenApi.hs, docs/user/service-and-operations.md), the
      Kubernetes apiserver authentication filter source, and a read-only probe of the
      proxy path from the Nagare operator's workstation on 2026-10-22. No independent
      verification attestation is claimed.
---

# Accept the API key in a header the Kubernetes API server forwards

**Authored by:** a `claude-code` session planning
`mori://shinzui/nagare/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently`
for the Nagare platform (`mori://shinzui/nagare`).


## What is asked

Let a caller present its API key in a request header of its own, `X-En-Api-Key: <secret>`, as an
alternative to `Authorization: Bearer <secret>`. Both headers authenticate against the same
`EN_API_KEYS_READ_WRITE` and `EN_API_KEYS_READ_ONLY` entries with the same roles, the same
constant-time comparison and the same caller header. Bearer stays the default and the documented
form; the new header exists for callers behind a proxy that consumes `Authorization` for its own
authentication. The OpenAPI document declares the second scheme so a client can discover it.


## Why

Nagare runs En inside each context's single-node Kubernetes cluster as a ClusterIP Service in
`nagare-system`, deliberately unreachable from outside the cluster. Its CLI writes and observes
every reviewed access relationship (a user's or team's grant on a site, a team membership) through
`kubectl port-forward svc/en`, one forward per call. Spawning the forward costs about 0.9 s before
the first request, and the CLI carries readiness parsing, reopen and termination logic for it.
That cost is part of
`mori://shinzui/nagare/okf/bug-reports/concepts/BUG-8`, where one reviewed access change took
about two minutes.

The Kubernetes API server already offers the alternative: it proxies HTTP requests to a Service at
`/api/v1/namespaces/nagare-system/services/en:80/proxy/<path>`, authenticated with the caller's
kubeconfig identity and gated by RBAC on `services/proxy`. A read-only probe from the operator's
workstation on 2026-10-22, using the context's kubeconfig client certificate, reached En that way in
0.10 to 0.12 s per request:

```text
GET .../services/en:80/proxy/v1/schema                 -> 401 from En in 0.104 s
GET .../services/en:80/proxy/v1/schema  (bogus bearer)  -> 401 from En in 0.108 s
GET .../services/en:80/proxy/v1/openapi.json  x3        -> 401 from En in 0.107 s, 0.108 s, 0.121 s
```

Every answer was En's own problem document, `"detail":"missing or invalid API key"`, including
the request that carried a bearer token. The API server removes the header before proxying:
`k8s.io/apiserver/pkg/endpoints/filters/authentication.go`, in `withAuthentication`, after a
successful authentication:

```go
// authorization header is not required anymore in case of a successful authentication.
req.Header.Del("Authorization")
```

En reads its key only from that header (`en-server/app/Middleware.hs`, `authenticate` and
`bearerSecret`), so no change on the Nagare side alone can carry the key through the proxy.

The alternative of exposing En on the operator's tailnet was rejected on the Nagare side: the
host firewall trusts the Tailscale interface wholesale, so a host port, a subnet route or the
Tailscale Kubernetes operator would make En's write API reachable by every tailnet device with
only its API key as the gate, where the API server keeps a client certificate and RBAC in front.
A second header is the smaller and safer change.


## Proposed behaviour

- `authenticate` looks for the secret in `Authorization: Bearer <secret>` and in
  `X-En-Api-Key: <secret>`. A request with exactly one of them authenticates against the key list
  as today. A request with both authenticates only when both present the same key; otherwise it is
  unauthenticated. The caller header, the read-only refusal of write requests and the exempt health
  probes are unchanged.
- The 401 problem response is unchanged, including `WWW-Authenticate: Bearer`.
- `withSecurityScheme` declares `apiKeyAuth` (`type: apiKey`, `in: header`, `name: X-En-Api-Key`)
  beside `bearerAuth`, and every authenticated operation's `security` lists the two as alternatives.
  `docs/api/openapi.json` is regenerated; the en-servant test that asserts exactly `bearerAuth`
  asserts both.
- The server documentation's "Authentication, rate limiting, and TLS" section documents the header,
  when to use it, and that a secret in a header is as sensitive as a bearer token.

Not asked: a key in the query string, a change to key roles or key configuration, or a change to
`en-client`, whose callers set headers themselves.


## Consumer

`mori://shinzui/nagare/plans/216-reach-en-through-the-api-server-s-service-proxy-instead-of-a-port-forward`
is held behind this request: once an En release with the header is pinned by Nagare's auth plane
and rolled onto a context, nagarectl sends `X-En-Api-Key` to the API server's service proxy and
stops spawning `kubectl port-forward` for En. nagarectl will check
`components.securitySchemes.apiKeyAuth` in `/v1/openapi.json` before using the header and refuse
with a reason that names this request when it is absent.
