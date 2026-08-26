#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

hurlfmt --check \
  health.hurl \
  openapi.hurl \
  checks.hurl \
  lookups.hurl \
  expands.hurl \
  schema.hurl \
  relationships.hurl \
  perimeter/perimeter.hurl

hurl --test --variables-file vars.env \
  --variable base_url="${EN_SERVER_URL:-http://127.0.0.1:8080}" \
  --secret api_key="${EN_API_KEY:-dev-secret-0123456789}" \
  health.hurl \
  openapi.hurl \
  checks.hurl \
  lookups.hurl \
  expands.hurl \
  schema.hurl
