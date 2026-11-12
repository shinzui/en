---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Accept the API key in a header the Kubernetes API server forwards](accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md) - Let a caller present its En API key as `X-En-Api-Key` in addition to `Authorization: Bearer`, so a client that reaches En through the Kubernetes API server's service proxy, which deletes the Authorization header after authenticating the caller, can authenticate without a port-forward.
- [Serve several isolated tenants from one En server](serve-several-isolated-tenants-from-one-en-server.md) - Let one en-server process serve several tenants, each with its own schema, datastore, API keys, consistency tokens, grant generation and changes feed, selected by the caller's key, so a platform's En can host an application's authorization model beside its own without either tenant reading, writing or invalidating the other's state.
