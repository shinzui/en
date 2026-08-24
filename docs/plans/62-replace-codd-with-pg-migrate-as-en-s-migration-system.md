---
id: 62
slug: replace-codd-with-pg-migrate-as-en-s-migration-system
title: "Replace codd with pg-migrate as en's migration system"
kind: exec-plan
created_at: 2026-08-24T14:13:00Z
intention: "intention_01m0t1v894e7nv8y8yamg3achb"
---

# Replace codd with pg-migrate as en's migration system

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today nobody can run en's database migrations with a migration tool. The repository claims
its SQL is "codd-managed", but no codd binary is in the development shell, no codd
configuration file exists anywhere in the tree, and nothing records which migrations a
database has already received. What actually applies the schema is a hand-written shell
recipe, `run-migrations` in `Justfile`, that probes the live database for each migration's
side effect — "does table `relation_tuple` exist yet?", "does index
`relation_tuple_live_unique` still mention `caveat_name`?" — and shells out to `psql` when
the probe says no. Every new migration means inventing a new probe. A probe that is subtly
wrong silently skips or silently re-runs a migration, and nothing detects that an applied
SQL file was later edited.

A second, worse consequence is that en's PostgreSQL integration test suite does not use the
migrations at all. `en-postgres/integration-test/Main.hs` carries a second, hand-maintained
copy of the schema in a Haskell string literal called `schemaSql`, and that copy has already
drifted: it omits the `en_datastore_metadata` table entirely. The tests therefore prove that
en works against a schema that no real database has.

After this change, en's schema is owned by `pg-migrate`, a Hasql-native PostgreSQL migration
library. Concretely, a person can do this:

```console
cabal run en-migrate -- status
cabal run en-migrate -- up
cabal run en-migrate -- verify
```

and see a real ledger: which migrations are applied, when, with what SHA-256 checksum over
the exact SQL bytes. Running `up` twice is safe and the second run reports `AlreadyApplied`
rather than re-executing anything. Editing an already-applied SQL file is caught by `verify`
instead of silently diverging. Adding a migration becomes `cabal run en-migrate -- new`,
which creates the file and appends it to the ordered manifest atomically — no new shell
probe, ever.

The integration tests stop carrying their own schema copy: they call
`withMigratedDatabase`, which starts a throwaway PostgreSQL server and applies the very same
migration plan the production executable would apply. Schema drift between "what tests run
against" and "what a database gets" becomes structurally impossible.

Nothing in this plan preserves database contents. en has no users and no deployed database;
the local development database in `db/` is recreated from scratch as part of the work.


## Progress

- [x] Milestone 1 (2026-08-24T14:32Z): unblock the dependency closure — widen the `biscuit-haskell` fork onto `crypton` 1.1 / `ram`, re-pin it in `cabal.project`, and prove `pg-migrate` 1.1.0.0 solves and builds inside en.
- [x] Milestone 2 (2026-08-24T14:40Z): turn `en-migrations` into a `pg-migrate` component — new `en-migrations/migrations/` directory with `0001-en-bootstrap.sql` and `manifest`, rewritten `En.Migrations`, and a proof that the squashed bootstrap produces byte-identical schema to the old six-file sequence.
- [x] Milestone 3 (2026-08-24T14:50Z): ship the `en-migrate` executable and rewire the developer workflow (`Justfile`, `process-compose.yaml`).
- [x] Milestone 4 (2026-08-24T14:55Z): make the tests use the real plan — `en-postgres` integration suite migrates with `pg-migrate-test-support`, hand-written `schemaSql` deleted, plan-construction test added.
- [x] Milestone 5 (2026-08-24T15:00Z): retire codd from en's prose and metadata — `README.md`, `mori.dhall`, `en-server/app/Main.hs` operator guidance — and delete `en-migrations/db/`.
- [ ] Milestone 6: ADR distillation and retrospective.


## Surprises & Discoveries

**`pg-migrate` cannot enter en's build plan without changing `biscuit-haskell` first.**
Discovered before any code was written, by running the solver. `pg-migrate` depends on
`crypton >= 1.1 && < 1.2`; the `biscuit-haskell` fork en pins caps `crypton ^>= 1.0`:

```text
$ cabal build all --dry-run --constraint="crypton >= 1.1"
Resolving dependencies...
Error: [Cabal-7107]
Could not resolve dependencies:
[__0] trying: biscuit-haskell-0.4.0.0 (user goal)
[__1] next goal: crypton (dependency of biscuit-haskell)
[__1] rejecting: crypton-1.1.4 (conflict: biscuit-haskell => crypton^>=1.0)
```

**Relaxing the bound is not enough; crypton 1.1 changed its byte-array dependency.**
Adding `--allow-newer=biscuit-haskell:crypton` makes the solver succeed, but the compile then
fails. crypton 1.1 moved from the deprecated `memory` package to its fork `ram`, so
crypton's `Ed25519.PublicKey` no longer has a `ByteArrayAccess` instance from the `memory`
package that `biscuit-haskell` still depends on:

```text
src/Auth/Biscuit/Crypto.hs:101:15: error: [GHC-39999]
    • No instance for ‘memory-0.18.0:Data.ByteArray.Types.ByteArrayAccess
                         Ed25519.PublicKey’
```

**The two-line fix works, and it was proven before this plan was written.** A scratch copy of
the fork with only those two dependency lines changed — `crypton >= 1.0 && < 1.2` and `ram
>= 0.20 && < 0.23` replacing `memory` — was built against en's full package set with
`crypton >= 1.1` forced, together with all four `pg-migrate` packages:

```text
[1 of 1] Compiling Main   ( app/VerifyGrant.hs, .../en-verify-grant-tmp/Main.o )
[2 of 2] Linking .../en-verify-grant
Completed    pg-migrate-embed-1.1.0.0 (lib)
Completed    pg-migrate-cli-1.1.0.0 (lib)
EXIT=0
```

`biscuit-haskell` compiled unchanged at source level, `en-biscuit` linked, and
`pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`, and `pg-migrate-test-support` 1.1.0.0 all
built alongside en's closure with crypton 1.1.4 and tls 2.4.3. Milestone 1 is therefore a
known-good procedure rather than an open question; what remains is doing it for real in the
fork and pushing the commit.

**Milestone 1 landed exactly as rehearsed, with no third surprise.** The two-line
`.cabal` change is `shinzui/biscuit-haskell-project` commit
`61f2b31063db6bc7fe0fb885dd2da957634a525b`; `grep -rn "Data.ByteArray" biscuit/src`
confirmed beforehand that `src/Auth/Biscuit/Crypto.hs` line 46 is the package's only
importer, and no Haskell source needed touching. en's solved plan now carries exactly the
versions the plan predicted:

```text
biscuit-haskell-0.4.0.0   crypton-1.1.4   ram-0.22.1   tls-2.4.3
base-4.21.2.0   hasql-1.10.3.7   aeson-2.2.5.0   containers-0.7
ephemeral-pg-0.2.1.0   optparse-applicative-0.19.0.0
```

`memory` is absent from the plan entirely. All six existing test suites pass, `en-biscuit-tests`
among them -- the signal the plan named as proof that the `memory`-to-`ram` swap is
semantically neutral rather than merely type-correct.

**`pg-migrate`'s own `examples/basic` is the authoritative integration template, and it
corrects the plan's sketch in one place.** Read at
`mori://shinzui/pg-migrate` (`examples/basic/app/Main.hs` and its `.cabal`) before writing any
en code. The example's cabal file enables `DuplicateRecordFields` in the *consuming*
executable. That is not decoration: `PlanOptions`, `ListOptions`, `UpOptions` and the rest each
declare a field named `output`, and `pg-migrate-cli` exports them all ambiguously, so
`commandOutputFormat`'s record patterns do not resolve without it. The plan's Step 8 cabal
file omits it; Milestone 3 adds it.

Every other signature in the plan verified against the 1.1.0.0 source unchanged:
`migrationComponentFromEmbeddedSql :: Text -> Set Text -> NonEmpty (FilePath, ByteString) ->
Either DefinitionError MigrationComponent`, `migrationPlan :: NonEmpty MigrationComponent ->
Either PlanError MigrationPlan`, `cliEnvironment :: Settings.Settings -> MigrationPlan ->
RunOptions -> CliEnvironment`, `renderMigrationCommandText :: CliOutcome -> Text`,
`renderMigrationCommandJson :: CliOutcome -> Value`, `exitClass` as a field of `CliOutcome`,
and `withMigratedDatabaseOptions :: RunOptions -> MigrationPlan -> (Connection -> IO value) ->
IO (Either MigratedDatabaseError value)`. `new` takes `--manifest`, `--description`, and an
optional `--name`, as the Justfile recipe assumes. A manifest entry's `.sql` suffix is
stripped to form the migration's local name, confirming the `en/0001-en-bootstrap` identity.

