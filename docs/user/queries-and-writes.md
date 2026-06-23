# Queries and Writes

This guide covers the runtime operations exposed by `en-core`: write tuples,
delete tuples, check access, list reachable objects, and expand access paths.

## Tuples

A tuple says a subject has a relation on an object:

```haskell
Tuple
    { object = ObjectRef (ObjectType "space") "planning"
    , relation = RelationName "owner"
    , subject = SubjectId (ObjectRef (ObjectType "user") "alice")
    , caveat = Nothing
    }
```

The subject can be:

- `SubjectId object`: a concrete subject such as `user:alice`.
- `SubjectSet object relation`: a userset such as `org:acme#member`.

Writes and deletes go through `TupleStore`:

```haskell
writeToken <- tupleStore.writeTuples [tuple]
deleteToken <- tupleStore.deleteTuples [tuple]
```

Each write returns a `ConsistencyToken`.

## Consistency modes

Every read takes a `Consistency`:

| Mode | Use when |
| --- | --- |
| `MinimizeLatency` | The default for most reads; uses an optimized cached revision and may be stale. |
| `AtLeastAsFresh token` | You need read-your-writes after a tuple write. |
| `AtExactSnapshot token` | You need to repeat a read at exactly the token's snapshot. |
| `FullyConsistent` | You need the freshest head revision and accept lower cacheability. |

For most request paths, prefer `MinimizeLatency` or `AtLeastAsFresh`. Reserve
`FullyConsistent` for cases that truly need head-of-database freshness.

## Check

`check` answers whether one subject has one permission on one object.

```haskell
check ::
    Monad m =>
    ConsistencyStore m ->
    TupleStore m ->
    ReachabilityGraph ->
    Consistency ->
    CaveatContext ->
    Subject ->
    RelationName ->
    ObjectRef ->
    m (Either EnError CheckDecision)
```

Results:

- `Allowed`: permit the operation.
- `Denied`: reject the operation.
- `Conditional obligations`: a path exists, but caveat context is missing.

At HTTP or handler boundaries, fail closed unless the caller can complete the
context and retry.

## Lookup

`lookup` lists objects of one object type that a subject can reach with a
permission. It is the read-filter primitive for list endpoints.

```haskell
Lookup.lookup
    consistencyStore
    tupleStore
    graph
    MinimizeLatency
    LookupRequest
        { subject = SubjectId user
        , permission = RelationName "view"
        , objectType = ObjectType "space"
        , context = requestContext
        , limit = LookupLimit 100
        , cursor = Nothing
        }
```

The result is a `LookupPage`:

```haskell
data LookupPage = LookupPage
    { objects :: [LookupObject]
    , state :: LookupState
    }
```

Each `LookupObject` carries the object and its `CheckDecision`. For ordinary
access filtering, keep `Allowed` results and treat `Conditional` as unresolved
until context is complete.

Use cursors until `LookupExhausted`:

- `LookupExhausted`: no more results.
- `LookupHasMore cursor`: request the next page with that cursor.
- `LookupTruncated cursor`: the engine hit a cap; use the visible page and
  continue only if your workflow can tolerate truncation.

The current implementation uses deterministic cursor text internally. Treat
cursor encodings as opaque.

## Expand

`expand` answers "who can reach this object permission?" as a bounded tree. Use
it for review, audit, and debugging UIs, not for hot-path authorization.

```haskell
Expand.expand
    consistencyStore
    tupleStore
    graph
    MinimizeLatency
    ExpandRequest
        { object = ObjectRef (ObjectType "space") "planning"
        , permission = RelationName "view"
        , context = requestContext
        , limit = ExpandLimit 100
        , cursor = Nothing
        }
```

The result tree has these node shapes:

- `ExpandSubject subject row`: a concrete subject.
- `ExpandUserset object relation children`: a userset edge and its expansion.
- `ExpandCaveated caveat children`: a caveated portion of the tree.

Like `lookup`, `expand` is paginated and bounded.

## Store interface

Custom stores implement `TupleStore`:

```haskell
data TupleStore m = TupleStore
    { readObjectRelation :: Revision -> ObjectRef -> RelationName -> Int -> Maybe StoreCursor -> m TuplePage
    , readStartingWithUser :: Revision -> UsersetQuery -> m TuplePage
    , writeTuples :: [Tuple] -> m ConsistencyToken
    , deleteTuples :: [Tuple] -> m ConsistencyToken
    , headRevision :: m Revision
    , optimizedRevision :: m Revision
    }
```

`readStartingWithUser` is the important reverse primitive. It returns objects of
`queryType` on `queryRelation` whose subject is one of `querySubjects`; both
`check` and `lookup` rely on it.

Read methods must respect the supplied `Revision`. Write methods must return a
token that can later be resolved by the paired `ConsistencyStore`.
