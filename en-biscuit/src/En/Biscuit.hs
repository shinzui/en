{- |
Module      : En.Biscuit
Description : Optional Biscuit decision-token integration for en.

This is the top-level module for the optional @en-biscuit@ package. It
re-exports the public surface so that a single @import En.Biscuit@ brings it all
into scope:

  * "En.Biscuit.Grant" — the typed grant model and the stable Biscuit Datalog
    predicate vocabulary (this plan).
  * ExecPlan 30 adds minting helpers ("En.Biscuit.Mint") over en decisions.
  * ExecPlan 31 adds local verification and attenuation ("En.Biscuit.Verify").

Those later modules are re-exported here as they land.
-}
module En.Biscuit (
    module En.Biscuit.Grant,
) where

import En.Biscuit.Grant
