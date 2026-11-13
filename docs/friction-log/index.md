---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Generic-lens labels on a new internal record were not optimised away in the lookup hot path](1-generic-lens-labels-on-a-new-internal-record-were-not-optimised-away-in-the-lookup-hot-path.md) - Reading a new Evaluated record through #objects/#assumed, as the project's label convention suggests, cost about a third of the smallest lookup benchmark, and the cause took six bench cycles of bisection to find.
