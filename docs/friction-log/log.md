# Bundle Update Log

## 2026-11-13

* **Update**: FRIC-1 accepted: Accepted under ADR 7's measured-exception policy; the same cost recurred from ExecPlan 70, which is why the ADR section was extended rather than a new rule written


* **Addition**: FRIC-1 records slowdown interface friction with mori://ekmett/lens: Generic-lens labels on a new internal record were not optimised away in the lookup hot path

* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
