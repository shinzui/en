-- | Relationship tuples — the unit of authorization data.
--
-- A tuple says: @subject@ has @relation@ on @object@ (optionally under a caveat
-- context). The subject may be a concrete id or a /userset/ (another object's
-- relation), which is how Zanzibar expresses groups-of-groups.
module En.Tuple
  ( ObjectRef (..)
  , Subject (..)
  , Tuple (..)
  , CaveatContext (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

import En.Schema (CaveatName, ObjectType, RelationName)

-- | A concrete object, e.g. @intention:42@.
data ObjectRef = ObjectRef
  { objectType :: ObjectType
  , objectId   :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | The subject of a tuple: either a concrete object id, or a userset
-- (@object#relation@) which expands to that relation's members.
data Subject
  = SubjectId ObjectRef
  | SubjectSet ObjectRef RelationName
  deriving stock (Eq, Ord, Show)

-- | Free-form context evaluated by a caveat at check/lookup time
-- (e.g. @current_time@). Concrete value type is refined alongside the caveat
-- evaluator; a string map is the placeholder.
newtype CaveatContext = CaveatContext (Map Text Text)
  deriving stock (Eq, Show)

-- | @subject@ has @relation@ on @object@, optionally caveated.
data Tuple = Tuple
  { object   :: ObjectRef
  , relation :: RelationName
  , subject  :: Subject
  , caveat   :: Maybe CaveatName
  }
  deriving stock (Eq, Ord, Show)