**The squash is exact, and en's schema now has a fingerprint.** Proven twice, first with
`psql` applying the six old files and then with the real `en-migrate up` path:

```text
$ diff -u <old six files, pg_dump --schema-only>  <bootstrap via en-migrate up, -N pgmigrate>
schemas identical
$ psql -d en_old -tAc 'SELECT horizon FROM en_gc_horizon'   -> 0
$ psql -d en_new -tAc 'SELECT horizon FROM en_gc_horizon'   -> 0
```

The surviving objects are exactly the four tables and five `relation_tuple` indexes the
plan predicted, with `relation_tuple_object_live_idx` and `relation_tuple_subject_live_idx`
absent and `relation_tuple_live_unique` free of `caveat_name`. The dedupe `UPDATE` from
`20260709202037_touch-semantics-live-unique.sql` reported `UPDATE 0` against the fresh old
database, confirming the Decision Log's claim that it is dead work on any database
pg-migrate would ever start from.

en's schema fingerprint from now on:

```text
en/0001-en-bootstrap position=1 kind=sql transaction=transactional
checksum=4a265abb6513df8f7ac8a4faf9f0e4105257b3205075694a7a7fa20cdaf7ea96
```

**`pg_dump` 17.10 emits a random nonce, so Step 10's diff is never empty as written.**
PostgreSQL 17.10's `pg_dump` brackets its output with `\restrict <random>` /
`\unrestrict <random>` lines whose token is regenerated per invocation, so two dumps of
byte-identical schemas still differ in two lines:

```text
-\restrict akNa2LxUuC0cH2NvSDeokdGw2ZHjkzCB7DWJ7OYtSWVZWWLlciRAdfNemShY8Zd
+\restrict 2oZ2alfAcGKuxA46DayqipMIuWcExCsk4fHK2KpmQbi6qi6BJVeYKFvBwMqOV1v
```

This is not schema content. Filter both dumps through
`grep -v '^\\\(un\)\?restrict '` before diffing; with those two lines removed the diff is
genuinely empty. Anyone re-running Step 10 on PostgreSQL 17.10 or later needs this.

**The manifest-membership guard works, but only a clean build reaches it.** Dropping
`en-migrations/migrations/junk.sql` into the directory and rebuilding fails as intended:

```text
src/En/Migrations/Internal/Definition.hs:36:6: error: [GHC-39584]
    • invalid pg-migrate manifest: UnlistedSqlFiles ["junk.sql"]
```

Note what did *not* work: `cabal build en-migrations --ghc-options=-fforce-recomp` and
`touch`-ing the module both printed `Up to date` without invoking GHC at all, exactly the
limitation the `RecompilePlugin` comment describes -- the plugin governs GHC's
recompilation decision, and cabal never got as far as asking GHC. Removing
`dist-newstyle/build/aarch64-osx/ghc-9.12.4/en-migrations-0.1.0.0` is what forces the check
to run locally; CI gets it for free from a cold build.

**Tamper detection is real.** Appending one space to the applied SQL file and rebuilding:

```text
verification failed
issue MigrationChecksumMismatch (MigrationId {component = "en", name = "0001-en-bootstrap"})
  (stored 15b0c98954...) (declared 4a265abb65...)
verify exit: 2
```

Reverting the byte restores `verification ok` and exit 0.

**`en-server/app/Main.hs` had drifted from the repository's own formatter, so touching it
at all costs 1425 lines.** `nix/treefmt.nix` wires `fourmolu` (with the project's
`fourmolu.yaml`), `cabal-fmt`, and `nixpkgs-fmt`; `.pre-commit-config.yaml` runs
`treefmt --fail-on-change`. Running that formatter over `HEAD`'s copy of
`en-server/app/Main.hs` rewrites 1425 lines -- mostly sorting every import into a single
group and converting `{- | -}` Haddock to `-- |` -- so the pre-commit hook rejects any
commit touching the file until that reformat lands. Every other Haskell file spot-checked
(`en-core/src/En/Check.hs`, `en-postgres/src/En/Postgres/TupleStore.hs`,
`en-server/app/Config.hs`, `en-servant/src/En/Servant/Wire.hs`) was already clean, so this
one file was the outlier. It was landed as its own `style(en-server)` commit -- verified a
pure reformat by checking that the multiset of identifiers in the file is unchanged -- which
keeps this plan's functional `en-server` diff at 21 lines.

Two traps when checking formatter cleanliness in this repository, both of which produced a
false "clean" here: `fourmolu.yaml` is discovered by walking up from the file, so a copy in
`/tmp` is formatted with fourmolu's defaults rather than the project's; and `treefmt` only
processes files git tracks, so an untracked scratch file inside the repository is silently
skipped ("emitted 0 files"). Check formatting on the real tracked path, or not at all.

**`just` recipe arguments are positional, so `just make-migration name=foo` silently
misfires.** The plan's Milestone 3 text describes the invocation as
`just make-migration name=whatever`; `just` treats that as the *value* of the first
positional parameter, not an assignment, so it created
`en-migrations/migrations/name=0002-scratch-probe.sql` and dutifully registered that
filename in the manifest. The recipe's doc comment now spells out the positional form.
Both paths were exercised and then reverted: an explicit
`just make-migration 0002-scratch-probe "..."` produced `0002-scratch-probe.sql`, and
`just make-migration "" "..."` let pg-migrate infer `0002.sql`. In every case the file and
the manifest line appeared together, which is the property the old `touch`-based recipe
could not offer.

Note also that `just`'s `--list` summary is the *last* comment line above a recipe, which is
why the migration recipes put their prose first and the one-line summary immediately above
the attribute -- matching the existing `openapi` recipe.

**`just start-and-test` fails in this environment for a reason that has nothing to do with
en.** Apple's `container` runtime (pid 26315,
`/nix/store/...-container-1.2.2/libexec/container/plugins/container-runtime-linux`) holds
`127.0.0.1:8080`, while en-server binds `*:8080`; the more specific loopback binding wins, so
`http://localhost:8080` reaches the container's static file server -- which answers `/healthz`
with its SPA fallback (200, so the readiness wait passes) and then 404s the real API.
Addressing en-server directly works:

```console
$ EN_SERVER_URL="http://192.168.1.115:8080" just test-server
server smoke test passed: allowed
```

That is the Milestone 3 acceptance signal: process-compose ran `just run-migrations`
(now `en-migrate up`), en-server started on the migrated schema, minted its
`en_datastore_metadata` row, and served a write / token / check round trip. If `just
start-and-test` 404s for someone else, check `lsof -nP -iTCP:8080 -sTCP:LISTEN` before
suspecting the migration.

**The duplicated schema had drifted exactly as the plan described, and it is now gone.**
`schemaSql` created `en_gc_horizon`, `en_transaction`, and `relation_tuple` with five
indexes -- and no `en_datastore_metadata`, so every integration run tested en against a
schema no real database has. Both acceptance greps are now empty:

```console
$ grep -rn "CREATE TABLE relation_tuple" --include="*.hs" . | grep -v dist-newstyle
$ grep -rln "CREATE TABLE" --include="*.hs" . | grep -v dist-newstyle
```

There is no `CREATE TABLE` in any Haskell source in the repository at all. All eight test
suites pass, `en-postgres-integration-tests` among them, now against the migrated schema.

Deleting `runMigrationDedupeScenario` also orphaned `textStatement`, which nothing else
used; `-Wall` caught it and it was removed rather than left behind.

**Two live documents outside Milestone 5's named scope also claimed codd, and were
corrected.** The milestone names `README.md`, `mori.dhall`, and `en-server/app/Main.hs`, but
the acceptance grep is wider than that, and it found two more files making false claims
about how en is migrated:

  * `docs/spec/0001-en-overview.md` (package table) described `en-migrations` as the "codd
    PostgreSQL schema" listing only two of its four tables.
  * `docs/user/service-and-operations.md` (Migrations section) told operators that
    `just run-migrations` applies each file with a `to_regclass`-guarded `psql` invocation.
    That is the exact mechanism this plan deletes, and it is the section an operator reads
    first. It now documents `en-migrate status` / `up` / `verify`, the ledger, advisory-lock
    safety, and the append-only rule.

