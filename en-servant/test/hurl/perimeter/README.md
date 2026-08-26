# Authentication perimeter suite

This opt-in suite requires an `en-server` configured with separate read-write and
read-only API keys. From the repository's Nix development shell, start the ordinary
PostgreSQL service and then start an isolated server on port 18081:

```bash
just process-up
EN_PORT=18081 \
  EN_DATABASE_URL="$PG_CONNECTION_STRING" \
  EN_API_KEYS_READ_WRITE='writer:writer-secret-0123456789' \
  EN_API_KEYS_READ_ONLY='reader:reader-secret-0123456789' \
  EN_TELEMETRY_ENABLED=false \
  cabal run en-server
```

In a second shell, inject every credential through Hurl's secret channel:

```bash
cd en-servant/test/hurl
hurl --test --variables-file vars.env \
  --variable base_url=http://127.0.0.1:18081 \
  --secret api_key='writer-secret-0123456789' \
  --secret read_only_api_key='reader-secret-0123456789' \
  --secret invalid_api_key='invalid-secret-0123456789' \
  perimeter/perimeter.hurl
```

The suite proves that probes remain public; missing and invalid credentials receive 401;
a valid read-write credential succeeds; and a read-only credential receives 403 on a write.
It does not mutate state: the only write-shaped request is refused by authorization before
the handler runs. `en-server` currently serves no CORS headers, so there is no CORS contract
for this suite to assert.

Hurl redacts the supplied values from diagnostics by exact matching, but it does not rewrite
HTTP response bodies. Do not publish raw response reports from a perimeter run without
treating them as potentially sensitive.
