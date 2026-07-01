{- |
Module      : En.Biscuit
Description : Optional Biscuit decision-token integration for en.

This is the top-level module for the optional @en-biscuit@ package. It exists
so that later ExecPlans have a real compilation target:

  * ExecPlan 29 adds the grant vocabulary ("En.Biscuit.Grant") and the stable
    Biscuit Datalog predicate names.
  * ExecPlan 30 adds minting helpers ("En.Biscuit.Mint") over en decisions.
  * ExecPlan 31 adds local verification and attenuation ("En.Biscuit.Verify").

As those modules land, they are re-exported from here so that a single
@import En.Biscuit@ brings the public surface into scope. For now this module
only establishes the package; it intentionally exports nothing.
-}
module En.Biscuit () where