**What deliberately still says codd.** `docs/plans/` and `docs/masterplans/` are historical
records and are not rewritten, as the milestone states. `docs/reviews/2026-07-07-architecture-performance-review.md`
is left alone for the same reason -- it is a dated review, and its finding ("README says
migrations are codd-managed; the Justfile applies them with raw `psql`") is precisely the
defect this plan closes. Rewriting it would erase the evidence that the problem was known.

**A concurrent process was writing this repository during implementation.** A `docs/capabilities/`
OKF bundle (including `profile.dhall`, `log.md`, and `postgres-migrations.md`) and a large
`mori.dhall` change adding `dependencyRefs` appeared in the working tree mid-session, with new
files still being created between commits. None of it was authored by this plan and none of it
was committed here. `mori.dhall` was handled by staging only this plan's two codd lines against
`HEAD` while leaving the concurrent edits unstaged, so this plan's commit carries exactly its
own change. Two consequences for whoever owns that work: their uncommitted `mori.dhall` still
carries a `Schema.MoriRef` for `mzabani/codd` (updated in the working tree to
`shinzui/pg-migrate`, but not committed by this plan), and `docs/capabilities/postgres-migrations.md`
still documents codd and points `resource:` at the now-deleted `en-migrations/db/migrations`.

(Add further discoveries here as work proceeds, with evidence.)


## Decision Log

- Decision: Squash en's six existing SQL migrations into a single `0001-en-bootstrap.sql`
  rather than porting them one-for-one.
  Rationale: No database anywhere holds a codd ledger, so `pg-migrate` history starts empty
  regardless. Two of the six files only make sense against an already-migrated database:
  `20260709202037_touch-semantics-live-unique.sql` runs a duplicate-resolution `UPDATE` over
  rows that cannot exist on a fresh database and then drops and recreates an index that the
  first file just created, and `20260709232320_drop-dead-live-indexes.sql` drops two indexes
  the first file just created. Replaying that dead work on every fresh developer, CI, and
  ephemeral-test database forever buys nothing. The evolution history stays in git and in
  `docs/plans/45`, `docs/plans/49`, `docs/plans/60`. Milestone 2 proves the squash is exact
  by diffing `pg_dump --schema-only` against the old sequence.
  Date: 2026-08-24

- Decision: Do not use `pg-migrate-import-codd`.
  Rationale: That adapter exists to read a real codd ledger table and map its rows into the
  `pg-migrate` ledger so an existing database is not re-migrated. en has never run codd; no
  codd ledger exists in any database. Importing nothing would add a package, a mapping
  module, and an audit trail with no subject.
  Date: 2026-08-24

- Decision: Keep `en-server` free of migration execution; it neither applies nor verifies
  migrations at startup.
  Rationale: `pg-migrate`'s deployment runbook is explicit that migrations should run as an
  explicit deployment or administrative job and that service startup should not be the
  primary migration path. `en-server` today only prints guidance when the schema is missing;
  this plan updates the wording and leaves the behavior alone. Adding a startup verification
  pass would also require handing `pg-migrate` a dedicated connection while `en-server` owns
  a `hasql-pool`, which is scope this plan does not need.
  Date: 2026-08-24

- Decision: Delete `runMigrationDedupeScenario` from
  `en-postgres/integration-test/Main.hs` instead of adapting it.
  Rationale: That scenario re-creates the pre-touch-semantics index shape, seeds duplicate
  live rows, and asserts that the duplicate-resolution `UPDATE` from
  `20260709202037_touch-semantics-live-unique.sql` keeps the newest row. Once that migration
  is squashed away, the scenario tests SQL that the repository no longer ships. Keeping it
  would mean maintaining a fourth copy of retired migration SQL inside a test. The touch
  semantics it protects — one live tuple per (object, relation, subject) — remain covered by
  `runTouchSemanticsScenario` and by the live unique index itself.
  Date: 2026-08-24

- Decision: Migrate the integration suite with `runMigrationPlan` inside the existing
  `Pg.with` bracket, rather than replacing the bracket with `withMigratedDatabaseOptions`
  as Milestone 4 specified.
  Rationale: `withMigratedDatabaseOptions` hands the callback exactly one
  `Connection.Connection` and does not expose the `EphemeralPg.Database` it started. Four
  scenarios need that handle to open *additional* concurrent connections --
  `runWriteRaceScenario` acquires three (`leftConnection`, `rightConnection`, `blocker`),
  `runBatchTouchRaceScenario` two, `runSnapshotRepeatabilityScenario` one holder, and
  `runHorizonMonotonicityScenario` likewise -- and without them the write-race and
  batch-touch-race scenarios cannot contend at all. Adopting the helper would have meant
  rewriting those four scenarios to thread connection settings instead of a database handle,
  which is unrelated churn in the most delicate tests in the suite.
  `runMigrationPlan defaultRunOptions (Pg.connectionSettings database) enMigrationPlan` is
  the same plan applied by the same runner the helper itself calls, so the milestone's actual
  goal -- tests run against the migration plan `en-migrate up` applies, with no second copy
  of the schema anywhere -- is met exactly. `pg-migrate-test-support` is therefore not a
  dependency of this suite; `pg-migrate` is.
  Date: 2026-08-24

- Decision: Widen the existing `shinzui/biscuit-haskell-project` fork rather than adding
  `allow-newer` to en's `cabal.project`.
  Rationale: `allow-newer` makes the solver succeed but the build still fails (see Surprises
  & Discoveries), so it does not actually solve the problem. The fork already exists
  precisely to carry GHC 9.12 bound widenings, and the correct fix — depend on `ram` instead
  of the deprecated `memory` — belongs in the package that has the wrong dependency.
  Date: 2026-08-24


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Architecture Decision Records

There is no `docs/adr/` directory in this repository and `mori.dhall` declares no OKF
bundles, so no local ADR governs this work and none was consulted. Per the ADR workflow this
skill follows, an absent corpus must not be invented as an incidental plan edit. Milestone 6
decides whether this work produces durable project context worth an ADR and, if so, creates
`docs/adr/` as plain Markdown with no OKF frontmatter, matching the repository's other
documentation directories.

### What en is, in one paragraph

en is a Haskell relationship-based authorization toolkit. It stores authorization facts as
"relation tuples" — rows saying, for example, that user `alice` is a `viewer` of space
`project-x` — in PostgreSQL, and answers permission questions over them. It never deletes a
tuple row outright: it stamps the row's `deleted_xid` column with the transaction id that
removed it, so a query can reconstruct what the database looked like at any past moment.
That is what makes en's "consistency tokens" work. The Cabal packages are `en-core` (pure
engine), `en-migrations` (the SQL schema), `en-postgres` (Hasql-backed storage),
`en-servant` (HTTP API types), `en-server` (the standalone service), `en-client`,
`en-biscuit`, and `en-example`. They are listed in `cabal.project`.

### The current migration situation, exactly

`en-migrations/db/migrations/` holds six plain SQL files whose names begin with a UTC
timestamp:

```text
20260623044157_create-relation-tuples.sql
20260623160000_historical-read-indexes.sql
20260709023019_datastore-metadata.sql
20260709202037_touch-semantics-live-unique.sql
20260709232320_drop-dead-live-indexes.sql
20260710150000_gc-horizon-high-water-mark.sql
```

Applied in that order they produce five database objects that en's code depends on: the
tables `en_transaction`, `relation_tuple`, `en_datastore_metadata`, and `en_gc_horizon`, and
five surviving indexes on `relation_tuple`.

`en-migrations/src/En/Migrations.hs` is the entire Haskell side of the package. It exports
one value:

```haskell
migrationsDir :: FilePath
migrationsDir = "db/migrations"
```

`en-server/app/Main.hs` imports that value at line 40 and interpolates it into three operator
messages (around lines 214, 764, and 877) that say, in effect, "apply the migrations in
db/migrations first". Nothing else in the repository imports `En.Migrations`.

The word "codd" appears in `README.md` line 38, in the `en-migrations` description inside
`mori.dhall`, in the `dependencies` list of `mori.dhall` (as `mzabani/codd`), and in the
Haddock comment atop `En.Migrations`. `docs/plans/38-validate-configuration-and-persist-datastore-identity.md`
already recorded the discrepancy: the migrations are codd-*compatible* SQL applied by
guarded `psql`, and no codd pipeline exists.

