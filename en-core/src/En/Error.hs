-- | Engine error type. The closed set of ways an en operation can fail.
module En.Error (
    EnError (..),
) where

import Data.Text (Text)

{- | Authorization-engine failures. Authn (identity) failures are shomei's concern,
not en's; en only reports failures of the relationship/authorization layer.
-}
data EnError
    = -- | The referenced object type / relation is not in the active schema.
      UnknownRelation Text
    | -- | A relationship tuple referenced a subject/object that violates the schema.
      SchemaViolation Text
    | -- | A caveat could not be evaluated because required context was missing.
      MissingCaveatContext [Text]
    | -- | The supplied consistency token is invalid or outside the GC window.
      InvalidConsistencyToken Text
    | {- | A pagination cursor was malformed or does not belong to this store.
      Carries the cursor's rendering.

      Distinct from 'InvalidConsistencyToken' (a different artifact, obtained a
      different way) and from 'StoreError' (an outage, and retryable). Resuming a
      page is only meaningful with a cursor the store itself issued; anything
      else is a client fault, and restarting the scan from the beginning in its
      place would silently duplicate results.
      -}
      InvalidCursor Text
    | -- | A configured evaluation budget (depth, breadth) was exhausted.
      ResolutionLimitExceeded
    | {- | The traversal re-entered a subproblem it is already evaluating: the
      relationship data contains a cycle. Carries a rendering of the subproblem,
      e.g. @"space:recursive#view"@.

      'En.Check.check' and 'En.Lookup.lookup' never raise this. They compute set
      membership, and a cycle contributes no members, so they treat a revisit as
      an empty result. 'En.Expand.expand' does raise it, because it renders a
      tree for a human to audit and silently omitting a cyclic branch would hide
      data from the reviewer.
      -}
      CycleDetected Text
    | {- | A write precondition did not hold inside the write transaction, so the
      write was refused and nothing was applied. Carries a rendering of the
      failing precondition, e.g. @"must-exist: space:project-x#member\@user:alice"@.

      This is an arbitration loss, not an outage: the caller read a state, decided
      on it, and by the time the write ran that state was gone. Retrying without
      re-reading will fail again.
      -}
      WritePreconditionFailed Text
    | -- | The underlying tuple store failed.
      StoreError Text
    deriving stock (Eq, Show)
