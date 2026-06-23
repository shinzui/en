# GraphQL Integration

`en` integrates with GraphQL as an authorization dependency behind resolvers. It
does not generate a GraphQL schema and should not be exposed directly to browser
clients. A GraphQL gateway, backend-for-frontend, or resource-owning service
should call `check`, `lookup`, and `expand` at the same boundaries where it
loads protected data.

Use this shape when GraphQL is in front of many services:

```text
client
  -> GraphQL gateway or BFF
      -> request identity from authentication
      -> en check / lookup / batch helper
      -> resource GraphQL services
          -> service databases
```

`en` remains the centralized relationship graph. The GraphQL layer remains the
composition layer. Domain services remain the source of truth for their own
objects and write the tuples that reflect domain changes.

## Enforcement boundaries

Do not make every resolver in every downstream service call `en` again for the
same user-to-object decision. That creates latency fan-out and makes a single
GraphQL query multiply into many authorization queries.

Prefer this rule:

- The GraphQL gateway or BFF enforces authorization for composed user-facing
  reads.
- The resource-owning service enforces authorization for direct protected
  reads and mutations that it owns.
- Downstream services trust narrowed requests from an already-authorized
  service unless they independently own another protected resource.

For example, a GraphQL `document(id:)` resolver should check whether the caller
can view `document:roadmap`. A thumbnail resolver nested under that document
should not repeat the same check unless thumbnails are independently exposed as
protected objects.

## Request context

Create a request-scoped authorization environment after authentication:

```haskell
data GraphQLAuthz m = GraphQLAuthz
    { checkPermission ::
        Subject ->
        RelationName ->
        ObjectRef ->
        m CheckDecision
    , lookupObjects ::
        Subject ->
        RelationName ->
        ObjectType ->
        LookupLimit ->
        Maybe LookupCursor ->
        m LookupPage
    , checkMany ::
        [AuthzCheck] ->
        m [CheckDecision]
    }
```

`checkMany` is an application helper. `en` currently exposes single `check` and
`lookup` operations, so production GraphQL callers that need many decisions
should add a small batching layer around `check`. Resolve consistency once,
deduplicate identical checks, run bounded concurrency, and map the results back
to the original fields.

A native server-side `BatchCheck` is planned (MasterPlan 3 EP-19,
`docs/plans/19-add-batchcheck-for-graphql-field-capability-and-candidate-filtering.md`): it evaluates
many `(subject, permission, object)` pairs under one resolved revision with shared subproblem
memoization, so a GraphQL field-capability batch becomes one request instead of N round-trips. Until it
lands, the client-side batching layer above — combined with the per-revision decision cache
(MasterPlan 2 EP-11) — keeps `checkMany` correct, at the cost of N round-trips.

A practical request context includes:

- The authenticated `Subject`, usually `SubjectId (ObjectRef (ObjectType "user") userId)`.
- The `CaveatContext` derived from trusted request data.
- The selected `Consistency`, usually `MinimizeLatency` or `AtLeastAsFresh token`.
- A request-scoped cache keyed by subject, permission, object, caveat context,
  schema hash, and resolved revision.
- Bounded deadlines and maximum batch sizes.

Treat `Allowed` as the only successful authorization result. Treat `Denied`,
`Conditional`, timeouts, and engine errors as not allowed unless the resolver
can supply missing caveat context and retry.

## Object resolvers

Use `check` when the resolver already knows the object id.

```graphql
type Query {
  document(id: ID!): Document
}

type Mutation {
  updateDocument(id: ID!, input: UpdateDocumentInput!): Document
}
```

The resolver shape is:

```text
Query.document(id)
  -> check user view document:id
  -> if Allowed, fetch document from document service
  -> otherwise return not found or forbidden according to product semantics

Mutation.updateDocument(id, input)
  -> check user edit document:id
  -> if Allowed, call document service mutation
  -> otherwise fail closed
```

For object detail reads, `check` is clearer and cheaper than `lookup`: the
question is "can this subject perform this action on this object?"

## List resolvers

Use `lookup` when the resolver needs a list of objects the subject can reach.
Then pass the returned ids, space ids, page ids, folders, or labels to the
owning service as a database predicate.

```graphql
type Query {
  documents(spaceId: ID, first: Int, after: String): DocumentConnection!
  activity(spaceId: ID, first: Int, after: String): ActivityConnection!
}
```

The preferred resolver shape is:

```text
Query.documents
  -> lookup user view page
  -> keep Allowed page ids
  -> call document service with page_id IN (:authorized_pages)
  -> page and sort in the document database

Query.activity
  -> lookup user view space or visibility_class
  -> keep Allowed ids
  -> call activity service with indexed filters
  -> page and sort in the activity database
```

Do not write every document or activity row into `en` just so GraphQL can list
them. Store high-volume rows in the owning service. Store the slow-changing
authorization graph in `en`: memberships, groups, sharing grants, parent links,
delegations, and container labels.

If the reachable set is too large for `lookup`, switch the resolver to one of
these shapes:

- Fetch a database page of candidates and run `checkMany` on the candidates.
- Maintain a materialized authorization projection in the owning service.
- Use a coarser reachable label such as space, folder, queue, or visibility
  class, then filter by that label in the service database.

