-- | The compiled schema: the reachability graph the engine traverses.
module En.Reachability
  ( ReachabilityGraph (..),
    RelationRef (..),
    SubjectSelector (..),
    EntryPoint (..),
    EntryKind (..),
    RewriteStep (..),
    compile,
    compileSchema,
    entryPoints,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import En.Error (EnError)
import En.Revision (SchemaHash)
import En.Schema
  ( AllowedSubject (..),
    CaveatDefinition,
    CaveatName,
    ObjectType,
    Relation (..),
    RelationName,
    Rewrite (..),
    Schema (..),
    ValidSchema,
    schemaHash,
    unValidSchema,
    validateSchema,
  )
import GHC.Generics (Generic)

-- | The compiled form of a 'Schema': everything @check@, @lookup@, and @expand@
-- traverse, and nothing else.
--
-- Reverse-edge metadata -- which subject shapes reach which relation, by what path
-- -- is /not/ here. No engine reads it; only 'En.Schema.Render' does. Building it
-- into the graph made every engine pay to construct and carry a structure none of
-- them consulted, so it is computed on demand by 'entryPoints'.
data ReachabilityGraph = ReachabilityGraph
  { relations :: !(Map RelationRef Relation),
    caveats :: !(Map CaveatName CaveatDefinition),
    hash :: !SchemaHash
  }
  deriving stock (Eq, Generic, Show)

data RelationRef = RelationRef
  { objectType :: !ObjectType,
    relation :: !RelationName
  }
  deriving stock (Eq, Ord, Show)

-- | A subject shape at the reverse edge source. A concrete subject source has
-- @relation = Nothing@. A userset source has @relation = Just r@ and means
-- @objectType#r@.
data SubjectSelector = SubjectSelector
  { objectType :: !ObjectType,
    relation :: !(Maybe RelationName),
    wildcard :: !Bool
  }
  deriving stock (Eq, Ord, Show)

data EntryKind
  = Direct
  | Conditional
  deriving stock (Eq, Ord, Show)

data RewriteStep
  = StepThis
  | StepComputedUserset !RelationName
  | StepTupleToUserset !RelationName !RelationName
  | StepUnion
  | StepIntersection
  | StepExclusion
  | StepCaveated
  deriving stock (Eq, Ord, Show)

data EntryPoint = EntryPoint
  { source :: !SubjectSelector,
    target :: !RelationRef,
    kind :: !EntryKind,
    path :: ![RewriteStep],
    caveats :: ![CaveatName],
    recursive :: !Bool
  }
  deriving stock (Eq, Show)

-- | Compile a validated schema into the reachability graph 'En.Check.check' and
-- 'En.Lookup.lookup' traverse. Total: the only thing that could fail is validation,
-- and the 'ValidSchema' argument is proof that already happened.
compile :: ValidSchema -> ReachabilityGraph
compile valid =
  ReachabilityGraph
    { relations =
        Map.fromList
          [ (RelationRef {objectType, relation = relationName}, relation)
          | (objectType, objectRelations) <- Map.toAscList schema.objectTypes,
            (relationName, relation) <- Map.toAscList objectRelations
          ],
      caveats = schema.caveats,
      hash = schemaHash valid
    }
  where
    schema =
      unValidSchema valid

-- | Validate a raw schema and compile it in one step.
compileSchema :: Schema -> Either EnError ReachabilityGraph
compileSchema schema =
  compile <$> validateSchema schema

-- | For each relation, the subject shapes that reach it and the rewrite path each
-- one takes.
--
-- Reverse-edge metadata for people, not for the engine: 'En.Schema.Render' draws it,
-- and it is the natural seed for the explain\/trace feature the architecture review
-- files as E12 -- an 'EntryPoint' already carries the @path@ a decision would have
-- followed. It lives outside 'ReachabilityGraph' because no evaluator consults it,
-- and building it into the graph charged every check, lookup, and expand for a
-- structure only a diagram reads.
--
-- Pure and cheap to recompute; a caller that draws many diagrams from one schema
-- should bind it once.
entryPoints :: ValidSchema -> Map RelationRef [EntryPoint]
entryPoints valid =
  Map.fromList
    [ (target, compileRelation schema target relation)
    | (objectType, relations) <- Map.toAscList schema.objectTypes,
      (relationName, relation) <- Map.toAscList relations,
      let target = RelationRef {objectType, relation = relationName}
    ]
  where
    schema =
      unValidSchema valid

compileRelation :: Schema -> RelationRef -> Relation -> [EntryPoint]
compileRelation schema target relation =
  compileRewrite schema target target Set.empty Direct [] [] relation.rewrite

compileRewrite ::
  Schema ->
  RelationRef ->
  RelationRef ->
  Set.Set RelationRef ->
  EntryKind ->
  [RewriteStep] ->
  [CaveatName] ->
  Rewrite ->
  [EntryPoint]
compileRewrite schema target current visited kind path caveats =
  \case
    This ->
      [ EntryPoint
          { source = SubjectSelector {objectType = allowed.objectType, relation = allowed.relation, wildcard = allowed.wildcard},
            target = target,
            kind = kind,
            path = reverse (StepThis : path),
            caveats = reverse caveats,
            recursive = False
          }
      | allowed <- maybe [] (Set.toAscList . (.allowedSubjects)) (lookupRelation schema current)
      ]
    ComputedUserset relationName ->
      let computed = RelationRef {objectType = current.objectType, relation = relationName}
       in if Set.member computed visited
            then []
            else
              maybe
                []
                ( \relation ->
                    compileRewrite
                      schema
                      target
                      computed
                      (Set.insert computed visited)
                      kind
                      (StepComputedUserset relationName : path)
                      caveats
                      relation.rewrite
                )
                (lookupRelation schema computed)
    TupleToUserset tuplesetRelation computedRelation ->
      [ EntryPoint
          { source = SubjectSelector {objectType = allowed.objectType, relation = Just computedRelation, wildcard = False},
            target = target,
            kind = kind,
            path = reverse (StepTupleToUserset tuplesetRelation computedRelation : path),
            caveats = reverse caveats,
            recursive = RelationRef {objectType = allowed.objectType, relation = computedRelation} == target
          }
      | allowed <- maybe [] (Set.toAscList . (.allowedSubjects)) (lookupRelation schema RelationRef {objectType = current.objectType, relation = tuplesetRelation}),
        not allowed.wildcard,
        hasRelation schema allowed.objectType computedRelation
      ]
    Union rewrites ->
      concatMap (compileRewrite schema target current visited kind (StepUnion : path) caveats) rewrites
    Intersection rewrites ->
      concatMap (compileRewrite schema target current visited Conditional (StepIntersection : path) caveats) rewrites
    Exclusion left right ->
      compileRewrite schema target current visited Conditional (StepExclusion : path) caveats left
        <> compileRewrite schema target current visited Conditional (StepExclusion : path) caveats right
    Caveated caveatName rewrite ->
      compileRewrite schema target current visited Conditional (StepCaveated : path) (caveatName : caveats) rewrite

lookupRelation :: Schema -> RelationRef -> Maybe Relation
lookupRelation schema ref = do
  relations <- Map.lookup ref.objectType schema.objectTypes
  Map.lookup ref.relation relations

hasRelation :: Schema -> ObjectType -> RelationName -> Bool
hasRelation schema objectType relationName =
  maybe False (Map.member relationName) (Map.lookup objectType schema.objectTypes)
