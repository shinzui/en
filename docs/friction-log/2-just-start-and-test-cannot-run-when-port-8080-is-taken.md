---
type: Friction Entry
title: "just start-and-test cannot run when port 8080 is taken"
description: "The start-and-test recipe and the process-compose en-server assume port 8080; with another process on 8080 the Hurl suite hits the wrong server, and EN_PORT alone does not move the Hurl base URL (EN_SERVER_URL does), nor the process-compose readiness probe."
generated:
  by: "claude-code/claude-opus-5-5"
  at: "2026-11-13T14:34:46Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/en"
affects: "mori://shinzui/en"
plan: "docs/plans/73-serve-tenants-selected-by-api-key-each-from-its-own-isolated-stack.md"
workaround: "Started the built en-server by hand on port 18181 with the process-compose environment and ran EN_SERVER_URL=http://127.0.0.1:18181 just hurl (6/6 files passed)"
resolution: "Local port collision on a working desktop; the workaround (start the built server on a free port and run EN_SERVER_URL=... just hurl) is recorded. Making start-and-test honour EN_PORT end to end is outside the tenancy initiative and has not recurred under another plan."
amended:
  - by: "claude-code/claude-opus-5-5"
    at: "2026-11-13T19:20:47Z"
    change: "Status set to accepted."
---
# just start-and-test cannot run when port 8080 is taken

## Attempted

Run just start-and-test to prove the Milestone 1 refactor left the black-box API unchanged

## Encountered

Every Hurl file failed with 404 because an Apple container process listened on 127.0.0.1:8080; with EN_PORT=18080 and EN_SERVER_URL set, /health passed but /v1 routes still answered 404 under process-compose

## Workaround

Started the built en-server by hand on port 18181 with the process-compose environment and ran EN_SERVER_URL=http://127.0.0.1:18181 just hurl (6/6 files passed)
