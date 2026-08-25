# Getting Started

This guide starts with the embedded-library path: define a schema in Haskell,
compile it, write relationship tuples through a store, and ask authorization
questions. It also shows how to run the standalone `en-server` from a text
schema file. Examples assume `OverloadedStrings`.

## 1. Define object and relation names

`en` does not ship a built-in authorization model. Your application defines
object types and relations as values.

```haskell
import Data.Map.Strict qualified as Map

import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Effect.TupleStore (writeTuples)
import En.Error (EnError)
import En.Reachability (compile)
import En.Revision (Consistency (AtLeastAsFresh))
import En.Schema (ObjectType (..), RelationName (..), Schema, validateSchema)
import En.Schema.Builder qualified as Schema
import En.Store.InMemory (newInMemoryWorld, runInMemoryStores)
import En.Tuple

userType, spaceType :: ObjectType
userType = ObjectType "user"
spaceType = ObjectType "space"

viewer, view :: RelationName
viewer = RelationName "viewer"
view = RelationName "view"
```

## 2. Build a schema

A direct relation uses `Schema.this`; a permission computes over one or more
relations.

```haskell
schemaResult :: Either EnError Schema
schemaResult = do
    user <- Schema.object "user" []
    space <-
        Schema.object
            "space"
            [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
    Schema.build [user, space]
```

`viewer` accepts direct `user` subjects. `view` accepts no direct tuples; it is
a permission computed from `viewer`. Use `Schema.relation` with allowed subjects
for writable base relations, and use `Schema.permission` with
`Schema.computed`, `Schema.arrow`, `Schema.anyOf`, or the other rewrite
constructors for computed rules. A permission cannot be a bare `Schema.this`;
that always-invalid shape is rejected by the builder API.

## 3. Validate and compile the schema

Compile once at startup and fail fast if the schema is invalid.

```haskell
schema <- either (fail . show) pure schemaResult
validSchema <- either (fail . show) pure (validateSchema schema)
let graph = compile validSchema
```

`compile` runs schema validation before building the `ReachabilityGraph` used by
`check`, `lookup`, and `expand`.

## 4. Create a test store and write relationship tuples

Tuple writes are performed through the `TupleStore` effect. For a test or a
databaseless demo, create one mutable world and install both of its store
interpreters with `runInMemoryStores`:

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

world <- newInMemoryWorld
```

The world is process-local. It is not a production store: it is not durable,
separate application instances cannot agree on it, and its revision counter only
models PostgreSQL snapshot semantics inside one process. Use `en-postgres` before
serving real traffic.

## 5. Check access

Run writes and authorization queries in one effect program over that world:

```haskell
let context = CaveatContext Map.empty

result <-
    runEff
        . runErrorNoCallStack
        . runInMemoryStores world
        $ do
            token <- writeTuples [grant]
            CheckOutcome{decision} <-
                check
                    graph
                    (AtLeastAsFresh token)
                    context
                    (SubjectId alice)
                    view
                    planning
            pure decision

case result of
    Right Allowed -> putStrLn "allow"
    Right Denied -> putStrLn "deny"
    Right (Conditional obligations) -> print obligations
    Left err -> print err
```

`writeTuples` returns a `ConsistencyToken`. Passing it to `AtLeastAsFresh`
gives the check read-your-writes behavior.

Use `Allowed` as the only successful authorization result. `Denied` and
`Conditional` should both fail closed at the request boundary unless your caller
can supply the missing caveat context and retry.

## 6. Run the standalone server from a schema file

For non-Haskell callers or a shared HTTP boundary, put the same model in a text
schema file and point `en-server` at it with `EN_SCHEMA_PATH`:

```shell
cat > /tmp/blog.en <<'EOF'
object user {}

object post {
  relation author: user
  relation reader: user, user:*
  permission view = author | reader
  permission edit = author
}
EOF

EN_DATABASE_URL='postgresql://user@localhost:5432/en' \
EN_SCHEMA_PATH=/tmp/blog.en \
  en-server
```

At startup the server logs the loaded path and schema hash:

```text
Loaded schema from /tmp/blog.en
Schema hash: fnv1a64:...
```

If the file cannot be read, parsed, or validated, startup exits non-zero before
serving traffic. If `EN_SCHEMA_PATH` is unset, the server warns and uses the
built-in demo schema for local smoke tests.

## 7. Next steps

- Add parent or container relations with `Schema.arrow`.
- Use `lookup` to protect list endpoints without doing one `check` per row.
- Use `expand` to build review and audit views that explain who can access an
  object.
- Move from an in-memory test store to `en-postgres` before serving real traffic.