Cursor-based pagination works better than offset pagination when a resolver
post-filters candidates with `checkMany`, because the database does not know
the offset of the next authorized result.

`en`'s `lookup` cursor is an opaque string: pass it straight through as the Relay connection `after`
argument and return it as `endCursor`. The resumable-cursor work in MasterPlan 3 EP-16
(`docs/plans/16-make-lookup-streaming-with-resumable-cursors-and-a-deadline-budget.md`) makes that
continuation stable across pages and under a deadline budget, which is what a Relay connection needs.

## Field-level permissions

Some GraphQL fields are data-dependent capabilities:

```graphql
type Document {
  id: ID!
  title: String!
  body: String!
  canEdit: Boolean!
  canShare: Boolean!
  canDelete: Boolean!
}
```

Do not let every `canX` field issue its own service call. Collect field
permission checks through the request-scoped `checkMany` helper:

```text
document.canEdit  -> enqueue check user edit document:id
document.canShare -> enqueue check user share document:id
document.canDelete -> enqueue check user delete document:id
flush -> run one bounded batch -> fill field values
```

This is the GraphQL version of the same pattern used by ReBAC systems for UI
tables and dashboards: batch checks for many object-permission pairs under one
request budget.

For sensitive fields, prefer checking before resolving the field value instead
of resolving the value and dropping it later. Avoid logging denied field values
or including them in downstream requests.

## GraphQL directives

Directives are useful as schema metadata, but they should call ordinary
application authorization code. They should not become a second policy language.

```graphql
directive @requiresPermission(
  objectType: String
  idArg: String = "id"
  permission: String!
) on FIELD_DEFINITION

directive @authzList(
  objectType: String!
  permission: String!
) on FIELD_DEFINITION
```

Example:

```graphql
type Query {
  document(id: ID!): Document
    @requiresPermission(objectType: "document", permission: "view")

  documents(first: Int, after: String): DocumentConnection!
    @authzList(objectType: "page", permission: "view")
}
```

Keep directive behavior simple:

- `@requiresPermission` maps to `check`.
- `@authzList` maps to `lookup` plus a service database filter.
- Field capability resolvers map to `checkMany`.
- Administrative "who can access this?" screens map to `expand`.

Treat authorization as deny-by-default. Every field that exposes a protected object must carry an
authz directive (or an explicit resolver check); a schema lint or CI check should fail the build when a
protected type is reachable through a field that has neither. Because the gateway is the authorization
chokepoint for composed reads — downstream services trust its narrowed requests — a forgotten
annotation is a silent data exposure, not a caught error.

Avoid directives that hide important domain decisions. For mutations, explicit
resolver code is often clearer because the authorization object may be derived
from multiple inputs or current database state.

## Service ownership

When `en` is centralized, tuple writes still belong to the domain service that
owns the fact.

Examples:

- Identity or group service writes `group:engineering#member@user:alice`.
- Space service writes `space:project-x#member@group:engineering#member`.
- Page service writes `page:child#parent@page:root`.
- Document service writes `document:roadmap#page@page:child`.
- Activity service stores activity rows in its own database and normally does
  not write one tuple per activity row.
- Sharing or invitation workflow writes `page:proposal#viewer@user:external`
  after the invited user accepts.

Write tuples transactionally with the domain change when possible. If that is
not possible, make tuple writes idempotent and run reconciliation from the
domain source of truth. Missing tuple writes should fail closed by producing
less access, not accidental access.

## Consistency after writes

Tuple writes return a `ConsistencyToken`. GraphQL mutations that change
relationships should carry that token into follow-up reads with
`AtLeastAsFresh`.

```text
Mutation.addGroupMember
  -> group service writes membership tuple
  -> return domain result plus en consistency token

Query.space
  -> use AtLeastAsFresh token when the client must observe the membership change
```

For ordinary GraphQL queries, prefer `MinimizeLatency`. Use `FullyConsistent`
only for operations that truly need the current head revision.

For a single GraphQL operation, keep consistency stable across related checks
where practical. Mixing different freshness requirements inside one response
can produce confusing UI behavior.

## Failure behavior

Protected resolvers must fail closed:

- `Allowed`: resolve the field or perform the mutation.
- `Denied`: return forbidden or not found according to product semantics.
- `Conditional`: retry only if the resolver can supply missing caveat context.
- Engine error or timeout: return an authorization error, not unfiltered data.

For list fields, decide empty-list semantics explicitly. It is often acceptable
for "no authorized results" and "no matching data" to both return an empty list.
It is not acceptable for an authorization failure to return unfiltered data.

## Checklist

- [ ] Authentication runs before GraphQL execution.
- [ ] Each GraphQL request has one `GraphQLAuthz` environment.
- [ ] Object resolvers use `check`.
- [ ] List resolvers use `lookup`, database filters, `checkMany`, or a
      projection.
- [ ] Field capability resolvers batch checks.
- [ ] Downstream services are not repeating the same authorization check at
      every hop.
- [ ] Domain services own tuple writes for their facts.
- [ ] Relationship-changing mutations return or preserve consistency tokens.
- [ ] Protected resolvers fail closed.
- [ ] Query depth, complexity, lookup limits, and batch sizes are bounded.
- [ ] Protected fields are deny-by-default: a schema lint or CI check fails when a protected type is
      exposed by a field with no authz directive or explicit check.
