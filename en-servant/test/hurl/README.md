# en-server black-box API suite

This Hurl suite targets an already-running, PostgreSQL-backed `en-server` over a real
socket. It proves process startup, production middleware, authentication, serialization,
and the stable HTTP contract. Detailed domain behavior remains in the Haskell tests, and
the complete generated schema remains in `docs/api/openapi.json`.

## Local setup

Enter the repository's Nix development shell, which provides Hurl 8.0.1, then start the
supervised PostgreSQL and `en-server` processes and run the safe suite:

```bash
nix develop
just process-up
just hurl
```

`just hurl` targets an already-running server. It neither starts nor stops services. To
run the full local/CI lifecycle—start services, wait for `GET /health/ready`, then execute
the suite—use:

```bash
just start-and-test
just process-down
```

The tracked `vars.env` contains only the non-secret default
`base_url=http://127.0.0.1:8080`. Override the target without editing the file:

```bash
EN_SERVER_URL=http://127.0.0.1:18080 just hurl
```

The runner injects `${EN_API_KEY:-dev-secret-0123456789}` through Hurl's `--secret`
option. The fallback is the same local-only key published in `process-compose.yaml`; set
`EN_API_KEY` when targeting any other environment. Never add real credentials to
`vars.env`.

## Default read-only contract

`run.sh` formats every Hurl file but executes only these independent, read-only families:

- `health.hurl` — unauthenticated liveness and readiness probes;
- `openapi.hurl` — the live OpenAPI 3.1 document and the packaged 404 formatter;
- `checks.hurl` — check and batch-check plus malformed-body, unknown-relation, and method
  failures;
- `lookups.hurl` — lookup and lookup-subjects plus cursor rejection;
- `expands.hurl` — expand success and an unknown-permission failure; and
- `schema.hurl` — the active schema source and identity.

The default files share no captures or mutations and may run in parallel. Their only
schema precondition is the built-in demo model, or an equivalent model defining object
types `user` and `space`, relation `space#viewer: user`, and permission
`space#view = viewer`. They do not require any relationship tuple to exist: response
assertions pin types and stable fields rather than environment-specific row values.

Run one family while editing it:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env \
  --secret api_key="${EN_API_KEY:-dev-secret-0123456789}" \
  checks.hurl
```

## Opt-in flows

`relationships.hurl` is not in the default run list because it mutates authorization
state. It first proves a failed precondition returns 412 without changing state, then
deletes and writes the exact fixture
`space:hurl-write-flow#viewer@user:hurl-alice`, captures the write's consistency token,
and proves visibility through `POST /v1/check` at that token. The delete-first setup makes
the flow idempotent; it passes on consecutive runs and leaves that one tuple present until
the next run deletes it again.

Run it only against a disposable development or CI database:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env \
  --secret api_key="${EN_API_KEY:-dev-secret-0123456789}" \
  relationships.hurl
```

`perimeter/perimeter.hurl` requires a separately configured server with read-write and
read-only keys. It does not mutate state. See `perimeter/README.md` for the exact startup
and secret-injection commands.

Hurl redacts secret values from its diagnostics by exact matching, but does not alter
response bodies and may preserve them in reports. Treat raw reports as potentially
sensitive. The server must never echo a credential.

## Formatting and failure behavior

`run.sh` uses `set -euo pipefail`; an assertion or formatting failure makes `just hurl`
exit non-zero. Format files with `hurlfmt --in-place <file>` and verify all tracked cases
with `just hurl`. The CI workflow starts the packaged server, waits for readiness, retains
the server log on failure, and tears the local stack down even when an assertion fails.
