{- | The authorization model, supplied by the consuming project as a value.

This is the schema-parametric heart of en: @en@ ships no built-in model; a
consumer (e.g. kikan) constructs a 'Schema' describing its object types,
relations, permission rewrite rules, and caveats. The engine compiles a
'Schema' into a reachability graph ("En.Reachability") and evaluates
'En.Check.check' / 'En.Lookup.lookup' against it.

The vocabulary is deliberately the Zanzibar core (relations + userset rewrites)
plus bounded caveats. See @docs/spec/0001-en-overview.md@.
-}
module En.Schema (
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
    CaveatValue (..),
    CaveatPayload (..),
    CaveatContext (..),
    ValidSchema,
    unValidSchema,
    validate,
    validateSchema,
    schemaHash,
) where

import Control.Monad (void)
import Data.Bits (xor)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Numeric (showHex)

import En.Caveat.Value (CaveatContext (..), CaveatPayload (..), CaveatValue (..))
import En.Error (EnError (..))
import En.Revision (SchemaHash (..))
import En.Schema.Internal (ValidSchema (..), unValidSchema)
import En.Schema.Types (
    AllowedSubject (..),
    CaveatCompare (..),
    CaveatDefinition (..),
    CaveatName (..),
    CaveatOperand (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    CaveatPredicate (..),
    CaveatSource (..),
    ObjectType (..),
    Relation (..),
    RelationName (..),
    Rewrite (..),
    Schema (..),
 )

-- | Validate a schema and, on success, return it wrapped as evidence.
validateSchema :: Schema -> Either EnError ValidSchema
validateSchema schema = do
    traverse_ validateCaveatDefinition (Map.toAscList schema.caveats)
    traverse_ validateObjectType (Map.toAscList schema.objectTypes)
    validateProductiveCycles schema
    pure (ValidSchema schema)
  where
    validateCaveatDefinition (name, definition)
        | name /= definition.name =
            Left (SchemaViolation ("caveat map key does not match definition name: " <> caveatText name))
        | otherwise = do
            traverse_ validateParameterType (Map.toAscList definition.parameters)
            validatePredicate definition.parameters definition.predicate

    validateParameterType (parameterName, parameterType) =
        case parameterType of
            ParameterEnum [] ->
                Left (SchemaViolation ("enum caveat parameter has no values: " <> parameterText parameterName))
            ParameterEnum values
                | length values /= Set.size (Set.fromList values) ->
                    Left (SchemaViolation ("enum caveat parameter has duplicate values: " <> parameterText parameterName))
            _ -> Right ()

    validatePredicate parameters =
        \case
            PredTrue -> Right ()
            PredCompare _ left right -> validateOperand parameters left *> validateOperand parameters right
            PredAnd predicates -> traverse_ (validatePredicate parameters) predicates
            PredOr predicates -> traverse_ (validatePredicate parameters) predicates
            PredNot predicate -> validatePredicate parameters predicate
            PredMember operand _ -> validateOperand parameters operand

    validateOperand parameters =
        \case
            OperandParam _ parameterName ->
                if Map.member parameterName parameters
                    then Right ()
                    else Left (SchemaViolation ("caveat predicate references undeclared parameter: " <> parameterText parameterName))
            OperandLiteral _ -> Right ()

    validateObjectType :: (ObjectType, Map RelationName Relation) -> Either EnError ()
    validateObjectType (objectType, relations) =
        traverse_ (validateRelation objectType relations) (Map.toAscList relations)

    validateRelation :: ObjectType -> Map RelationName Relation -> (RelationName, Relation) -> Either EnError ()
    validateRelation objectType relations (relationName, relation)
        | relationName /= relation.relationName =
            Left (SchemaViolation ("relation map key does not match relation name: " <> relationText objectType relationName))
        | Set.null relation.allowedSubjects && rewriteContainsThis relation.rewrite =
            Left (SchemaViolation ("relation with This must declare at least one allowed subject: " <> relationText objectType relationName))
        | otherwise = do
            traverse_ validateAllowedSubject relation.allowedSubjects
            validateRewrite objectType relations relationName relation.rewrite

    validateAllowedSubject allowed =
        case Map.lookup allowed.objectType schema.objectTypes of
            Nothing ->
                Left (UnknownRelation ("unknown allowed subject object type: " <> objectText allowed.objectType))
            Just subjectRelations ->
                case (allowed.wildcard, allowed.relation) of
                    (True, Just _) ->
                        Left (SchemaViolation ("wildcard allowed subject cannot name a userset relation: " <> objectText allowed.objectType))
                    (_, Nothing) -> Right ()
                    (_, Just relationName) ->
                        if Map.member relationName subjectRelations
                            then Right ()
                            else Left (UnknownRelation ("unknown allowed subject relation: " <> relationText allowed.objectType relationName))

    validateRewrite :: ObjectType -> Map RelationName Relation -> RelationName -> Rewrite -> Either EnError ()
    validateRewrite objectType relations relationName =
        \case
            This -> Right ()
            ComputedUserset computedRelation ->
                () <$ requireRelation objectType relations computedRelation
            TupleToUserset tuplesetRelation computedRelation -> do
                tupleset <- requireRelation objectType relations tuplesetRelation
                let compatibleTargets =
                        [ allowed.objectType
                        | allowed <- Set.toList tupleset.allowedSubjects
                        , not allowed.wildcard
                        , hasRelation allowed.objectType computedRelation
                        ]
                if null compatibleTargets
                    then
                        Left
                            ( SchemaViolation
                                ( "tuple-to-userset "
                                    <> relationText objectType relationName
                                    <> " points through "
                                    <> relationNameText tuplesetRelation
                                    <> " but no allowed subject object type defines "
                                    <> relationNameText computedRelation
                                )
                            )
                    else Right ()
            Union rewrites -> validateNonEmpty "union" objectType relationName rewrites
            Intersection rewrites -> validateNonEmpty "intersection" objectType relationName rewrites
            Exclusion left right -> validateRewrite objectType relations relationName left *> validateRewrite objectType relations relationName right
            Caveated caveatName rewrite ->
                if Map.member caveatName schema.caveats
                    then validateRewrite objectType relations relationName rewrite
                    else Left (UnknownRelation ("unknown caveat: " <> caveatText caveatName))
      where
        validateNonEmpty label currentObjectType currentRelationName =
            \case
                [] -> Left (SchemaViolation (label <> " rewrite is empty: " <> relationText currentObjectType currentRelationName))
                rewrites -> traverse_ (validateRewrite currentObjectType relations currentRelationName) rewrites

    requireRelation :: ObjectType -> Map RelationName Relation -> RelationName -> Either EnError Relation
    requireRelation objectType relations relationName =
        case Map.lookup relationName relations of
            Just relation -> Right relation
            Nothing -> Left (UnknownRelation ("unknown relation: " <> relationText objectType relationName))

    hasRelation objectType relationName =
        maybe False (Map.member relationName) (Map.lookup objectType schema.objectTypes)

-- | Validate schema references and rewrite shapes before compilation.
validate :: Schema -> Either EnError ()
validate =
    void . validateSchema

validateProductiveCycles :: Schema -> Either EnError ()
validateProductiveCycles schema =
    traverse_ validateRef (Map.keys relationGraph)
  where
    relationGraph =
        Map.fromList
            [ (RelationRef objectType relationName, dependencies objectType relation.rewrite)
            | (objectType, relations) <- Map.toAscList schema.objectTypes
            , (relationName, relation) <- Map.toAscList relations
            ]

    validateRef ref =
        case cyclicComponent ref of
            [] -> Right ()
            refs
                | any hasProductiveBase refs -> Right ()
                | otherwise ->
                    Left (SchemaViolation ("rewrite cycle has no direct This base: " <> Text.intercalate ", " (renderRef <$> refs)))

    cyclicComponent ref =
        let reachableFromRef = reachable ref
            cyclicRefs = filter (\candidate -> ref `Set.member` reachable candidate) (Set.toList reachableFromRef)
         in if Set.member ref reachableFromRef then ref : filter (/= ref) cyclicRefs else []

    reachable start =
        go Set.empty (Set.toList (Map.findWithDefault Set.empty start relationGraph))
      where
        go seen =
            \case
                [] -> seen
                current : rest
                    | Set.member current seen -> go seen rest
                    | otherwise ->
                        go (Set.insert current seen) (Set.toList (Map.findWithDefault Set.empty current relationGraph) <> rest)

    hasDirectBase ref =
        maybe False rewriteContainsThis (lookupRewrite ref)

    hasProductiveBase ref =
        any hasDirectBase (ref : Set.toList (reachable ref))

    lookupRewrite (RelationRef objectType relationName) = do
        relations <- Map.lookup objectType schema.objectTypes
        relation <- Map.lookup relationName relations
        pure relation.rewrite

    dependencies objectType =
        \case
            This -> Set.empty
            ComputedUserset relationName -> Set.singleton RelationRef{objectType, relation = relationName}
            TupleToUserset tuplesetRelation computedRelation ->
                case lookupRelation objectType tuplesetRelation of
                    Nothing -> Set.empty
                    Just tupleset ->
                        Set.fromList
                            [ RelationRef{objectType = allowed.objectType, relation = computedRelation}
                            | allowed <- Set.toList tupleset.allowedSubjects
                            , not allowed.wildcard
                            , hasRelation allowed.objectType computedRelation
                            ]
            Union rewrites -> foldMap (dependencies objectType) rewrites
            Intersection rewrites -> foldMap (dependencies objectType) rewrites
            Exclusion left right -> dependencies objectType left <> dependencies objectType right
            Caveated _ rewrite -> dependencies objectType rewrite

    lookupRelation objectType relationName = do
        relations <- Map.lookup objectType schema.objectTypes
        Map.lookup relationName relations

    hasRelation objectType relationName =
        maybe False (Map.member relationName) (Map.lookup objectType schema.objectTypes)

data RelationRef = RelationRef
    { objectType :: !ObjectType
    , relation :: !RelationName
    }
    deriving stock (Eq, Ord, Show)

rewriteContainsThis :: Rewrite -> Bool
rewriteContainsThis =
    \case
        This -> True
        ComputedUserset _ -> False
        TupleToUserset _ _ -> False
        Union rewrites -> any rewriteContainsThis rewrites
        Intersection rewrites -> any rewriteContainsThis rewrites
        Exclusion left right -> rewriteContainsThis left || rewriteContainsThis right
        Caveated _ rewrite -> rewriteContainsThis rewrite

-- | A deterministic semantic schema fingerprint for consistency-token metadata.
schemaHash :: ValidSchema -> SchemaHash
schemaHash =
    SchemaHash . ("fnv1a64:" <>) . Text.pack . flip showHex "" . fnv1a64 . renderSchema . unValidSchema

renderSchema :: Schema -> Text
renderSchema schema =
    Text.intercalate
        "|"
        [ "schema"
        , "objects"
        , renderList renderObjectType (Map.toAscList schema.objectTypes)
        , "caveats"
        , renderList renderCaveatDefinition (Map.toAscList schema.caveats)
        ]
  where
    renderObjectType (objectType, relations) =
        Text.intercalate
            ":"
            [ "object"
            , renderText (objectText objectType)
            , renderList renderRelation (Map.toAscList relations)
            ]

    renderRelation (relationName, relation) =
        Text.intercalate
            ":"
            [ "relation"
            , renderText (relationNameText relationName)
            , renderList renderAllowedSubject (Set.toAscList relation.allowedSubjects)
            , renderRewrite relation.rewrite
            ]

    renderAllowedSubject allowed =
        Text.intercalate
            ":"
            [ "subject"
            , renderText (objectText allowed.objectType)
            , maybe "_" (renderText . relationNameText) allowed.relation
            , if allowed.wildcard then "wildcard" else "concrete"
            ]

    renderCaveatDefinition (caveatName, definition) =
        Text.intercalate
            ":"
            [ "caveat"
            , renderText (caveatText caveatName)
            , renderList renderParameter (Map.toAscList definition.parameters)
            , renderPredicate definition.predicate
            ]

    renderParameter (parameterName, parameterType) =
        Text.intercalate
            ":"
            [ "parameter"
            , renderText (parameterText parameterName)
            , renderParameterType parameterType
            ]

    renderParameterType =
        \case
            ParameterText -> "text"
            ParameterBool -> "bool"
            ParameterInteger -> "integer"
            ParameterTimestamp -> "timestamp"
            ParameterEnum values -> "enum:" <> renderList renderText (Set.toAscList (Set.fromList values))

    renderPredicate =
        \case
            PredTrue -> "true"
            PredCompare comparator left right ->
                Text.intercalate ":" ["compare", renderCompare comparator, renderOperand left, renderOperand right]
            PredAnd predicates -> "and:" <> renderList renderPredicate predicates
            PredOr predicates -> "or:" <> renderList renderPredicate predicates
            PredNot predicate -> "not:" <> renderPredicate predicate
            PredMember operand values -> "member:" <> renderOperand operand <> ":" <> renderList renderCaveatValue values

    renderCompare =
        \case
            CmpEq -> "eq"
            CmpNe -> "ne"
            CmpLt -> "lt"
            CmpLe -> "le"
            CmpGt -> "gt"
            CmpGe -> "ge"

    renderOperand =
        \case
            OperandParam source name -> "param:" <> renderSource source <> ":" <> renderText (parameterText name)
            OperandLiteral value -> "literal:" <> renderCaveatValue value

    renderSource =
        \case
            FromContext -> "context"
            FromPayload -> "payload"

    renderCaveatValue =
        \case
            ValueText value -> "text:" <> renderText value
            ValueBool value -> "bool:" <> Text.pack (show value)
            ValueInteger value -> "integer:" <> Text.pack (show value)
            ValueTimestamp value -> "timestamp:" <> Text.pack (show value)
            ValueEnum value -> "enum:" <> renderText value

    renderRewrite =
        \case
            This -> "this"
            ComputedUserset relationName -> "computed:" <> renderText (relationNameText relationName)
            TupleToUserset tuplesetRelation computedRelation ->
                Text.intercalate
                    ":"
                    [ "tuple_to_userset"
                    , renderText (relationNameText tuplesetRelation)
                    , renderText (relationNameText computedRelation)
                    ]
            Union rewrites -> "union:" <> renderList renderRewrite rewrites
            Intersection rewrites -> "intersection:" <> renderList renderRewrite rewrites
            Exclusion left right -> "exclusion:" <> renderRewrite left <> ":" <> renderRewrite right
            Caveated caveatName rewrite -> "caveated:" <> renderText (caveatText caveatName) <> ":" <> renderRewrite rewrite

renderList :: (a -> Text) -> [a] -> Text
renderList render values =
    Text.intercalate "," (render <$> values)

renderText :: Text -> Text
renderText value =
    Text.pack (show (Text.length value)) <> "#" <> value

fnv1a64 :: Text -> Word64
fnv1a64 =
    Text.foldl' step 14695981039346656037
  where
    step hash char =
        (hash `xor` fromIntegral (fromEnum char)) * 1099511628211

objectText :: ObjectType -> Text
objectText (ObjectType text) = text

relationNameText :: RelationName -> Text
relationNameText (RelationName text) = text

caveatText :: CaveatName -> Text
caveatText (CaveatName text) = text

parameterText :: CaveatParameterName -> Text
parameterText (CaveatParameterName text) = text

relationText :: ObjectType -> RelationName -> Text
relationText objectType relationName =
    objectText objectType <> "#" <> relationNameText relationName

renderRef :: RelationRef -> Text
renderRef ref =
    relationText ref.objectType ref.relation
