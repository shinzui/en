---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Generic-lens labels on a new internal record were not optimised away in the lookup hot path](1-generic-lens-labels-on-a-new-internal-record-were-not-optimised-away-in-the-lookup-hot-path.md) - Reading a new Evaluated record through #objects/#assumed, as the project's label convention suggests, cost about a third of the smallest lookup benchmark, and the cause took six bench cycles of bisection to find.
- [just start-and-test cannot run when port 8080 is taken](2-just-start-and-test-cannot-run-when-port-8080-is-taken.md) - The start-and-test recipe and the process-compose en-server assume port 8080; with another process on 8080 the Hurl suite hits the wrong server, and EN_PORT alone does not move the Hurl base URL (EN_SERVER_URL does), nor the process-compose readiness probe.
- [macOS SysV shared memory limit fails parallel ephemeral PostgreSQL](3-macos-sysv-shared-memory-limit-fails-parallel-ephemeral-postgresql.md) - macOS allows 32 System V shared memory segments system-wide (kern.sysv.shmmni); each ephemeral-pg instance holds one, so a test suite running a case per core with two instances each fails initdb with 'could not create shared memory segment: No space left on device'.
