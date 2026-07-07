# en review — architecture, performance, missing features (2026-07-07)

Full-codebase review of en as of commit `919b8b4`, covering all seven packages, with en
assessed against its two intended postures: standalone embedded library and
authorization microservice. Findings were gathered by parallel deep reads of en-core,
en-postgres/en-migrations, en-servant/en-server/en-client/en-biscuit, plus a feature-gap
analysis against Google Zanzibar, SpiceDB, OpenFGA, and Ory Keto.

Severity legend: **CRITICAL** (unsafe to deploy), **HIGH** (fails or degrades badly on
realistic inputs/load), **MED** (correctness edge or meaningful operational cost),
**LOW** (hygiene, minor waste).

## Verdict

The foundations are unusually strong — the consistency-token machinery, caveat model,
and schema type-safety story are at or above the level of the open-source references for
the stated scope ("one org, one Postgres, Haskell-first"). But the project is a hot core
wrapped in a cold shell: the `check` evaluation path fails outright on realistic data
shapes, and the standalone server is not deployable as a microservice today — its API is
unauthenticated, it runs on a single database connection, and it has no health checks,
metrics, or scheduled garbage collection. The embedded-library posture is genuinely
good; the service posture is a prototype.

## Strengths (keep these)

- Package split is real: en-core verifiably has zero Servant/WAI/PostgreSQL deps; the
  two-effect design (`TupleStore`, `ConsistencyStore`) with in-memory interpreters gives
  embedded and hosted consumers one code path.
- The `Env es` record-of-operations seam (`en-servant/src/En/Servant/Seam.hs:37`) cleanly
  swaps cached/uncached/test variants.
- `ValidSchema` evidence type + compile-time quasi-quoter + thorough schema validation
  (arrow-target compatibility, productive-cycle analysis, duplicate detection).
- Consistency layer is best-in-class for a homegrown zookie implementation: opaque
  revisions with deliberately no `Ord` (new-enemy fix), all four Zanzibar modes,
  `pg_snapshot` partial order oracle-tested against PostgreSQL itself, GC horizon shared
  between token validation and the reaper, xid8 everywhere (no wraparound hazard).
- Storage layer: keyset pagination, prepared statements throughout, `unnest`-batched
  subject fan-in.
- Fail-closed discipline is consistent (403 on `Conditional`, Biscuit mint refuses
  non-`Allowed`); Biscuit fact-injection safety is proven by test, not asserted.
- The en-biscuit decision-token layer is a differentiator none of the references has.

---

## Theme A — Service production-readiness

### A1. CRITICAL — en-server API is completely unauthenticated
`en-servant/src/En/Servant/API.hs:112` serves the API bare; `en-server/app/Main.hs:137`
runs it with no auth combinator, middleware, mTLS, or token check. Anyone with network
reach can `POST /tuples` to grant themselves any permission or `DELETE /tuples` to erase
the graph. The en-servant.cabal description promises gating "against the caller's
verified shomei identity (kikan C11)"; nothing wires it in. No TLS (warp, not warp-tls;
no documented reverse-proxy assumption). No rate limiting — an authorization service is
a DoS amplifier (each check fans out DB reads).

### A2. HIGH — single shared hasql connection, no pooling, no reconnect
`en-server/app/Main.hs:48-89` acquires one `Connection.acquire` and threads it through
every request. hasql's `Connection` is an `MVar`, so all concurrent Warp requests
serialize on one libpq socket — a hard throughput ceiling — and a dropped connection
(Postgres restart, idle timeout) fails every request forever. The
`bracket (pure connection) …` at `Main.hs:136` is inert (acquisition happens outside
the bracket; `Warp.run` never returns). Fix: hasql-pool.

### A3. HIGH — error model collapses to 500 and leaks internals
`enErrorToServerError = jsonError err500 . Text.pack . show`
(`en-servant/src/En/Servant/Seam.hs:58-60`). Client faults (stale cursor, unknown
relation, foreign-datastore token, `ResolutionLimitExceeded`) are indistinguishable from
storage outages; derived `Show` output becomes an unstable wire contract; no
machine-readable error code; servant's own body-decode failures return plain text, so
the JSON error envelope isn't uniform.

### A4. HIGH — no health/readiness, graceful shutdown, or observability
No `/healthz`/`/readyz` (the Justfile readiness loop curls `/` and accepts the 404,
`Justfile:37-40`). No `setGracefulShutdownTimeout`/`setInstallShutdownHandler` — SIGTERM
kills in-flight requests. Logging is startup-only `Text.putStrLn`; no request logging,
request IDs, metrics (in-process `cacheStats` exist but are exported nowhere), or
tracing. process-compose.yaml manages only Postgres.

