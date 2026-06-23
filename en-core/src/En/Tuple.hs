{- | Relationship tuples — the unit of authorization data.

A tuple says: @subject@ has @relation@ on @object@ (optionally under a caveat
context). The subject may be a concrete id or a /userset/ (another object's
relation), which is how Zanzibar expresses groups-of-groups.
-}
module En.Tuple (
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    CaveatValue (..),
    CaveatPayload (..),
    CaveatContext (..),
    TupleCaveat (..),
) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)

import En.Schema (CaveatName, ObjectType, RelationName)

-- | A concrete object, e.g. @intention:42@.
data ObjectRef = ObjectRef
    { objectType :: !ObjectType
    , objectId :: !Text
    }
    deriving stock (Eq, Ord, Show)

{- | The subject of a tuple: either a concrete object id, or a userset
(@object#relation@) which expands to that relation's members.
-}
data Subject
    = SubjectId ObjectRef
    | SubjectSet ObjectRef RelationName
    deriving stock (Eq, Ord, Show)

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

-- | A named caveat plus the tuple-local arguments supplied at write time.
data TupleCaveat = TupleCaveat
    { name :: !CaveatName
    , payload :: !CaveatPayload
    }
    deriving stock (Eq, Ord, Show)

-- | @subject@ has @relation@ on @object@, optionally caveated.
data Tuple = Tuple
    { object :: !ObjectRef
    , relation :: !RelationName
    , subject :: !Subject
    , caveat :: !(Maybe TupleCaveat)
    }
    deriving stock (Eq, Ord, Show)