The `Justfile` recipe `run-migrations` is that guarded `psql` loop. Each of its six blocks
asks PostgreSQL a question and applies one file if the answer says the file has not run.
`process-compose.yaml` invokes `just run-migrations` before starting `en-server`, and the
`start-server` recipe depends on it.

### What pg-migrate is and how it differs

`pg-migrate` is a Haskell migration library. Its canonical project handle is
`mori://shinzui/pg-migrate`; its packages are `mori://shinzui/pg-migrate/packages/pg-migrate`,
`.../pg-migrate-embed`, `.../pg-migrate-cli`, and `.../pg-migrate-test-support`. Version
1.1.0.0 of all four is published on Hackage. The essential ideas, in plain terms:

A **manifest** is a plain text file named `manifest` sitting beside the SQL files. It lists
one `.sql` filename per line, in the order they must run. There are no comments, no
directives, and no header — a `#` or `--` line is a validation error. Order in the file is
execution order.

A **component** is a named, ordered bundle of migrations owned by one package. en has
exactly one, named `en`. A migration's durable identity is `component/name`, so
`0001-en-bootstrap.sql` in component `en` becomes `en/0001-en-bootstrap`.

**Embedding** means the SQL bytes are compiled into the binary by Template Haskell at build
time, not read from disk at run time. The splice `$(embedMigrationManifest "migrations/manifest")`
validates the manifest, registers every listed file as a compiler dependency, and produces
a `NonEmpty (FilePath, ByteString)`. It also fails the build if a `.sql` file sits in that
directory without being listed in the manifest — which is the mistake people actually make.

The **ledger** is a set of tables `pg-migrate` creates in its own PostgreSQL schema, named
`pgmigrate` by default. It records every applied migration's identity, position, SHA-256
checksum over the exact SQL bytes, kind, and transaction mode. For ordinary transactional
SQL, the migration's effects and its ledger row commit in a single transaction, so a
migration is never half-recorded.

**Append-only** is the rule that makes all of this sound: once a migration is applied
anywhere, its bytes, name, and position are frozen. Fixing something means appending a new
migration, never editing an old one. Editing an applied file changes its checksum and makes
`verify` fail. This is precisely the guarantee en has no way to offer today.

The commands the CLI mounts are `plan`, `list`, and `check` (no database needed), and
`status`, `verify`, `up`, and `repair` (database needed), plus `new` for authoring. All
accept `--json`.

### The dependency obstacle

This is the one genuinely hard part, and it has nothing to do with migrations. `pg-migrate`
computes checksums with `crypton >= 1.1 && < 1.2`. en depends, through `en-biscuit`, on
`biscuit-haskell` — pinned in `cabal.project` as a `source-repository-package` at
`https://github.com/shinzui/biscuit-haskell-project.git`, tag
`aef4272f0d44eec75c79aa6c2dd00c4200401829`, subdirectory `biscuit-haskell/biscuit`. That
fork's `.cabal` file caps `crypton ^>= 1.0` and depends on `memory >= 0.15 && < 0.19`.

Cabal resolves exactly one version of `crypton` for the whole project, so the two bounds are
irreconcilable and the solver refuses outright. Widening the bound alone does not work
either: crypton 1.1 replaced the deprecated `memory` package with its maintained fork `ram`,
so with crypton 1.1 in the plan, `biscuit-haskell`'s `Auth/Biscuit/Crypto.hs` asks for a
`ByteArrayAccess` instance from `memory` that only exists in `ram`.

The fix is confined to the fork's `.cabal` file. `ram` exposes `Data.ByteArray` with the same
`convert`, `biscuit-haskell` uses no other module from `memory`, and only one source file
(`src/Auth/Biscuit/Crypto.hs`, importing `Data.ByteArray (convert)`) touches it. Milestone 1
makes that change upstream and re-pins en to the new commit.

### Where things will live afterwards

```text
en-migrations/
├── app/
│   └── Main.hs                     (new) the en-migrate executable
├── migrations/
│   ├── 0001-en-bootstrap.sql       (new) the complete schema
│   └── manifest                    (new) one line: 0001-en-bootstrap.sql
├── src/
│   └── En/
│       ├── Migrations.hs           (rewritten) exports enMigrationPlan
│       └── Migrations/
│           └── Internal/
│               └── Definition.hs   (new) the Template Haskell embedding site
├── test/
│   └── Main.hs                     (new) plan-construction test
└── en-migrations.cabal             (rewritten)
```

`en-migrations/db/` disappears.


## Plan of Work

The work is six milestones. Milestone 1 must come first: nothing else can compile until it
lands. It is the only step that touches another repository, and it has already been rehearsed
against a scratch copy of the fork (see Surprises & Discoveries), so it is a known-good
procedure rather than an experiment. Milestones 2 through 5 are ordinary additive change.
Milestone 6 is the closing distillation the plan skill requires.

### Milestone 1 — Unblock the dependency closure

**Scope.** Make `pg-migrate` 1.1.0.0 buildable inside en. Nothing about migrations changes in
this milestone.

Clone or open the existing checkout of the biscuit fork. It lives on this machine at
`/Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project`, currently at exactly the commit
en pins. In `biscuit-haskell/biscuit/biscuit-haskell.cabal`, change two dependency lines:

```diff
-    crypton              ^>= 1.0,
-    memory               >= 0.15 && < 0.19,
+    crypton              >= 1.0 && < 1.2,
+    ram                  >= 0.20 && < 0.23,
```

No Haskell source change is needed, and this was verified before the plan was written by
building a patched scratch copy: `ram` is a fork of `memory` exposing the same
`Data.ByteArray` module with the same `convert`, and `src/Auth/Biscuit/Crypto.hs` is the only
module in the package that imports it. If a future version of the fork reveals another module
using a `memory`-only API, fix that module and record it under Surprises & Discoveries.

Commit and push that change to `shinzui/biscuit-haskell-project`, then update the pin in
en's `cabal.project` to the new commit hash. Because the widened bound admits both crypton
1.0 and 1.1, add a `constraints:` line forcing the new one so the solver does not quietly
stay on 1.0.6 and reintroduce the conflict when `pg-migrate` arrives:

```cabal
constraints:
    crypton >= 1.1,
    ephemeral-pg ==0.2.1.0,
    tasty-bench ==0.5
```

Extend the existing comment block above the `biscuit-haskell` pin to say why: crypton 1.1 is
required by `pg-migrate` and the fork carries the `memory`-to-`ram` swap that crypton 1.1
demands.

**Result.** `cabal build all` succeeds with crypton 1.1.4, tls 2.4.3, and the widened biscuit
fork. `pg-migrate` is not yet a dependency of anything, but a dry run proves it can be.

**Acceptance.** `cabal build all` completes, `cabal test all` still passes, and
`cabal run en-verify-grant -- --help` (the `en-biscuit` executable, which exercises the
Ed25519 code path that the `ram` swap touches) runs. `en-biscuit`'s own test suite is the
real signal here: it is the only thing in the repository that exercises Ed25519 signing and
verification, so a passing `cabal test en-biscuit` is what proves the `memory`-to-`ram` swap
was semantically neutral and not merely type-correct.

### Milestone 2 — Turn en-migrations into a pg-migrate component

**Scope.** Create the manifest and the squashed bootstrap SQL, rewrite `En.Migrations` to
export a validated plan, and prove the squash is exact.

Create `en-migrations/migrations/manifest` containing exactly one line:

```text
0001-en-bootstrap.sql
```

Create `en-migrations/migrations/0001-en-bootstrap.sql` with the complete schema. Its content
is given verbatim in Concrete Steps below. It is the fixed point of the six old files: the
live unique index without `caveat_name`, the two indexes that
`20260709232320_drop-dead-live-indexes.sql` dropped simply absent, and every surviving
comment preserved.

Add `en-migrations/src/En/Migrations/Internal/Definition.hs` as the embedding site. It needs
both `TemplateHaskell` and the `RecompilePlugin` pragma; the pragma is not optional
decoration. GHC 9.12 has no way to register a *directory* as a Template Haskell dependency,
so without it, adding a stray `.sql` file to `en-migrations/migrations/` would leave the
module looking up to date and the manifest-membership check would never run.

