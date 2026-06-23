# en lookup read-filter spike

This is a throwaway measurement harness for `docs/spec/0002-lookup-spike.md`.
It starts an isolated PostgreSQL instance with `ephemeral-pg`, generates a
kikan-shaped low-cardinality relationship graph, generates a 1,000,000-row
synthetic `kawa_activity` stream, and measures:

- `lookup_labels(subject)` over the relationship graph.
- The intended indexed read-path query over the consumer activity table.
- The anti-pattern that treats activities as authorization objects and stops at
  a 1001-result cap.

Run it from the repository root:

```bash
cabal run en-lookup-spike
```

The command prints a markdown results table. The database is temporary and is
removed automatically when the process exits.
