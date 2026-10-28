# Bundle Update Log

## 2026-10-28
* **Update**: Accept IR-1 and plan it in docs/plans/71-accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md: the change replaces only the credential-parsing body of en-server's authentication middleware, uses OpenAPI's first-class apiKey-in-header scheme, and adds no configuration or key tier. The plan fixes the agreement rule for a request that carries both headers and keeps Bearer as the default and the 401 challenge.

## 2026-10-22
* **Addition**: Create the Improvement Request bundle on the `coordination.improvementRequests` profile from okf-profiles v0.12.0 and propose IR-1 from `mori://shinzui/nagare`: accept the API key in `X-En-Api-Key` beside `Authorization: Bearer`, because the Kubernetes API server's service proxy deletes the Authorization header after authenticating the caller, which keeps Nagare on a `kubectl port-forward` per En call.