Rewrite `en-migrations/src/En/Migrations.hs` to export `enMigrations` (the component) and
`enMigrationPlan :: Either PlanError MigrationPlan`, and delete `migrationsDir`. Rewrite the
module Haddock: it currently says "codd-managed" and describes the schema in the future tense
("to be added"), both of which have been wrong for a while.

Update `en-migrations/en-migrations.cabal`: new synopsis and description, `extra-source-files`
for the SQL and manifest, `TemplateHaskell` in `default-extensions`, and library dependencies
on `bytestring`, `containers`, `pg-migrate ^>=1.1.0.0`, and `pg-migrate-embed ^>=1.1.0.0`.

**Result.** `en-migrations` is a `pg-migrate` component. Nothing consumes it yet — `en-server`
still imports the now-deleted `migrationsDir` and will not compile until Milestone 5, so do
Milestone 3 and the `en-server` edit from Milestone 5 in the same working session if you want
a green tree at every commit. The simplest ordering that keeps every commit building is:
Milestone 2's package edits, then the `en-server/app/Main.hs` message rewrite from Milestone
5, then commit.

**Acceptance.** `cabal build en-migrations` succeeds. Deliberately dropping a stray
`en-migrations/migrations/junk.sql` into the directory and rebuilding fails the build with a
manifest-membership error; deleting it restores the build. The schema-equivalence proof in
Validation and Acceptance shows a byte-identical `pg_dump --schema-only` against the old
sequence.

### Milestone 3 — Ship the en-migrate executable and rewire the dev workflow

**Scope.** Add the administrative CLI and make it the only way migrations are applied.

Add `en-migrations/app/Main.hs`, an `optparse-applicative` program that mounts
`migrationCommandParser`, reads `DATABASE_URL` for a default connection, dispatches, renders
text or JSON according to the parsed command, and exits. The full source is in Concrete
Steps. Declare it in `en-migrations.cabal` as `executable en-migrate` with dependencies on
`aeson`, `bytestring`, `hasql`, `optparse-applicative`, `pg-migrate`, `pg-migrate-cli`, and
`text`.

Then replace the shell probes. In `Justfile`, `run-migrations` becomes a one-liner that runs
`en-migrate up`, and `make-migration` becomes a call to `en-migrate new`, which creates the
file and appends it to the manifest atomically instead of `touch`-ing a file that someone
must remember to wire up. Add a `verify-migrations` recipe for the pre-deploy check. The
`migrationDate` variable at the top of the `Justfile` becomes dead and should go: `new`
derives the next name from the manifest's existing numbering.

`process-compose.yaml` needs no structural change — its `en-server` process already runs
`just run-migrations &&` before building and executing the server, and that recipe now does
the right thing.

**Result.** `cabal run en-migrate -- up` applies the schema and records a ledger;
`just run-migrations` is a thin wrapper over it; `just make-migration name=whatever` produces
a properly registered migration file.

**Acceptance.** Against a freshly created empty database, `up` reports the bootstrap
migration as `AppliedNow`, a second `up` reports `AlreadyApplied`, and `verify` succeeds.
`just start-and-test` brings up the whole stack through `process-compose` and the HTTP smoke
test passes.

### Milestone 4 — Make the tests use the real plan

**Scope.** Delete the duplicated schema and migrate test databases with the real plan.

In `en-postgres/integration-test/Main.hs`, the current `main` starts an ephemeral server with
`Pg.with`, acquires a connection, and calls `resetSchema` — which executes the hand-written
`schemaSql` literal, dropping and recreating three tables. `resetSchema` is called nine times
to wipe state between scenarios.

Replace the outer bracket with `withMigratedDatabaseOptions` from
`Database.PostgreSQL.Migrate.Test`, passing `enMigrationPlan`. That helper starts the
ephemeral server, applies the plan on a dedicated connection, releases it, and hands the
callback a fresh connection. Then redefine `resetSchema` to truncate rather than recreate:

```haskell
resetSchema :: Connection.Connection -> IO ()
resetSchema connection =
    runSessionOrFail
        connection
        (Session.script "TRUNCATE relation_tuple, en_transaction RESTART IDENTITY; UPDATE en_gc_horizon SET horizon = 0;")
```

Truncating rather than dropping is what keeps the `pgmigrate` ledger intact between
scenarios — dropping and recreating the application tables under a live ledger would leave
the ledger claiming migrations that no longer describe the database. Note that
`en_datastore_metadata` now exists in the test database for the first time; it needs no reset
because the integration suite never writes to it.

Delete `schemaSql`, `runMigrationDedupeScenario`, `oldLiveUniqueSql`, `duplicateSeedSql`, and
`dedupeAndReindexSql`, and remove the scenario's call site in `main` (see the Decision Log
entry for why). Unwrap the `Either MigratedDatabaseError` result explicitly and `fail` with
the structured error rather than a boolean — a Hasql `Left` returned normally by the callback
is a result, not an exception, so both layers must be matched.

Add `pg-migrate`, `pg-migrate-test-support`, and `en-migrations` to the
`en-postgres-integration-tests` stanza in `en-postgres/en-postgres.cabal`. `en-postgres`'s
library already depends on `en-migrations`, so no new package-level edge is created.

Add a small test suite `en-migrations-tests` at `en-migrations/test/Main.hs` that evaluates
`enMigrationPlan` and fails loudly on `DefinitionError` or `PlanError`. This is the fast
check that runs without PostgreSQL and catches an invalid manifest, invalid SQL, or a broken
component definition in CI before anything touches a database.

**Result.** There is exactly one description of en's schema in the repository, and the tests
run against it.

**Acceptance.** `cabal test en-postgres:en-postgres-integration-tests` passes.
`grep -rn "CREATE TABLE relation_tuple" --include="*.hs" .` returns nothing.
`cabal test en-migrations` passes.

### Milestone 5 — Retire codd from prose and metadata

**Scope.** Make the repository's claims true.

`en-server/app/Main.hs` imports `migrationsDir` at line 40 and uses it in three operator
messages. Replace the import with a local constant and update the wording so it names the
command an operator should actually run:

```haskell
migrationHint :: Text.Text
migrationHint = "Apply migrations with `cabal run en-migrate -- up`."
```

Use it at the three sites — the unreachable-database message (around line 214), the
datastore-identity failure (around line 764), and `describeSchemaSource`'s demo-schema note
(around line 877). The datastore-identity message currently asks "Is the
en_datastore_metadata migration ... applied?"; it should now say the database's migrations
are missing or out of date and name the command.

In `README.md` line 38, replace the `en-migrations` row's description with pg-migrate wording
naming `en-migrate up`. In `mori.dhall`, replace `"codd-managed PostgreSQL schema migrations"`
in the `en-migrations` package description and replace `"mzabani/codd"` in the `dependencies`
list with `"shinzui/pg-migrate"`.

Finally delete `en-migrations/db/` — the six old SQL files. Their content survives in git
history and their reasoning survives in the plan documents they cite.

**Result.** No reference to codd remains outside `docs/plans/` and `docs/masterplans/`, which
are historical records and must not be rewritten.

**Acceptance.** `grep -rn "codd" --include="*.hs" --include="*.cabal" --include="*.nix" --include="*.dhall" --include="*.yaml" --include="*.md" . | grep -v "^./docs/plans" | grep -v "^./docs/masterplans" | grep -v dist-newstyle` returns only this plan file. `cabal build all` and `cabal test all` pass.

### Milestone 6 — ADR distillation and retrospective

**Scope.** Close the plan properly.

Review the Decision Log and Surprises & Discoveries for context that outlives this plan. Two
candidates stand out: the fact that en's schema is owned by an append-only `pg-migrate`
component and that editing an applied migration is forbidden, and the crypton 1.1 / `ram`
constraint that now binds en's whole dependency closure through a forked
`biscuit-haskell`. Both are the kind of thing a future contributor will otherwise rediscover
painfully.

