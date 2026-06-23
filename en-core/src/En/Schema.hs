-- | The authorization model, supplied by the consuming project as a value.
--
-- This is the schema-parametric heart of en: @en@ ships no built-in model; a
-- consumer (e.g. kikan) constructs a 'Schema' describing its object types,
-- relations, permission rewrite rules, and caveats. The engine compiles a
-- 'Schema' into a reachability graph ("En.Reachability") and evaluates
-- 'En.Check.check' / 'En.Lookup.lookup' against it.
--
-- The vocabulary is deliberately the Zanzibar core (relations + userset rewrites)
-- plus bounded caveats. See @docs/spec/0001-en-overview.md@.
module En.Schema
  ( Schema (..)
  , ObjectType (..)
  , RelationName (..)
  , Relation (..)
  , Rewrite (..)
  , CaveatName (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

newtype ObjectType = ObjectType Text
  deriving stock (Eq, Ord, Show)

newtype RelationName = RelationName Text
  deriving stock (Eq, Ord, Show)

newtype CaveatName = CaveatName Text
  deriving stock (Eq, Ord, Show)

-- | A complete authorization model: every object type and its relations.
newtype Schema = Schema
  { objectTypes :: Map ObjectType (Map RelationName Relation)
  }
  deriving stock (Eq, Show)

-- | A relation is a name plus the rewrite rule that computes its effective members.
data Relation = Relation
  { relationName :: RelationName
  , rewrite      :: Rewrite
  }
  deriving stock (Eq, Show)

-- | Userset-rewrite expressions — the Zanzibar relation algebra. @en@ leans on
-- 'Union', 'ComputedUserset', and 'TupleToUserset'; 'Intersection' / 'Exclusion'
-- are supported but are the expensive, non-streaming cases for 'En.Lookup.lookup'.
data Rewrite
  = -- | Directly assigned tuples on this relation (Zanzibar @_this@).
    This
  | -- | The members of another relation on the same object.
    ComputedUserset RelationName
  | -- | Arrow: follow a tupleset relation, then a relation on the target.
    TupleToUserset RelationName RelationName
  | Union [Rewrite]
  | Intersection [Rewrite]
  | -- | @a but not b@.
    Exclusion Rewrite Rewrite
  | -- | A rewrite gated by a named caveat (bounded ABAC: time-bound, autonomy-level).
    Caveated CaveatName Rewrite
  deriving stock (Eq, Show)
