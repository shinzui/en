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
  health.hurl \
  openapi.hurl \
  checks.hurl \
  lookups.hurl \
  expands.hurl \
  schema.hurl