Since no `docs/adr/` exists, create it only if you conclude an ADR is warranted, as plain
Markdown files with a heading and no OKF frontmatter — do not invent a profile, a `docId`
scheme, or Mori identity as a side effect of this plan. Then write the Outcomes &
Retrospective section.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/en`, inside the Nix
development shell (`nix develop`, or automatically via `direnv`). The shell sets `PGHOST` to
`$PWD/db`, `PGDATA` to `$PGHOST/db`, `PGDATABASE` to `en`, and `PG_CONNECTION_STRING` to a
unix-socket URL for that database.

### Step 1 — Start PostgreSQL

```console
$ just process-up
```

Expect `pg_ctl: server is running`. If the data directory does not exist yet, entering the
shell runs `initdb` for you.

### Step 2 — Milestone 1: widen the biscuit fork

```console
$ cd /Users/shinzui/Keikaku/hub/haskell/biscuit-haskell-project
$ git log --oneline -1
aef4272 feat: add mori.dhall and Justfile for biscuit-haskell corpus
```

Confirm that hash matches the tag in en's `cabal.project`. Edit
`biscuit-haskell/biscuit/biscuit-haskell.cabal` lines 56 and 57 as shown in Milestone 1, then
commit and push:

```console
$ git commit -am "fix(deps): build against crypton 1.1 and ram"
$ git push
$ git rev-parse HEAD
```

Back in en, update the `tag:` line of the `biscuit-haskell` `source-repository-package` stanza
in `cabal.project` to that hash, add `crypton >= 1.1,` to the `constraints:` block, and
build:

```console
$ cd /Users/shinzui/Keikaku/bokuno/en
$ cabal build all
$ cabal test all
```

If `biscuit-haskell` fails to compile for a reason other than the two `.cabal` lines, stop and
record the error under Surprises & Discoveries before continuing — the rest of the plan
depends on this working.

### Step 3 — Milestone 2: the manifest

```console
$ mkdir -p en-migrations/migrations
$ printf '0001-en-bootstrap.sql\n' > en-migrations/migrations/manifest
```

### Step 4 — Milestone 2: the bootstrap SQL

Create `en-migrations/migrations/0001-en-bootstrap.sql` with exactly this content:

```sql
-- en's complete PostgreSQL schema.
--
-- This single migration is the fixed point of the six timestamped SQL files that
-- preceded pg-migrate adoption (see docs/plans/62). Their evolution -- the
-- caveat-free live unique index from docs/plans/45, the index trim from
-- docs/plans/49, the gc-horizon high-water mark from docs/plans/60 -- is
-- preserved in git history and in those plans. It is not replayed here, because
-- no database has ever held that history.
--
-- Append the next migration; never edit this file. Its exact bytes are the
-- checksum pg-migrate stores when a database applies it.

-- One row per write transaction. `snapshot` anchors consistency tokens: it
-- captures which transactions were in flight when the write committed, which is
-- what lets a later read reconstruct the database as of this moment.
CREATE TABLE en_transaction
  ( xid xid8 PRIMARY KEY
  , snapshot pg_snapshot NOT NULL DEFAULT pg_current_snapshot()
  , schema_hash text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );

-- Relation tuples, soft-deleted rather than removed: `deleted_xid` NULL means
-- live. Point-in-time reads test visibility with pg_visible_in_snapshot against
-- created_xid and deleted_xid, so a row removed today is still correctly visible
-- to a read anchored before its removal.
CREATE TABLE relation_tuple
  ( id bigserial PRIMARY KEY
  , object_type text NOT NULL
  , object_id text NOT NULL
  , relation text NOT NULL
  , subject_type text NOT NULL
  , subject_id text NOT NULL
  , subject_relation text NULL
  , caveat_name text NULL
  , caveat_payload jsonb NULL
  , created_xid xid8 NOT NULL
  , deleted_xid xid8 NULL
  , CHECK ((subject_relation IS NULL) OR (subject_relation <> ''))
  );

-- Touch semantics (docs/plans/45): a live tuple's identity is
-- (object, relation, subject). The caveat is an attribute of that tuple, not part
-- of its identity, so writing the same tuple with a different caveat replaces it
-- rather than adding a second live row.
CREATE UNIQUE INDEX relation_tuple_live_unique
  ON relation_tuple
    ( object_type
    , object_id
    , relation
    , subject_type
    , subject_id
    , coalesce(subject_relation, '')
    )
  WHERE deleted_xid IS NULL;

-- Historical reads scan without the live predicate, so they need unfiltered
-- indexes in both directions (object-scoped and subject-scoped).
CREATE INDEX relation_tuple_object_hist_idx
  ON relation_tuple (object_type, object_id, relation, id);

CREATE INDEX relation_tuple_subject_hist_idx
  ON relation_tuple
    (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id);

CREATE INDEX relation_tuple_created_xid_idx
  ON relation_tuple (created_xid);

COMMENT ON INDEX relation_tuple_created_xid_idx IS
  'Reserved for the watch/changelog feed (docs/plans/53-add-a-watch-changelog-api.md); serves no statement today. See docs/plans/49-trim-dead-indexes-and-resolve-consistency-lazily.md.';

-- Serves the reaper, which physically removes rows whose deleted_xid has fallen
-- below the garbage-collection horizon.
CREATE INDEX relation_tuple_deleted_xid_idx
  ON relation_tuple (deleted_xid)
  WHERE deleted_xid IS NOT NULL;

-- This database's persistent identity.
--
-- Every consistency token embeds a datastore id, and token validation rejects a
-- token whose id does not match the serving datastore. That guard is only worth
-- anything if distinct databases carry distinct ids.
--
-- The id is minted by the server on first startup, not here: keeping the
-- migration pure DDL leaves it deterministic and free of any dependency on
-- pgcrypto for gen_random_uuid(). The server inserts a candidate with
-- ON CONFLICT DO NOTHING and then reads back whichever id won, so servers racing
-- on first startup converge rather than fighting.
--
-- The singleton column enforces exactly-one-row at the schema level: the primary
-- key admits one `true`, and the check constraint forbids `false`.
CREATE TABLE en_datastore_metadata
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , datastore_id text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );

-- The garbage-collection horizon's durable high-water mark (docs/plans/60,
-- Milestone 4).
--
-- The horizon is oldestRetainedXid: the reaper physically deletes a soft-deleted
-- tuple whose deleted_xid < horizon, and token validation rejects any snapshot
-- under which a row already reaped could still be live. For that to be sound the
-- horizon must never move backwards -- reaping at T1 destroys rows below H(T1),
-- and a token validated at T2 > T1 reasons about H(T2), so the argument needs
-- H(T1) <= H(T2). A freshly computed horizon does not guarantee that on its own:
-- a long-running transaction holding pg_snapshot_xmin low can pull a later
-- horizon below an earlier one.
--
-- This table is that missing guarantee. It holds one row: the greatest horizon
-- ever served. The reaper advances it (SET horizon = GREATEST(horizon, fresh))
-- and returns the new value before it reaps, and token validation reads
-- GREATEST(horizon, fresh). Because the reaper publishes the mark before it
-- destroys anything, validation on any replica is bounded below by every reap any
-- replica has already performed.
--
-- The row is seeded here (horizon 0) so the reaper and validation always find it;
-- GREATEST lifts 0 to the first real horizon on the first pass.
CREATE TABLE en_gc_horizon
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , horizon bigint NOT NULL DEFAULT 0
  );

INSERT INTO en_gc_horizon (singleton, horizon) VALUES (true, 0);
```

### Step 5 — Milestone 2: the embedding site

Create `en-migrations/src/En/Migrations/Internal/Definition.hs`:

```haskell
{-# LANGUAGE TemplateHaskell #-}

{- GHC 9.12 has no Template Haskell API for registering a directory as a
dependency, so a .sql file added to or removed from en-migrations/migrations
without touching the manifest would leave this module looking up to date and
silently skip manifest-membership validation. The plugin below is a no-op Core
plugin whose recompilation policy forces GHC to reconsider this module on every
build it runs. It cannot help when no Haskell source changes at all -- cabal then
reports "Up to date" and never invokes GHC -- but a clean build revalidates. -}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module En.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    enMigrations,
) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    migrationComponentFromEmbeddedSql,
 )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)

-- | The manifest's files and their exact bytes, embedded at compile time.
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
    $(embedMigrationManifest "migrations/manifest")

{- | en's single migration component.

The component name @en@ is durable: it forms the first half of every migration's
stored identity (@en\/0001-en-bootstrap@), so changing it would orphan every
applied row in the ledger.
-}
enMigrations :: Either DefinitionError MigrationComponent
enMigrations =
    migrationComponentFromEmbeddedSql "en" mempty embeddedMigrationEntries
