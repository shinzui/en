-- | Engine error type. The closed set of ways an en operation can fail.
module En.Error
  ( EnError (..)
  ) where

import Data.Text (Text)

-- | Authorization-engine failures. Authn (identity) failures are shomei's concern,
-- not en's; en only reports failures of the relationship/authorization layer.
data EnError
  = -- | The referenced object type / relation is not in the active schema.
    UnknownRelation Text
  | -- | A relationship tuple referenced a subject/object that violates the schema.
    SchemaViolation Text
  | -- | A caveat could not be evaluated because required context was missing.
    MissingCaveatContext [Text]
  | -- | The supplied consistency token is invalid or outside the GC window.
    InvalidConsistencyToken Text
  | -- | The traversal exceeded the configured depth/breadth bound.
    ResolutionLimitExceeded
  | -- | The underlying tuple store failed.
    StoreError Text
  deriving stock (Eq, Show)