### A5. MED — wire format leaks constructor names; no versioning
Generic Aeson puts `"tag":"AllowedWire"`, `"AtLeastAsFreshWire"` etc. on the wire; the
internal `Wire` suffix is frozen into the public API. No `/v1` prefix or version header
exists to fix it compatibly. `DELETE /tuples` carries a request body (`API.hs:94`),
which proxies mishandle. Batch response is a bare positional list (`API.hs:221-225`).

### A6. MED — hardcoded datastore identity; unvalidated config
`DatastoreId "en-server"` hardcoded (`en-server/app/Main.hs:59-60`): two deployments
against different databases mint indistinguishable tokens, defeating the cross-datastore
token guard. Identity should be minted once and persisted in the database (as SpiceDB
does). `EN_GC_WINDOW` is passed as raw Text with no interval-syntax validation
(`Main.hs:37,62`). Also: after dump/restore or failover the xid8 epoch resets and old
tokens validate against a meaningless xid counter — nothing detects this.

### A7. MED — client-supplied lookup deadline is unbounded; defaults hardcoded
`API.hs:397-405` clamps only the negative direction: `deadlineMillis: 86400000` holds a
worker for a day. The 3000 ms default is baked into en-servant despite plan 16's
"configurable" intent. Check, batch-check, and expand have no deadline budget at all;
`maxBatchSize = 1000` is hardcoded (`en-server/app/Main.hs:130`).

### A8. MED — `requirePermission` is a helper, not the advertised combinator
en-servant.cabal and the README describe a Servant combinator; the implementation is a
plain `Handler ()` helper (`Authorize.hs:14-37`). The guarantee is call discipline, not
types. Defensible design, but the packaging oversells it (untracked plan 27 suggests
this is known).

### A9. LOW — operational drift
README says migrations are codd-managed; the Justfile applies them with raw `psql` and
`to_regclass` checks (`Justfile:55-65`). en-server tells users to "run the codd
migrations" (`Main.hs:54-56`) but never verifies migration state. en-client is only the
servant-client record — no ClientEnv/BaseUrl construction, timeouts, retry policy,
pagination helper, or token-threading convenience.

---

## Theme B — Check engine: correctness and performance

### B1. HIGH — check errors out on any relation wider than one page
`ensureExhausted` (`en-core/src/En/Check.hs:567-572`): `evalThis`/`evalTupleToUserset`
issue a single `readObjectRelation … pageLimit Nothing` (`Check.hs:399,433,506,539`) and
convert `HasMore`/`Truncated` into `ResolutionLimitExceeded`. A document with 1001
direct viewers makes every check on it *fail*. Lookup and expand drain pages
(`Lookup.hs:492-509`, `Expand.hs:262-270`); check does not — the three algorithms
disagree about what a large relation means.

### B2. HIGH — check full-scans the object-relation instead of probing membership
`evalThisMemo` (`Check.hs:395-417`) reads all rows for `object#relation`, compares each
subject linearly, allocates a per-row decision list, and recurses sequentially into
every `SubjectSet` row. The store already has the right batched primitive
(`ReadStartingWithUser`/`UsersetQuery`, `En/Effect/TupleStore.hs:74-81`) which lookup
uses; check never does. A group with 900 members costs 900 rows per direct-membership
check; nested groups multiply. Combined with B1, check is only viable on narrow
relations. A point-membership store primitive (`HasTuple`-style probe) is missing.

### B3. HIGH — data cycles poison unrelated union branches
Revisiting a subproblem is an error, not an empty result
(`Check.hs:274-275`), and union combines via `sequence` (`Check.hs:342-345,404`), so one
cyclic branch converts the whole check to `ResolutionLimitExceeded` even when another
branch already proved `Allowed`. Two mutually-nested groups (legal data) make every
check that touches them fail — and `checkMany` reports that as `Denied`
(`Check.hs:112-117`). Zanzibar semantics: a revisited subproblem contributes no members.
Union also never short-circuits on the first `Allowed`. `EnError` cannot distinguish
"depth exceeded" from "cycle detected".

### B4. MED — exclusion with a Conditional base never evaluates the subtrahend
`Check.hs:355,484`: base `Conditional` returns immediately. If the subtract branch is
unconditionally `Allowed`, the true answer is `Denied`, yet the engine reports
`Conditional` — a false "supply context and you may pass" for a subject who provably
cannot. `Decision.exclusion` (`Decision.hs:65-70`) likewise passes subtract-side
obligations through unmarked.

