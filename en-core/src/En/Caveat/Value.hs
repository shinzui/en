-- | Caveat values shared by schema definitions and relationship tuples.
module En.Caveat.Value (
    CaveatValue (..),
    CaveatPayload (..),
    CaveatContext (..),
) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)

-- | Concrete values accepted by the bounded caveat evaluator.
data CaveatValue
    = ValueText !Text
    | ValueBool !Bool
    | ValueInteger !Integer
    | ValueTimestamp !UTCTime
    | ValueEnum !Text
    deriving stock (Eq, Ord, Show)

-- | Arguments stored on a tuple with a named caveat.
newtype CaveatPayload = CaveatPayload (Map Text CaveatValue)
    deriving stock (Eq, Ord, Show)

{- | Request-time facts evaluated by caveats, e.g. current time or requested
autonomy level.
-}
newtype CaveatContext = CaveatContext (Map Text CaveatValue)
    deriving stock (Eq, Ord, Show)