```

### Step 6 — Milestone 2: rewrite En.Migrations

Replace the whole of `en-migrations/src/En/Migrations.hs`:

```haskell
{- | en's PostgreSQL schema, as a pg-migrate migration plan.

The SQL lives in @en-migrations/migrations@ and is embedded into the binary at
compile time, so nothing reads a migrations directory at run time. The schema
defines:

  * @relation_tuple@ -- the authorization facts, with @created_xid xid8@ and
    @deleted_xid xid8@ (@NULL@ = live) for MVCC soft-delete.
  * @en_transaction@ -- one row per write, carrying @xid xid8@ and
    @snapshot pg_snapshot@ to anchor consistency tokens.
  * @en_datastore_metadata@ -- this database's persistent identity.
  * @en_gc_horizon@ -- the garbage-collection horizon's high-water mark.

See @docs\/spec\/0001-en-overview.md@ (Consistency).

Migrations are append-only. Add one with
@cabal run en-migrate -- new --manifest en-migrations\/migrations\/manifest@;
never edit an applied file, because its exact bytes are the checksum a database
has already recorded.
-}
module En.Migrations (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    enMigrationPlan,
    enMigrations,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationPlan,
 )
import En.Migrations.Internal.Definition (enMigrations)

{- | The complete single-component migration plan for en.

The embedded manifest is validated at compile time, so a component-definition
failure here indicates a broken package invariant rather than an operator error.
-}
enMigrationPlan :: Either PlanError MigrationPlan
enMigrationPlan =
    case enMigrations of
        Left definitionError ->
            error ("invalid embedded en migration component: " <> show definitionError)
        Right component -> migrationPlan (component :| [])
```

### Step 7 — Milestone 3: the en-migrate executable

Create `en-migrations/app/Main.hs`:

```haskell
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
import En.Migrations (enMigrationPlan)
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as Exit

main :: IO ()
main = do
    plan <- either (fail . show) pure enMigrationPlan
    command <-
        execParser
            ( info
                (migrationCommandParser plan <**> helper)
                (fullDesc <> progDesc "Manage en's PostgreSQL migration plan")
            )
    -- plan, list, check, and new never touch a database, so an absent
    -- DATABASE_URL must not stop them; the database-backed commands fail with
    -- hasql's own connection error instead.
    defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
    let defaultSettings =
            Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
        environment = cliEnvironment defaultSettings plan defaultRunOptions
    outcome <- runMigrationCommand environment command
    case commandOutputFormat command of
        TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
        JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
    Exit.exitWith (exitCodeFor (exitClass outcome))

-- | Distinguish success, a verification report with issues, bad input, and a
-- runtime failure, so deployment automation can branch on the exit code.
exitCodeFor :: ExitClass -> Exit.ExitCode
exitCodeFor =
    \case
        ExitSucceeded -> Exit.ExitSuccess
        ExitVerificationFailed -> Exit.ExitFailure 2
        ExitUsageFailed -> Exit.ExitFailure 64
        ExitExecutionFailed -> Exit.ExitFailure 1

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat =
    \case
        Plan PlanOptions{output = OutputOptions format} -> format
        List ListOptions{output = OutputOptions format} -> format
        Check CheckOptions{output = OutputOptions format} -> format
        Status StatusOptions{output = OutputOptions format} -> format
        Verify VerifyOptions{output = OutputOptions format} -> format
        Up UpOptions{output = OutputOptions format} -> format
        Repair RepairOptions{output = OutputOptions format} -> format
        New NewOptions{output = OutputOptions format} -> format
```

### Step 8 — Milestone 3: the cabal file

Rewrite `en-migrations/en-migrations.cabal` so the library, the executable, and the test
suite are declared. The `LambdaCase` extension is needed by `Main.hs`'s `\case` expressions;
`GHC2024` does not enable it.

```cabal
cabal-version:      3.0
name:               en-migrations
version:            0.1.0.0
synopsis:           pg-migrate-managed PostgreSQL schema for en's relationship tuples
description:
  en's PostgreSQL schema as a pg-migrate migration component: the relation-tuple
  table (with xid8 created/deleted columns for MVCC point-in-time reads), the
  revision / transaction table, the datastore identity row, and the
  garbage-collection horizon high-water mark. SQL is embedded at compile time
  from an ordered manifest and applied by the @en-migrate@ executable.

