# Capability Catalog Log

## 2026-08-24

* **Adoption**: Authored the initial profile-governed capability catalog for `en` under the
shared `coordination.capabilities` profile (okf-profiles v0.12.0, OKF v0.2). Twenty-five
capabilities (CAP-1..CAP-25) were derived from the package descriptions and exposed modules, the
six test suites and the conformance suite, the benchmarks and the lookup spike, the user guides
under `docs/user`, the ADRs under `docs/adr`, and the embedded migration component — each backed
by at least one openable artifact. Registered the `capabilities` bundle in `mori.dhall`, which
required bumping the `mori-schema` pin to the revision that carries `OkfBundle`.

The catalog records **provision, not composition**: `en-example` is a worked host rather than a
consumer-facing package, so it appears as evidence for the fail-closed guard (CAP-19) rather
than as a capability of its own.

One limit is recorded as a capability limit rather than an omission, because a consumer has to
plan around it: the HTTP error model is a structured envelope and not RFC 7807 problem details
(CAP-18).

CAP-14 describes `en-migrations` as the append-only pg-migrate component it became in
`docs/plans/62-replace-codd-with-pg-migrate-as-en-s-migration-system.md`, not the codd setup the
README claimed and no database ever ran.
