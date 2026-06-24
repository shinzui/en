-- | Raw schema data types shared by the safe public schema API and internal evidence wrappers.
module En.Schema.Types (
    Schema (..),
    ObjectType (..),
    RelationName (..),
    Relation (..),
    AllowedSubject (..),
    Rewrite (..),
    CaveatName (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    CaveatSource (..),
    CaveatOperand (..),
    CaveatCompare (..),
    CaveatPredicate (..),
    CaveatDefinition (..),
) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Language.Haskell.TH.Syntax (Lift)

import En.Caveat.Value (CaveatValue)

newtype ObjectType = ObjectType Text
    deriving stock (Eq, Ord, Show, Lift)

newtype RelationName = RelationName Text
    deriving stock (Eq, Ord, Show, Lift)

newtype CaveatName = CaveatName Text
    deriving stock (Eq, Ord, Show, Lift)

newtype CaveatParameterName = CaveatParameterName Text
    deriving stock (Eq, Ord, Show, Lift)

{- | The bounded value kinds a caveat can ask for. The evaluator remains small
and total; these are enough for time bounds, booleans, ids, and autonomy
levels without embedding a general policy language.
-}
data CaveatParameterType
    = ParameterText
    | ParameterBool
    | ParameterInteger
    | ParameterTimestamp
    | ParameterEnum [Text]
    deriving stock (Eq, Ord, Show, Lift)

data CaveatSource
    = FromContext
    | FromPayload
    deriving stock (Eq, Ord, Show, Lift)

data CaveatOperand
    = OperandParam !CaveatSource !CaveatParameterName
    | OperandLiteral !CaveatValue
    deriving stock (Eq, Ord, Show, Lift)

data CaveatCompare
    = CmpEq
    | CmpNe
    | CmpLt
    | CmpLe
    | CmpGt
    | CmpGe
    deriving stock (Eq, Ord, Show, Lift)

data CaveatPredicate
    = PredTrue
    | PredCompare !CaveatCompare !CaveatOperand !CaveatOperand
    | PredAnd ![CaveatPredicate]
    | PredOr ![CaveatPredicate]
    | PredNot !CaveatPredicate
    | PredMember !CaveatOperand ![CaveatValue]
    deriving stock (Eq, Ord, Show, Lift)

-- | Declares the request or tuple arguments a named caveat expects.
data CaveatDefinition = CaveatDefinition
    { name :: !CaveatName
    , parameters :: !(Map CaveatParameterName CaveatParameterType)
    , predicate :: !CaveatPredicate
    }
    deriving stock (Eq, Show, Lift)

-- | A complete authorization model: every object type and its relations.
data Schema = Schema
    { objectTypes :: !(Map ObjectType (Map RelationName Relation))
    , caveats :: !(Map CaveatName CaveatDefinition)
    }
    deriving stock (Eq, Show, Lift)

-- | A relation is a name plus the rewrite rule that computes its effective members.
data Relation = Relation
    { relationName :: !RelationName
    , allowedSubjects :: !(Set AllowedSubject)
    , rewrite :: !Rewrite
    }
    deriving stock (Eq, Show, Lift)

{- | A subject shape accepted by direct tuples on a relation.

@AllowedSubject t Nothing@ accepts concrete subjects of object type @t@, such
as @user:alice@. @AllowedSubject t (Just r)@ accepts userset subjects of shape
@t#r@, such as @org:acme#member@.
-}
data AllowedSubject = AllowedSubject
    { objectType :: !ObjectType
    , relation :: !(Maybe RelationName)
    , wildcard :: !Bool
    }
    deriving stock (Eq, Ord, Show, Lift)

{- | Userset-rewrite expressions — the Zanzibar relation algebra. @en@ leans on
'Union', 'ComputedUserset', and 'TupleToUserset'; 'Intersection' / 'Exclusion'
are supported but are the expensive, non-streaming cases for 'En.Lookup.lookup'.
-}
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
    deriving stock (Eq, Show, Lift)