### B5. MED — `checkMany` maps all errors to `Denied`
`Check.hs:112-117` — including `UnknownRelation` and store failures. Fail-closed is
right, but callers cannot distinguish denial from outage per pair; the signature also
drops the `Error EnError` constraint `check` has.

### B6. MED — decision-cache key includes full `CaveatContext`
`SubproblemKey` (`En/Cache.hs:92-100`, used at `Check.hs:248-257`). Any context carrying
`current_time` (the canonical caveat) makes every request's key unique → ~0%
cross-request hit rate for caveated schemas. SpiceDB caches context-free subproblem
results and re-applies caveats.

### B7. MED — lookup confirmation re-resolves consistency and is N+1
`confirmCandidates` (`Lookup.hs:473-481`) calls `check` per intersection/exclusion
candidate with the original `Consistency`; `check` re-runs `resolveConsistency`
(`Check.hs:66-68`), so one lookup can span multiple snapshots under
`MinimizeLatency`/`FullyConsistent`. Each confirmation is a full check with its own
store reads and no shared memo.

### B8. MED — lookup/expand recompute the full traversal per page; deadline doesn't bound work
`runLookup` materializes all candidates, then `pageLookup` slices (`Lookup.hs:587-608`);
each subsequent page re-runs the whole traversal. The deadline is consulted once, after
traversal (`Lookup.hs:589`) — it relabels `HasMore` as `Truncated` but never interrupts
expansion, contradicting the "streamed" claim at `Lookup.hs:105-108`. `resultCap = 1000`
applies only at page slicing, so intermediate sets are unbounded. Expand has the same
shape (`Expand.hs:278-289`).

### B9. MED — lookup cursor revision is client-forgeable
With a cursor present, `lookupWithDeadlineWithChecker` takes the revision straight from
client-supplied text (`Lookup.hs:170-176`) — no `validateToken`, no datastore/schema/GC
check, unlike `ConsistencyToken`. A forged or expired cursor reads at an arbitrary
revision, including past the GC horizon.

### B10. MED — expand's tree erases set operators
`Intersection`/`Exclusion`/`Union` all flatten to concatenated children
(`Expand.hs:170-179`); `ExpandNode` (`Expand.hs:57-61`) has no operator constructors. An
audit UI cannot distinguish "needs all" from "any" from "except" — a correctness problem
for access review, not just a gap.

### B11. MED — compiled `EntryPoint` graph is dead weight
`graph.entries` is consumed only by `En/Schema/Render.hs` and tests; check/lookup/expand
walk the rewrite AST directly. Half of `En/Reachability.hs` (65-188) is speculative —
either wire lookup to it or move it to the render layer.

### B12. LOW — hot-path allocation and contention
List-append per tuple row inside `foldM` (`Check.hs:381,408-417,444`); `acc <> page.rows`
per page in drains; O(n²) `elem` dedupe (`Decision.hs:76-82`, `Caveat.hs:142-148`);
`visited` as a list. Single-`IORef` cache mutates stats on every hit/miss even when
disabled (`Cache.hs:114-128`), a CAS contention point under concurrency; FIFO eviction
with O(n) `oldestKey` (`Cache.hs:162-180`). Hard-coded `maxDepth = 25`,
`pageLimit = 1000`, `resultCap = 1000` duplicated across three modules with no
per-engine or per-request configuration. `mergeLookupObjects` rebuilds/re-sorts a Map at
every union node (`Lookup.hs:538-552`). FNV-1a-64 is a weak fingerprint for a hash that
gates cache correctness across schema changes (`Schema.hs:409-414`). All evaluation
fan-out is strictly sequential (`Check.hs:93-94` punts concurrency to the transport).

---

## Theme C — Storage and write semantics

### C1. MED-HIGH — caveat updates are silent no-ops / duplicate live grants
`relation_tuple_live_unique` includes `coalesce(caveat_name,'')`
(`en-migrations` create-relation-tuples migration:23-33); inserts use bare
`ON CONFLICT DO NOTHING` (`en-postgres/src/En/Postgres/TupleStore.hs:344-363`).
Consequences: (1) rewriting a live tuple with a different caveat *payload* (same name)
silently drops the new payload while returning a success token; (2) writing the same
(object, relation, subject) with a different caveat *name* (e.g. adding a caveat to
tighten an uncaveated grant) creates a second live row while the unconditional grant
stays live. SpiceDB keys uniqueness on (resource, relation, subject) with touch
semantics. This is an authorization-correctness trap.

