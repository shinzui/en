processComposeSocket := ".dev/process-compose.sock"

# Show available recipes
default:
  just --list

# Start local process-compose services without TUI
[group("services")]
process-up:
  process-compose --tui=false --unix-socket {{processComposeSocket}} up --detached
  @for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
      if pg_ctl status -D "$PGDATA" >/dev/null 2>&1; then exit 0; fi; \
      sleep 1; \
    done; \
    pg_ctl status -D "$PGDATA"

# Stop local process-compose services
[group("services")]
process-down:
  process-compose --unix-socket {{processComposeSocket}} down || true

# Start the standalone en server against the configured database
#
# Authentication is required unless EN_AUTH_DISABLED=true. Configure callers with
# EN_API_KEYS_READ_WRITE / EN_API_KEYS_READ_ONLY (comma-separated name:secret entries,
# secrets at least 16 bytes); throttle them with EN_RATE_LIMIT_RPS / EN_RATE_LIMIT_BURST.
# All are inherited from the calling environment.
[group("services")]
start-server: run-migrations
  EN_DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run en-server

# Wait for the process-compose en-server to be healthy, then run the HTTP smoke test
#
# process-compose owns the server (see process-compose.yaml); this waits on the same
# /health/live the orchestrator's liveness probe uses rather than spawning a second
# server on the same port.
[group("services")]
start-and-test: process-up
  @set -eu; \
    url="${EN_SERVER_URL:-http://localhost:${EN_PORT:-8080}}"; \
    ready=0; \
    for _ in $(seq 1 60); do \
      if curl -fsS -o /dev/null "$url/health/live" 2>/dev/null; then ready=1; break; fi; \
      sleep 2; \
    done; \
    if [ "$ready" -ne 1 ]; then \
      echo "en-server never answered GET /health/live with 200; last log lines:" >&2; \
      process-compose --unix-socket {{processComposeSocket}} process logs en-server --tail 20 >&2 || true; \
      exit 1; \
    fi; \
    just test-server

# `en-migrate new` writes the file and appends it to the manifest atomically, so a
# migration can never exist unregistered -- there is no second step to forget.
#
# Arguments are positional, not `name=...`:
#
#   just make-migration 0002-add-watch-cursor "add the watch cursor column"
#   just make-migration "" "let pg-migrate number it"   # -> 0002.sql
#
# The name must continue the manifest's numbering; 0001-en-bootstrap.sql is taken.
# Never edit an applied file -- append a new one.
#
# Create a new migration file and register it in the ordered manifest
[group("database")]
make-migration name="" description="":
  cabal run -v0 en-migrate -- new \
    --manifest en-migrations/migrations/manifest \
    {{ if name == "" { "" } else { "--name " + name + ".sql" } }} \
    --description "{{ if description == "" { name } else { description } }}"

# Create database if it doesn't exist
[group("database")]
create-database:
  @psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -qx 1 || createdb "$PGDATABASE"

# Idempotent by construction: en-migrate consults the ledger and applies only what
# is pending, so this is safe to run on every start (process-compose does).
#
# Apply pending PostgreSQL migrations
[group("database")]
run-migrations: create-database
  DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run -v0 en-migrate -- up

# Exits 2 on a checksum mismatch or a missing/unknown migration, which is the
# pre-deploy check the old guarded-psql recipe could not offer.
#
# Compare the declared migration plan with the database's ledger
[group("database")]
verify-migrations:
  DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run -v0 en-migrate -- verify

# Show which migrations this database has and which are pending
[group("database")]
migration-status:
  DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run -v0 en-migrate -- status

# Run a write-token-check HTTP smoke test against a running en-server
[group("testing")]
test-server:
  @set -eu; \
    url="${EN_SERVER_URL:-http://localhost:${EN_PORT:-8080}}"; \
    auth="Authorization: Bearer ${EN_API_KEY:-dev-secret-0123456789}"; \
    curl -fsS -X POST "$url/v1/relationships/delete" \
      -H "$auth" \
      -H 'content-type: application/json' \
      -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"kind":"id","objectType":"user","objectId":"alice"},"caveat":null}]}' >/dev/null; \
    token=$(curl -fsS -X POST "$url/v1/relationships" \
      -H "$auth" \
      -H 'content-type: application/json' \
      -d '{"tuples":[{"object":{"objectType":"space","objectId":"project-x"},"relation":"viewer","subject":{"kind":"id","objectType":"user","objectId":"alice"},"caveat":null}]}' \
      | jq -r '.token'); \
    decision=$(curl -sS -X POST "$url/v1/check" \
      -H "$auth" \
      -H 'content-type: application/json' \
      -d "{\"consistency\":{\"mode\":\"atLeastAsFresh\",\"token\":\"$token\"},\"context\":{\"values\":{}},\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"permission\":\"view\",\"object\":{\"objectType\":\"space\",\"objectId\":\"project-x\"}}" \
      | jq -r '.decision.result'); \
    test "$decision" = "allowed"; \
    echo "server smoke test passed: $decision"

# The document is derived (never hand-written) by `cabal run en-openapi`. A red result
# means someone changed the API type and did not regenerate the checked-in artifact.
#
# Regenerate docs/api/openapi.json from the route types and fail if it drifted
[group("testing")]
openapi:
  cabal run -v0 en-openapi
  git diff --exit-code -- docs/api/openapi.json
