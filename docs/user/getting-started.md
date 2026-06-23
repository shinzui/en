# Getting Started

This guide shows the embedded-library path: define a schema in Haskell, compile
it, write relationship tuples through a store, and ask authorization questions.
Examples assume `OverloadedStrings`.

## 1. Define object and relation names

`en` does not ship a built-in authorization model. Your application defines
object types and relations as values.

```haskell
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)

import En.Schema
import En.Tuple
import En.Reachability (compile)
import En.Revision (Consistency (MinimizeLatency))
import En.Check (CheckDecision (..), check)

userType, spaceType :: ObjectType
userType = ObjectType "user"
spaceType = ObjectType "space"

viewer, view :: RelationName
viewer = RelationName "viewer"
view = RelationName "view"

userSubject :: Set.Set AllowedSubject
userSubject =
    Set.singleton AllowedSubject{objectType = userType, relation = Nothing}
```

## 2. Build a schema

A direct relation uses `This`; a permission usually computes over one or more
relations.

```haskell
schema :: Schema
schema =
    Schema
        { objectTypes =
            Map.fromList
                [ (userType, Map.empty)
                ,
                    ( spaceType
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
                        , relationEntry "view" Set.empty (ComputedUserset viewer)
                        ]
                    )
                ]
        , caveats = Map.empty
        }

relationEntry :: Text -> Set.Set AllowedSubject -> Rewrite -> (RelationName, Relation)
relationEntry name allowedSubjects rewrite =
    ( RelationName name
    , Relation
        { relationName = RelationName name
        , allowedSubjects = allowedSubjects
        , rewrite = rewrite
        }
    )
```

`viewer` accepts direct `user` subjects. `view` accepts no direct tuples; it is
a permission computed from `viewer`.

## 3. Validate and compile the schema

Compile once at startup and fail fast if the schema is invalid.

```haskell
graph <- either (fail . show) pure (compile schema)
```

`compile` runs schema validation before building the `ReachabilityGraph` used by
`check`, `lookup`, and `expand`.

## 4. Write relationship tuples

Tuple writes are performed through a `TupleStore`. PostgreSQL users normally
construct one with `En.Postgres.TupleStore.postgresTupleStoreIO`; tests can
provide their own in-memory `TupleStore`.

```haskell
alice, planning :: ObjectRef
alice = ObjectRef{objectType = userType, objectId = "alice"}
planning = ObjectRef{objectType = spaceType, objectId = "planning"}

grant :: Tuple
grant =
    Tuple
        { object = planning
        , relation = viewer
        , subject = SubjectId alice
        , caveat = Nothing
        }

token <- tupleStore.writeTuples [grant]
```

The returned `ConsistencyToken` can be supplied to later reads with
`AtLeastAsFresh token` for read-your-writes behavior.

## 5. Check access

```haskell
let context = CaveatContext Map.empty

decision <-
    check
        consistencyStore
        tupleStore
        graph
        MinimizeLatency
        context
        (SubjectId alice)
        view
        planning

case decision of
    Right Allowed -> putStrLn "allow"
    Right Denied -> putStrLn "deny"
    Right (Conditional obligations) -> print obligations
    Left err -> print err
```

Use `Allowed` as the only successful authorization result. `Denied` and
`Conditional` should both fail closed at the request boundary unless your caller
can supply the missing caveat context and retry.

## 6. Next steps

- Add parent or container relations with `TupleToUserset`.
- Use `lookup` to protect list endpoints without doing one `check` per row.
- Use `expand` to build review and audit views that explain who can access an
  object.
- Move from an in-memory test store to `en-postgres` before serving real traffic.
