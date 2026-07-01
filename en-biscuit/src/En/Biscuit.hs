{- |
Module      : En.Biscuit
Description : Optional Biscuit decision-token integration for en.

This is the top-level module for the optional @en-biscuit@ package. It
re-exports the public surface so that a single @import En.Biscuit@ brings it all
into scope:

  * "En.Biscuit.Grant" — the typed grant model and the stable Biscuit Datalog
    predicate vocabulary.
  * "En.Biscuit.Mint" — minting helpers that turn successful en decisions into
    signed Biscuit tokens.
  * ExecPlan 31 adds local verification and attenuation ("En.Biscuit.Verify").

Those later modules are re-exported here as they land.
-}
module En.Biscuit (
    module En.Biscuit.Grant,
    module En.Biscuit.Mint,
) where

import En.Biscuit.Grant
import En.Biscuit.Mint
