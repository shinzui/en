# en User Docs

`en` is a schema-parametric relationship-based authorization toolkit for Haskell.
Use it when authorization depends on relationships between subjects and objects:
space membership, ownership, delegation, guest organizations, parent spaces, or
other graph-shaped grants.

These docs are for users integrating `en` into an application. Design rationale
and implementation plans live under [`docs/spec`](../spec) and [`docs/plans`](../plans).

## Start here

- [Getting started](getting-started.md): define a schema, compile it, write tuples,
  and call `check`.
- [Modeling authorization](modeling.md): choose object types, relations,
  permissions, usersets, caveats, and lookup-friendly schemas.
- [Queries and writes](queries-and-writes.md): use `check`, `lookup`, `expand`,
  consistency modes, tuples, and cursors.
- [Service and operations](service-and-operations.md): run the standalone server,
  use PostgreSQL, call the Servant API, and understand operational constraints.

## Mental model

An `en` authorization model has three pieces:

1. A `Schema` supplied by the consuming application, usually authored with
   `En.Schema.Builder`.
2. Relationship `Tuple`s stored in a `TupleStore`.
3. Read queries over a compiled `ReachabilityGraph`.

The most common query is:

```haskell
check consistencyStore tupleStore graph MinimizeLatency context subject permission object
```

It returns `Allowed`, `Denied`, or `Conditional obligations`. Treat
`Conditional` as not allowed until the missing caveat context has been supplied
and the query returns `Allowed`.

## Package map

| Package | Use it for |
| --- | --- |
| `en-core` | Schemas, tuples, consistency types, `check`, `lookup`, `expand`, and store effect interfaces |
| `en-postgres` | PostgreSQL-backed tuple store and `pg_snapshot` consistency token support |
| `en-servant` | Servant API types, handlers, and `requirePermission` helper |
| `en-server` | Standalone HTTP service with a built-in demo schema |
| `en-client` | Typed Haskell client for the standalone service |

## Current status

The project is experimental. The core model, in-memory-style effect boundary,
PostgreSQL tuple store, Servant API, and demo server exist, but the public API
should still be treated as pre-1.0. Prefer compiling and validating your schema
at application startup so schema mistakes fail before serving traffic.
