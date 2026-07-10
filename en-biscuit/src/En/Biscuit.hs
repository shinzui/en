{- |
Module      : En.Biscuit
Description : Optional Biscuit decision-token integration for en.

This is the top-level module for the optional @en-biscuit@ package. It
re-exports the public surface so that a single @import En.Biscuit@ brings it all
into scope:

  * "En.Biscuit.Grant" — the typed grant model and the stable Biscuit Datalog
    predicate vocabulary.
  * "En.Biscuit.Keys" — issuer key identity, verifier keysets, and key-material
    text codecs for issuer-key rotation.
  * "En.Biscuit.Mint" — minting helpers that turn successful en decisions into
    signed Biscuit tokens.
  * "En.Biscuit.Verify" — local, fail-closed verification and attenuation of
    those tokens in a downstream service.
-}
module En.Biscuit (
    module En.Biscuit.Grant,
    module En.Biscuit.Keys,
    module En.Biscuit.Mint,
    module En.Biscuit.Verify,
) where

import En.Biscuit.Grant
import En.Biscuit.Keys
import En.Biscuit.Mint
import En.Biscuit.Verify