### C2. HIGH — `en_transaction` grows forever and is scanned on every read
`oldestRetainedXidStatement` (`TupleStore.hs:290-299`) filters on `created_at`, which
has no index (PK is on `xid` only); nothing ever prunes the table (the reaper only
touches `relation_tuple`); `ResolveConsistency` (`Revision.hs:315-326`) runs it on every
read. Read latency degrades linearly with lifetime write count. Fix: index
`(created_at, xid)` (or BRIN) and prune behind the horizon in the reaper.

### C3. MED — 2–3 sequential revision round trips per read
`ResolveConsistency` unconditionally fetches optimized revision, head revision, and GC
horizon even for modes that don't need them; with the default
`EN_OPTIMIZED_REVISION_CACHE_TTL_MS` of 0 the cache is disabled, so that's three
sequential round trips per request on the single shared connection (A2). Fetch lazily
per mode; the horizon is a natural candidate for the same TTL cache.

### C4. MED — reaper never scheduled; unbatched reap
Nothing in en-server runs `reapDeletedTuples`, so soft-delete bloat is unbounded. When
run, it is one unbounded `DELETE` (`TupleStore.hs:301-314`) — long row-lock-holding,
WAL-heavy; it should loop with LIMITed batches.

### C5. MED — write token over-claims freshness (`AtExactSnapshot` instability)
`writeVisibleSnapshot` (`TupleStore.hs:233-247`) sets `xmax = max(snapshot.xmax, xid+1)`,
leaving any xid assigned between the anchor's real xmax and the write's xid *visible*
without being in `xip`. Concurrent transactions committing after token issuance are then
included by later `AtExactSnapshot` reads — reads at a token are not repeatable (mild
new-enemy-adjacent hazard for revocations racing a write). Tighter construction:
`xip ∪ [snapshot.xmax .. xid-1]`.

### C6. MED — per-tuple insert round trips
`writeTuplesSession`/`deleteTuplesSession` (`TupleStore.hs:157-175`) issue one statement
per tuple (N+4 round trips for N tuples). Use `unnest` multi-row DML (the read path
already uses the pattern).

### C7. LOW-MED — GC TOCTOU
Token validation reads the horizon, then the tuple read runs later; a reap in between
yields a silently incomplete result instead of `InvalidConsistencyToken`. Acceptable if
GC window ≫ request duration — but that invariant is undocumented (EP-14 doesn't state
it).

### C8. LOW — silent-degradation decodes
(1) `decodeCursor` (`TupleStore.hs:667-671`) maps malformed cursors to `0`, silently
restarting pagination (duplicates). (2) `decodeTupleCaveat` (`TupleStore.hs:574-585`)
maps an undecodable `caveat_payload` to an empty payload — which can change an
authorization decision; should be `StoreError`. (3) `writeVisibleSnapshot`'s
parse-failure fallback returns a token that quietly does not see its own write.
(4) `pageFromRows` (`TupleStore.hs:203-215`) has a cursor off-by-one at `limit = 0`
(unreachable at normal limits, but the path exists).

### C9. LOW — dead indexes
`relation_tuple_object_live_idx`, `relation_tuple_subject_live_idx`
(migration:35-42), and `relation_tuple_created_xid_idx` are unusable by every query in
the codebase (read predicates use `pg_visible_in_snapshot`, never bare
`deleted_xid IS NULL`) — pure write amplification unless reserved for a future watch
feed (if so, document it). `readStartingWithUser`'s global `ORDER BY id LIMIT` across
unnested subject keys forces a sort of all matching rows before the limit — verify with
EXPLAIN at large fan-in.

### C10. Verified non-issue
Hand-rolled `BEGIN`/`COMMIT` without `ROLLBACK` looked like connection poisoning, but
the hasql version in use resets aborted transactions (`bringTransactionStatusToIdle`).
`hasql-transaction` would still make the discipline explicit and add
serialization-failure retries.

---

## Theme D — Biscuit layer

### D1. MED — key management and revocation are thin
`MintConfig.issuerSecretKey` is a raw in-memory `SecretKey` (`Mint.hs:87-90`);
`verifyGrant` accepts exactly one `PublicKey` (`Verify.hs:185-191`) — no key id in the
token, no multi-key acceptance, so rotation requires simultaneous redeploy of every
verifier. Revocation is opt-in per token (`revocationId :: Maybe`; `Verify.hs:198`
treats absence as never-revoked) — a token minted without one is irrevocable until
expiry. Biscuit's built-in unconditional per-block revocation ids are unused.

### D2. MED — attenuation-injection semantics untested
`extractAndCheck` reads grant facts via `queryRawBiscuitFacts` (`Verify.hs:385`);
correctness depends on biscuit-haskell scoping block-added facts out of that query. The
suite proves mint-time injection safety but has no test that a *holder-attenuated* block
adding forged `en_right`/`en_expires_at` facts is ignored/rejected. One test pins the
dependency's semantics.

