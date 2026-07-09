migrationDate := `date -u '+%Y%m%d%H%M%S'`
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
# /healthz the orchestrator's readiness probe uses rather than spawning a second
# server on the same port.
[group("services")]
start-and-test: process-up
  @set -eu; \
    url="${EN_SERVER_URL:-http://localhost:${EN_PORT:-8080}}"; \
    ready=0; \
    for _ in $(seq 1 60); do \
      if curl -fsS -o /dev/null "$url/healthz" 2>/dev/null; then ready=1; break; fi; \
      sleep 2; \
    done; \
    if [ "$ready" -ne 1 ]; then \
      echo "en-server never answered GET /healthz with 200; last log lines:" >&2; \
      process-compose --unix-socket {{processComposeSocket}} process logs en-server --tail 20 >&2 || true; \
      exit 1; \
    fi; \
    just test-server

# Create new migration file with timestamp
[group("database")]
make-migration name:
  touch en-migrations/db/migrations/{{migrationDate}}_{{name}}.sql

# Create database if it doesn't exist
[group("database")]
create-database:
  @psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -qx 1 || createdb "$PGDATABASE"

# Apply local PostgreSQL migrations
[group("database")]
run-migrations: create-database
  @if [ "$(psql "$PG_CONNECTION_STRING" -tAc "SELECT to_regclass('public.relation_tuple') IS NOT NULL")" = "f" ]; then \
      psql "$PG_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f en-migrations/db/migrations/20260623044157_create-relation-tuples.sql; \
    else \
      echo "base migration already applied"; \
    fi
  @if [ "$(psql "$PG_CONNECTION_STRING" -tAc "SELECT to_regclass('public.relation_tuple_object_hist_idx') IS NOT NULL")" = "f" ]; then \
      psql "$PG_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f en-migrations/db/migrations/20260623160000_historical-read-indexes.sql; \
    else \
      echo "historical-read indexes already applied"; \
    fi

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
