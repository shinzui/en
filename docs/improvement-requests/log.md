# Bundle Update Log

## 2026-11-13

* **Update**: IR-2 completed under docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md: tenants selected by key, one database per tenant, per-tenant lifecycle, fault containment and observability, with no single-tenant regression. AC-2 holds in a narrower form until docs/plans/78-refuse-writes-of-tuples-the-active-schema-cannot-interpret.md lands; AC-6's readiness wording differs per ADR 10.

* **Update**: IR-2 accepted at gate G0 (single-tenant use must pay no performance tax) and in progress under docs/masterplans/12-serve-several-isolated-tenants-from-one-en-server.md

## 2026-11-12
* **Addition**: Propose IR-2 from mori://shinzui/mori: serve several isolated tenants (schema, datastore, keys, tokens, grant generation, changes feed) from one en-server, selected by the caller's key, so the Nagare platform En can host an application's model such as Mori's registry model beside its own.

## 2026-10-28
* **Update**: Accept IR-1 and plan it in docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md: the change replaces only the credential-parsing body of en-server's authentication middleware, uses OpenAPI's first-class apiKey-in-header scheme, and adds no configuration or key tier. The plan fixes the agreement rule for a request that carries both headers and keeps Bearer as the default and the 401 challenge.

## 2026-10-22
* **Addition**: Create the Improvement Request bundle on the `coordination.improvementRequests` profile from okf-profiles v0.12.0 and propose IR-1 from `mori://shinzui/nagare`: accept the API key in `X-En-Api-Key` beside `Authorization: Bearer`, because the Kubernetes API server's service proxy deletes the Authorization header after authenticating the caller, which keeps Nagare on a `kubectl port-forward` per En call.