### D3. MED — no HTTP minting path
Minting is embedded-only; a pure HTTP consumer of en-server cannot obtain decision
tokens. Compounded by reads not returning consistency tokens (E3) — `EnGrant` requires a
`ConsistencyToken` (`Grant.hs:103`) whose natural source, the check response, doesn't
supply one. No sealed-token support surfaced, no third-party blocks, no standard header
convention.

---

## Theme E — Missing features (gap analysis vs Zanzibar/SpiceDB/OpenFGA/Keto)

Present and strong (no action): full rewrite algebra (union/intersection/exclusion/
arrow), wildcards, type restrictions, typed caveats, check + batch-check, cursored
lookup-resources and expand, zookies with all four consistency modes, quantization
window, three cache tiers with revision-keyed invalidation, embedded mode, conformance
harness, schema renderers.

| # | Feature | Status | Library impact | Service impact |
|---|---------|--------|----------------|----------------|
| E1 | Write preconditions / OCC (Zanzibar lock tuples, SpiceDB preconditions) | Absent — `WriteTuples :: [Tuple] -> ConsistencyToken`, no precondition arg; also no atomic mixed write ("touch"/replace) | Med | **High** — concurrent grant/revoke race; also the clean fix for C1 |
| E2 | Read-relationships endpoint + delete-by-filter | Effects exist (`readObjectRelation`, `readStartingWithUser`); no HTTP surface; deletes require exact tuples | Low | **High** — no way to audit "what grants exist for X" or offboard a user without bespoke SQL |
| E3 | Checked-at tokens on read responses | Absent — only writes return tokens (`CheckResponseWire` is decision-only, `API.hs:199-203`) | Med | **High** — breaks zookie chaining; blocks D3 |
| E4 | Lookup-subjects (flat, cursored "who has access") | Absent — expand is a tree, and it erases operators (B10) | Med | **High** — sharing dialogs, access review, notification fan-out |
| E5 | Watch / changelog API | Absent (deliberately deferred, spec §2) | Med | **High** — cache invalidation, search-index ACL sync, Biscuit revocation feed; the xid8 soft-delete design means the changelog already exists in the tables |
| E6 | Schema-change story for live data | Partial — hash rotation hard-invalidates all tokens; no tuple-vs-new-schema validation, no compatible-change taxonomy, no reload (startup-only `EN_SCHEMA_PATH`), no read-schema endpoint | Med | **High** |
| E7 | Health, metrics, request logging, graceful shutdown | Absent (A4) | — | **High** |
| E8 | Auth on en's own API + rate limiting | Absent (A1) | — | **Critical** |
| E9 | Bulk import/export | Absent — per-row round trips and anchoring | Low | Med |
| E10 | Multi-tenancy | Absent — one schema/datastore per process (acceptable for stated scope) | Low | Med |
| E11 | OpenAPI spec / gRPC / non-Haskell SDKs | Absent; servant-openapi3 nearly free; gRPC/SDKs are reasonable non-goals | — | Med |
| E12 | Explain/trace for check decisions | Absent (unused `EntryPoint.path` machinery is halfway there) | Med | Med |
| E13 | Wire streaming (NDJSON/SSE) for large lookups | Absent — cursor-loop only | Low | Low-Med |
| E14 | Caveat DSL extensions (arithmetic, durations, CIDR/prefix, list params, cross-caveat composition) | Absent, partly by design; enum ordering is positional and undocumented at use site | Low-Med | Low-Med |

Explicit non-goals that should stay non-goals for now: horizontal dispatch, distributed
caching, CEL compatibility.

---

## Recommended priority order

1. **A1** — auth on the server API (+ TLS posture, rate limiting). Everything else is
   moot for service deployment without it.
2. **B1 + B2 + B3** — check's evaluation strategy: point-membership probe primitive,
   page-draining semantics, cycle-as-empty-set, union short-circuit. One coherent piece
   of work; the difference between "works on demos" and "works on real group sizes".
3. **A2 + C2 + C4** — connection pooling, `en_transaction` index/pruning, scheduled
   reaper. Three small operational time bombs.
4. **E1 + C1** — write preconditions and touch semantics; one design fixes both the OCC
   gap and the caveat-update trap.
5. **A3 + E3** — typed wire error model and checked-at tokens on reads; cheap, and both
   unblock downstream features (HTTP Biscuit minting, client retry policy).
6. **E5** — watch API is the highest-leverage feature after those; the changelog already
   exists in the tables.