license:            MIT
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
category:           Security, Authorization, Database
extra-source-files:
  migrations/*.sql
  migrations/manifest

common warnings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions:
    LambdaCase
    OverloadedStrings

library
  import:          warnings, shared
  hs-source-dirs:  src
  default-extensions: TemplateHaskell
  exposed-modules:  En.Migrations
  other-modules:    En.Migrations.Internal.Definition
  build-depends:
    , base              >=4.19 && <5
    , bytestring
    , pg-migrate        ^>=1.1.0.0
    , pg-migrate-embed  ^>=1.1.0.0

executable en-migrate
  import:         warnings, shared
  hs-source-dirs: app
  main-is:        Main.hs
  build-depends:
    , aeson
    , base
    , bytestring
    , en-migrations
    , hasql                 >=1.10 && <1.11
    , optparse-applicative
    , pg-migrate            ^>=1.1.0.0
    , pg-migrate-cli        ^>=1.1.0.0
    , text

test-suite en-migrations-tests
  import:         warnings, shared
  type:           exitcode-stdio-1.0
  hs-source-dirs: test
  main-is:        Main.hs
  build-depends:
    , base
    , en-migrations
    , pg-migrate  ^>=1.1.0.0
```

### Step 9 — Milestone 3: the Justfile

Replace the `make-migration` and `run-migrations` recipes and delete the now-unused
`migrationDate` variable at the top of the file:

```just
# Create a new migration file and register it in the ordered manifest
[group("database")]
make-migration name description="":
  cabal run -v0 en-migrate -- new \
    --manifest en-migrations/migrations/manifest \
    --name {{name}} \
    --description "{{ if description == "" { name } else { description } }}"

# Apply pending PostgreSQL migrations
[group("database")]
run-migrations: create-database
  DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run -v0 en-migrate -- up

# Compare the declared migration plan with the database's ledger
[group("database")]
verify-migrations:
  DATABASE_URL="${EN_DATABASE_URL:-$PG_CONNECTION_STRING}" cabal run -v0 en-migrate -- verify
```

Note that `new` requires the name to fit the manifest's existing numbering: with
`0001-en-bootstrap.sql` present, an explicit `--name 0002-whatever` is expected, and omitting
`--name` yields `0002.sql`.

### Step 10 — Milestone 2 acceptance: prove the squash is exact

This is the step that justifies squashing. It applies the old six files to one database and
the new bootstrap to another, then compares the resulting schemas. Run it before deleting
`en-migrations/db/`.

```console
$ dropdb --if-exists en_old && createdb en_old
$ for f in en-migrations/db/migrations/*.sql; do \
    psql -d en_old -v ON_ERROR_STOP=1 -q -f "$f"; \
  done
$ dropdb --if-exists en_new && createdb en_new
$ DATABASE_URL="postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/en_new" \
    cabal run -v0 en-migrate -- up
$ pg_dump --schema-only --no-owner --no-privileges -d en_old > /tmp/en-old-schema.sql
$ pg_dump --schema-only --no-owner --no-privileges -N pgmigrate -d en_new > /tmp/en-new-schema.sql
$ diff -u /tmp/en-old-schema.sql /tmp/en-new-schema.sql && echo "schemas identical"
schemas identical
```

`-N pgmigrate` excludes `pg-migrate`'s own ledger schema, which by definition has no
counterpart in the old database. `pg_dump --schema-only` does not dump table contents, so
assert the seeded `en_gc_horizon` row separately:

```console
$ psql -d en_old -tAc "SELECT horizon FROM en_gc_horizon"
0
$ psql -d en_new -tAc "SELECT horizon FROM en_gc_horizon"
0
```

Paste the actual `diff` result into Surprises & Discoveries if it is not empty, and reconcile
the bootstrap SQL until it is. Clean up with `dropdb en_old && dropdb en_new`.

### Step 11 — Recreate the development database

The existing `en` database carries the schema applied by the old `psql` probes and has no
`pg-migrate` ledger, so `up` would try to create tables that already exist. It holds only
scratch data:

```console
$ dropdb --if-exists en && createdb en
$ just run-migrations
```

Expect a report naming `en/0001-en-bootstrap` as applied. Run it a second time and expect
`AlreadyApplied`.


## Validation and Acceptance

Each milestone's acceptance is stated above. The end-to-end evidence that the whole change
worked is the following sequence, run from the repository root after Milestone 5.

**The plan is inspectable without a database.** These three commands must succeed with no
PostgreSQL server involved and no `DATABASE_URL` set:

```console
$ cabal run -v0 en-migrate -- plan
$ cabal run -v0 en-migrate -- list
$ cabal run -v0 en-migrate -- check --manifest en-migrations/migrations/manifest
```

`plan` shows the single component `en`. `list` shows one migration,
`en/0001-en-bootstrap`, with its position, kind, transaction mode, and SHA-256 checksum.
`check` lists the manifest's one file with the same checksum. Record the checksum in this
plan's Outcomes section — it is the fingerprint of en's schema from now on.

**Applying is idempotent.** Against a freshly created empty database:

```console
$ dropdb --if-exists en && createdb en
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 en-migrate -- status
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 en-migrate -- up
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 en-migrate -- up
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 en-migrate -- verify
```

The first `status` reports one pending migration. The first `up` reports it `AppliedNow`; the
second reports `AlreadyApplied` and changes nothing. `verify` then succeeds and exits 0.

**Tampering is detected.** This is the guarantee en did not have before. Append a single
space to the end of the applied SQL file, rebuild, and verify:

```console
$ printf ' ' >> en-migrations/migrations/0001-en-bootstrap.sql
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 en-migrate -- verify; echo "exit: $?"
```

Expect a checksum-mismatch issue for `en/0001-en-bootstrap` and exit code 2. Undo the edit
(`git checkout -- en-migrations/migrations/0001-en-bootstrap.sql`), rebuild, and confirm
`verify` succeeds again. Do not "fix" a real mismatch by editing the ledger; the forward path
is always a new appended migration.

**The service runs on the migrated schema.**

```console
$ just start-and-test
server smoke test passed: allowed
```

That recipe brings up `process-compose`, which runs `just run-migrations` (now `en-migrate up`),
builds and executes `en-server`, waits on `/healthz`, then writes a relationship, reads back
a consistency token, and checks a permission against it. A passing smoke test proves the
migrated schema serves real traffic, including the `en_datastore_metadata` row that
`en-server` mints on first startup.

**The full test suite passes.**

```console
$ cabal test all
```

In particular `en-postgres:en-postgres-integration-tests` now migrates its ephemeral database
with the same plan the executable applies, and `en-migrations:en-migrations-tests` evaluates
the plan purely.

**Nothing claims codd anymore.**

```console
$ grep -rn "codd" --include="*.hs" --include="*.cabal" --include="*.nix" \
    --include="*.dhall" --include="*.yaml" --include="*.md" . \
  | grep -v "^./docs/plans" | grep -v "^./docs/masterplans" | grep -v dist-newstyle
```

Expect matches only in this plan file.


## Idempotence and Recovery

Every step here can be repeated. `en-migrate up` is idempotent by construction: it consults
the ledger and applies only what is pending, so running it twice, or running it concurrently
from two processes (the second waits on a PostgreSQL advisory lock), is safe.

The file-creation steps are ordinary `git` work: `git checkout --` any file to start over.
`en-migrate new` refuses to overwrite an existing file and replaces the manifest atomically,
so a failed authoring attempt leaves the manifest consistent.

The riskiest command in this plan is `dropdb en`. That is safe here only because en has no
users and the local development database holds nothing but scratch tuples — the same
justification the user gave for this whole plan. If you are reading this in a future where
that is no longer true, stop: the forward-only path for a database with real data is
`pg-migrate`'s history import (`mori://shinzui/pg-migrate`, `docs/operations/history-import.md`),
not a drop. Do not run `dropdb` against anything you did not create in the last few minutes.

Milestone 1 is the one step that touches another repository. It is a two-line change to a
`.cabal` file on a fork that exists for exactly this purpose; if it goes wrong, revert the
commit there and restore the old `tag:` line in `cabal.project`. Until the new commit is
pushed, en's `cabal.project` can point at a local checkout with a `packages:` entry to
iterate, but the committed state must reference the pushed hash so a fresh clone builds.

If `cabal build` behaves inconsistently after the dependency change, `cabal clean` and
rebuild: the crypton/`ram` swap changes unit-id hashes across a large part of the closure,
and a stale store entry can produce confusing instance errors.

If the manifest-membership check does not fire when you add a stray `.sql` file, check that
the `RecompilePlugin` pragma is present on `En.Migrations.Internal.Definition` and that
`cabal` actually invoked GHC — when no Haskell source changed at all, cabal reports "Up to
date" and never runs the compiler. `cabal build --ghc-options=-fforce-recomp` or a clean
build revalidates.


## Interfaces and Dependencies

### External packages

All four `pg-migrate` packages are at version 1.1.0.0 on Hackage; their source is registered
with Mori as `mori://shinzui/pg-migrate`. Verified against Hackage's preferred-versions
endpoint on 2026-08-24: `["1.1.0.0","1.0.0.0"]`.

`pg-migrate` (`mori://shinzui/pg-migrate/packages/pg-migrate`) supplies the model, plan
validation, ledger, and Hasql runner. `en-migrations`'s library depends on it.

`pg-migrate-embed` (`mori://shinzui/pg-migrate/packages/pg-migrate-embed`) supplies
`embedMigrationManifest` and `RecompilePlugin`. Library dependency of `en-migrations`.

`pg-migrate-cli` (`mori://shinzui/pg-migrate/packages/pg-migrate-cli`) supplies the command
parser, dispatch, and renderers. Dependency of the `en-migrate` executable only — it must not
enter any library's dependency closure.

`pg-migrate-test-support` (`mori://shinzui/pg-migrate/packages/pg-migrate-test-support`)
supplies `withMigratedDatabase`. Test-suite dependency of
`en-postgres:en-postgres-integration-tests` only; it pulls in `ephemeral-pg`, which
`en-postgres`'s integration suite already uses.

`pg-migrate-import-codd` is deliberately not used; see the Decision Log.

The versions en's build plan already resolves satisfy every `pg-migrate` bound: base 4.21.2.0
(needs `>=4.20 && <4.22`), hasql 1.10.3.7 (`>=1.10 && <1.11`), aeson 2.2.5.0, containers 0.7,
bytestring 0.12.2.0, text 2.1.4, time 1.14, ram 0.22.1 (`>=0.20 && <0.23`),
optparse-applicative 0.19.0.0, ephemeral-pg 0.2.1.0 (`>=0.2 && <0.3`). The single exception is
crypton, which Milestone 1 exists to resolve. This was verified with a real solver run: with
the widened biscuit fork in the package set, `cabal build all --dry-run` selects
`pg-migrate-1.1.0.0`, `pg-migrate-embed-1.1.0.0`, `pg-migrate-cli-1.1.0.0`, and
`pg-migrate-test-support-1.1.0.0` alongside every en package.

`pg-migrate` 1.1 supports GHC 9.12.4 and PostgreSQL 17 and 18, which matches en's
`with-compiler: ghc-9.12.4` and the `pkgs.postgresql` in `nix/haskell.nix`.

### Values that must exist at the end of each milestone

At the end of Milestone 2, `En.Migrations` exports:

```haskell
enMigrations    :: Either DefinitionError MigrationComponent
enMigrationPlan :: Either PlanError MigrationPlan
```

and `migrationsDir :: FilePath` no longer exists anywhere.

The `pg-migrate` constructors these are built from:

```haskell
migrationComponentFromEmbeddedSql
  :: Text                              -- component name
  -> Set Text                          -- names of components this one must follow
  -> NonEmpty (FilePath, ByteString)   -- the embedded manifest entries
  -> Either DefinitionError MigrationComponent

migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
```

At the end of Milestone 3, `cabal list-bin en-migrate` resolves and the executable answers
`--help`.

At the end of Milestone 4, `en-postgres/integration-test/Main.hs` uses:

```haskell
withMigratedDatabaseOptions
  :: RunOptions
  -> MigrationPlan
  -> (Connection.Connection -> IO value)
  -> IO (Either MigratedDatabaseError value)
```

from `Database.PostgreSQL.Migrate.Test`, and contains no `CREATE TABLE` text.

### Internal boundaries to respect

`En.Migrations.Internal.Definition` is internal to `en-migrations` and must stay in
`other-modules`; only `En.Migrations` is public. Symmetrically, no en package may import a
module from `pg-migrate` whose name contains `Internal` — those are explicitly outside
`pg-migrate`'s versioning promise.

`en-core` must not gain a `pg-migrate` dependency. It is the transport- and
database-agnostic engine, and the whole point of the `en-migrations` package is that the SQL
lives somewhere `en-core` never looks.
