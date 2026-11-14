# Bundle Update Log

## 2026-11-14

* **Update**: FRIC-4 accepted: Status set to accepted.

* **Addition**: FRIC-4 records detour tooling friction with mori://shinzui/en: just hurl does not run the write-path Hurl flow

## 2026-11-13

* **Update**: FRIC-3 accepted: Status set to accepted.


* **Addition**: FRIC-3 records detour environment friction with mori://shinzui/ephemeral-pg: macOS SysV shared memory limit fails parallel ephemeral PostgreSQL


* **Update**: FRIC-2 accepted: Status set to accepted.


* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/en: just start-and-test cannot run when port 8080 is taken


* **Update**: FRIC-1 accepted: Accepted under ADR 7's measured-exception policy; the same cost recurred from ExecPlan 70, which is why the ADR section was extended rather than a new rule written


* **Addition**: FRIC-1 records slowdown interface friction with mori://ekmett/lens: Generic-lens labels on a new internal record were not optimised away in the lookup hot path

* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
