---
title: "only stored relationship listings use Relay keyset pagination"
status: accepted
date: 2026-08-26
authors: [shinzui]
related:
  - docs/plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md
  - docs/masterplans/11-bring-en-into-conformance-with-the-haskell-jitsurei-pattern-catalog.md
  - mori://shinzui/relay-pagination
  - mori://shinzui/haskell-jitsurei/docs/api-relay-pagination
---

# ADR 6 — only stored relationship listings use Relay keyset pagination

## Status

Accepted, 2026-08-26. Implemented by
[ExecPlan 67](../plans/67-adopt-relay-pagination-for-en-s-list-endpoints.md).

## Context

The fleet pagination pattern requires unbounded ordered collections to expose Relay
`Connection`, `Edge`, and `PageInfo` values; accept `first`/`after` or `last`/`before`; use a
total keyset order; and prove both directions with the released conformance walker.

Four en operations previously carried bespoke cursors: relationship query, object lookup,
subject lookup, and watch. They are not four instances of the same abstraction.
`POST /v1/relationships/query` scans stored rows in the unique `relation_tuple.id` order.
Lookup and lookup-subjects execute bounded graph traversals whose cursors preserve frontier
state and whose `truncated` outcome means evaluation stopped before a safe page boundary.
Watch is a forward-only changelog protocol whose cursor fixes and drains a half-open revision
window. Pretending those traversal and feed cursors were reversible keyset positions would
publish behavior the engines cannot truthfully provide.

Relationship pages must also remain on one authorization snapshot. A continuation cannot
re-resolve the consistency request in the POST body, because writes between pages could then
make one walk skip or duplicate grants.

## Decision

`POST /v1/relationships/query` is en's Relay keyset endpoint. Pagination controls live in
the query string through `RelayPage 20 100`; the relationship filter and initial consistency
request remain in the JSON body. Its success body is `Connection TupleWire`. Its cursor sort
keys are the minted consistency token followed by `relation_tuple.id`, ascending. The token
pins the snapshot and the non-null primary key makes the order total. Continuations validate
the cursor's token and ignore the body's consistency request.

Every 400 from this operation uses `RelayPageError`, including body-validation, expired-token,
and handler-detected cursor failures. This is an exact exception to en's RFC 9457 default;
412, 422, 500, and 503 remain problem documents. The OpenAPI conformance test names only this
route and status as the exception.

Lookup, lookup-subjects, and watch retain their existing protocols. Their unboundedness alone
does not make them Relay keyset collections: graph-traversal truncation and forward-only feed
windows are semantically significant and are not representable by Relay `PageInfo`.

## Consequences

The relationship-query wire contract is deliberately breaking. Generated Haskell clients now
pass a `ClientPage` before `ReadRelationshipsRequestWire` and receive
`RelationshipPageResult`; the old body `limit`/`cursor`, `RelationshipsStateWire`, and
`ReadRelationshipsResponseWire` are gone. Registered source consumers under
`mori://shinzui/nagare` and `mori://shinzui/kikan-en` use none of those symbols or the route,
so no cross-repository migration was required at adoption time.

The PostgreSQL implementation uses `relay-pagination-hasql` over the existing
`relation_tuple_pkey`; no duplicate index or schema migration is required. The in-memory
interpreter mints the same cursor payload, and a conformance test walks the actual WAI
application forward and backward to prove completeness, order, honest boundaries, cursor
determinism, and cursor/page-info agreement.

Adding Relay to another en endpoint requires proving that the endpoint is a reversible
keyset collection with a total order and no semantic state outside `PageInfo`. A cosmetic
cursor re-encoding is not sufficient. Every added endpoint also requires its own live
conformance walk and an exact 400 exemption.
