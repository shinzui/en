# Modeling Authorization

`en` models authorization with object types, relations, permissions, usersets,
and caveats. A good schema keeps the relationship graph small, slow-changing,
and easy for `lookup` to reverse.

## Object types

Define object types for principals and protected resources:

- `user`: a concrete authenticated principal.
- `org`: a group or external organization.
- `space`: a protected container.
- `visibility_class`: a label-like object that many spaces can point at.
- Domain resources such as `intention`, `conversation`, or `document`.

Use stable object ids from your application. `en` treats object ids as opaque
text.

## Relations vs permissions

Use direct relations for stored facts:

- `owner`
- `member`
- `parent`
- `guest_org`
- `delegate`
- `visibility_class`

Use computed relations as permissions:

- `view`
- `act`
- `audit`
- `admin`

Permissions usually have `allowedSubjects = Set.empty` because callers should
not write direct tuples to them. Instead, the permission rewrites over stored
relations.

```haskell
import En.Schema.Builder qualified as Schema

Schema.permission
    "view"
    ( Schema.anyOf
        (Schema.computed "owner")
        [ Schema.computed "member"
        , Schema.arrow "guest_org" "member"
        , Schema.arrow "parent" "view"
        ]
    )
```

This says a subject can view a space if they are an owner, a member, a member of
a guest org attached to the space, or can view a parent space.

## Direct subjects and userset subjects

`AllowedSubject` controls what shapes may appear in direct tuples:

```haskell
Schema.relation "owner" [Schema.subject "user"] Schema.this
Schema.relation "member" [Schema.subject "user", Schema.userset "org" "member"] Schema.this
```

`Schema.subject "user"` accepts concrete subjects such as `user:alice`.
`Schema.userset "org" "member"` accepts userset subjects such as
`org:acme#member`.

Use userset subjects when membership in another object should grant access:

```haskell
Tuple
    { object = ObjectRef (ObjectType "space") "guest-space"
    , relation = RelationName "member"
    , subject = SubjectSet (ObjectRef (ObjectType "org") "agency") (RelationName "member")
    , caveat = Nothing
    }
```

Any user in `org:agency#member` is now treated as a member of `space:guest-space`.

## Rewrite choices

Prefer these rewrites:

- `This`: direct tuples on the current relation.
- `ComputedUserset`: another relation on the same object.
- `TupleToUserset`: follow a relation to another object, then evaluate a
  relation on that object.
- `Union`: any branch grants access.

Use these carefully:

- `Intersection`: every branch must match; `lookup` must confirm candidates.
- `Exclusion`: base branch minus subtract branch; `lookup` must confirm
  candidates.
- `Caveated`: grants are conditional on bounded context.

`check` handles all rewrites. `lookup` is fastest and easiest to reason about
when permissions are shallow and mostly union-shaped.

## Caveats

Caveats are bounded request-time gates, not a general policy language. They are
declared in the schema and attached to tuple or rewrite paths.

The current built-in evaluator recognizes the `within_autonomy` tuple caveat:

- Tuple payload key `autonomy`: granted level, as a `ValueEnum`.
- Tuple payload key `until`: optional expiry, as a `ValueTimestamp`.
- Request context key `requested_autonomy`: requested level, as a `ValueEnum`.
- Request context key `current_time`: required when `until` is present.

Autonomy levels rank as `read < act < admin`; unknown enum values are treated as
the lowest rank.

```haskell
schema :: Schema
schema =
    Schema.buildWithCaveats
        [ Schema.caveat
            "within_autonomy"
            [ Schema.parameter "requested_autonomy" (ParameterEnum ["read", "act", "admin"])
            , Schema.parameter "until" ParameterTimestamp
            ]
        ]
        [ Schema.object
            "intention"
            [ Schema.relation "delegate" [Schema.subject "user"] (Schema.caveated "within_autonomy" Schema.this)
            , Schema.permission "view" (Schema.computed "delegate")
            ]
        ]

TupleCaveat
    { name = CaveatName "within_autonomy"
    , payload =
        CaveatPayload
            ( Map.fromList
                [ ("autonomy", ValueEnum "act")
                , ("until", ValueTimestamp expiry)
                ]
            )
    }
```

When required context is missing, `check` and `lookup` return `Conditional`
with the missing keys. Callers should fail closed or retry with complete
context.

The raw constructors in `En.Schema` remain available for advanced callers and
tests that intentionally construct invalid schemas. Application schemas should
prefer `En.Schema.Builder` so relation map keys, relation records, and allowed
subject sets are assembled consistently.

## Lookup-friendly modeling

Use `en` for the low-cardinality relationship graph: memberships, ownership,
delegations, parent links, and other facts that change on human or agent
actions.

Do not put high-cardinality, high-churn resource facts into `en` just so they
can be queried. For example, if a service has millions of activity rows, store
activity visibility labels in that service's own indexed table, not as `en`
tuples. Then use this pattern:

1. Call `lookup` for the small reachable label set, such as spaces or visibility
   classes.
2. Apply that result as a predicate in the owning service's query.

That keeps `en.lookup` bounded and avoids an N+1 `check` across every row.

## Validation rules worth knowing

`validate` and `compile` reject schemas that have:

- `This` relations without any allowed subjects.
- References to missing relations or caveats.
- Empty `Union` or `Intersection` branches.
- `TupleToUserset` arrows whose target object types do not define the computed
  relation.
- Rewrite cycles with no productive direct `This` base.
