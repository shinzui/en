---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Accept the API key in a header the Kubernetes API server forwards](accept-the-api-key-in-a-header-the-kubernetes-api-server-forwards.md) - Let a caller present its En API key as `X-En-Api-Key` in addition to `Authorization: Bearer`, so a client that reaches En through the Kubernetes API server's service proxy, which deletes the Authorization header after authenticating the caller, can authenticate without a port-forward.

