# en-server black-box API suite

This Hurl suite targets an already-running PostgreSQL-backed `en-server`. The default
runner is read-only. Setup, fixture requirements, opt-in mutation, and authentication
perimeter instructions are completed as the remaining ExecPlan milestones land.

From the repository root, start the local stack and run the safe suite:

```bash
just process-up
just hurl
```
