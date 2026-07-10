{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}

{- | Check stored tuples against a candidate schema.

'En.Schema.validateSchema' asks whether a schema is internally consistent. This module asks
the other question: whether the grants already in the store still mean anything under it.

A schema edit that drops a relation does not delete the tuples written on it — they stay in
the table, unevaluatable, invisible to every check. The same is true of a removed object
type, a narrowed subject list, a deleted caveat, and a caveat parameter whose type changed
under a payload that still carries the old one. Each is an /orphan/: a live row the
candidate schema cannot interpret.

Nothing here is a policy. 'checkTupleAgainstSchema' reports; the caller decides whether to
refuse the schema, force it through, or print a report and exit.

The scan is deliberately unanchored ('En.Effect.TupleStore.readAllTuples'): orphan detection
must find tuples whose object type is /absent/ from the candidate schema, and no filter over
a type that does not exist can name them.
-}
module En.SchemaCheck (
    TupleOrphan (..),
    OrphanReason (..),
    OrphanReport (..),
    checkTupleAgainstSchema,
    validateTuplesAgainstSchema,
    renderTupleOrphan,
    renderTuple,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, (:>))

import En.Effect.TupleStore (PageState (..), StoreCursor, TuplePage (..), TupleRow (..), TupleStore, readAllTuples)
import En.Revision (Revision)
import En.Schema (
    AllowedSubject (..),
    CaveatDefinition (..),
    CaveatName (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectType (..),
    Relation (..),
    RelationName (..),
    Schema (..),
    ValidSchema,
    unValidSchema,
 )
import En.Tuple (ObjectRef (..), Subject (..), Tuple (..), TupleCaveat (..))

-- | A live tuple the candidate schema cannot interpret, and why.
data TupleOrphan = TupleOrphan
    { tuple :: !Tuple
    , reason :: !OrphanReason
    }
    deriving stock (Eq, Show)

{- | Why a tuple is orphaned. Exactly one reason is reported per tuple — the first the
checks below encounter — because a tuple whose object type is gone has no relation to
disagree about either, and reporting both would be noise.
-}
data OrphanReason
    = -- | The tuple's object type is not in the candidate schema.
      OrphanUnknownObjectType !ObjectType
    | -- | The object type exists; this relation on it does not.
      OrphanUnknownRelation !ObjectType !RelationName
    | -- | The subject's own object type is not in the candidate schema.
      OrphanUnknownSubjectType !ObjectType
    | {- | The subject's type (and userset relation) exist, but the relation does not accept
      a subject of this shape. Narrowing @allowedSubjects@ — including dropping a wildcard
      allowance — lands here.
      -}
      OrphanDisallowedSubject !Subject
    | -- | The tuple carries a caveat the candidate schema does not define.
      OrphanUnknownCaveat !CaveatName
    | {- | The caveat exists, but the tuple's stored payload does not fit its parameters.
      One message per offending key, ordered by key.
      -}
      OrphanCaveatPayloadMismatch !CaveatName ![Text]
    deriving stock (Eq, Show)

{- | Is this tuple interpretable under this schema?

The checks run in the order a reader would ask them, and stop at the first failure:

1. the object type exists;
2. the relation exists on it;
3. the subject's object type exists, and for a userset, the relation it names exists on that
   type;
4. the relation accepts a subject of this shape;
5. the caveat, if any, is defined;
6. every key of the caveat's stored payload is a declared parameter of the declared type.

A tuple written on a /permission/ rather than a relation reports 'OrphanDisallowedSubject':
a permission is a 'Relation' with an empty @allowedSubjects@, so nothing can be directly
assigned to it, and that is the honest reading of the schema rather than a special case.
-}
checkTupleAgainstSchema :: ValidSchema -> Tuple -> Maybe TupleOrphan
checkTupleAgainstSchema validSchema tuple =
    TupleOrphan tuple <$> reasonFor
  where
    schema = unValidSchema validSchema

    reasonFor :: Maybe OrphanReason
    reasonFor =
        case Map.lookup tuple.object.objectType schema.objectTypes of
            Nothing -> Just (OrphanUnknownObjectType tuple.object.objectType)
            Just relations ->
                case Map.lookup tuple.relation relations of
                    Nothing -> Just (OrphanUnknownRelation tuple.object.objectType tuple.relation)
                    Just relation ->
                        subjectReason relation `orElse` caveatReason

    subjectReason :: Relation -> Maybe OrphanReason
    subjectReason relation =
        case tuple.subject of
            SubjectId object ->
                knownType object.objectType
                    `orElse` requireAllowed relation AllowedSubject{objectType = object.objectType, relation = Nothing, wildcard = False}
            SubjectWildcard objectType ->
                knownType objectType
                    `orElse` requireAllowed relation AllowedSubject{objectType, relation = Nothing, wildcard = True}
            SubjectSet object subjectRelation ->
                knownUserset object.objectType subjectRelation
                    `orElse` requireAllowed relation AllowedSubject{objectType = object.objectType, relation = Just subjectRelation, wildcard = False}

    -- The subject's type must be modelled at all. A schema that dropped `user` strands every
    -- grant naming a user, whatever relation it was written on.
    knownType :: ObjectType -> Maybe OrphanReason
    knownType objectType
        | Map.member objectType schema.objectTypes = Nothing
        | otherwise = Just (OrphanUnknownSubjectType objectType)

    -- A userset subject `group:eng#member` needs both `group` and `group#member`.
    knownUserset :: ObjectType -> RelationName -> Maybe OrphanReason
    knownUserset objectType subjectRelation =
        case Map.lookup objectType schema.objectTypes of
            Nothing -> Just (OrphanUnknownSubjectType objectType)
            Just relations
                | Map.member subjectRelation relations -> Nothing
                | otherwise -> Just (OrphanUnknownRelation objectType subjectRelation)

    requireAllowed :: Relation -> AllowedSubject -> Maybe OrphanReason
    requireAllowed relation allowed
        | Set.member allowed relation.allowedSubjects = Nothing
        | otherwise = Just (OrphanDisallowedSubject tuple.subject)

    caveatReason :: Maybe OrphanReason
    caveatReason =
        case tuple.caveat of
            Nothing -> Nothing
            Just TupleCaveat{name, payload} ->
                case Map.lookup name schema.caveats of
                    Nothing -> Just (OrphanUnknownCaveat name)
                    Just definition ->
                        case payloadErrors definition.parameters payload of
                            [] -> Nothing
                            errors -> Just (OrphanCaveatPayloadMismatch name errors)

{- | Every way a stored payload can fail its declared parameters.

A parameter declared but /absent/ from the payload is not an error: adding a parameter is a
compatible change precisely because existing payloads simply do not carry it. A payload key
that is not a declared parameter is an error, which is what makes removing a parameter
incompatible.
-}
payloadErrors :: Map CaveatParameterName CaveatParameterType -> CaveatPayload -> [Text]
payloadErrors parameters (CaveatPayload values) =
    mapMaybe keyError (Map.toAscList values)
  where
    keyError (key, value) =
        case Map.lookup (CaveatParameterName key) parameters of
            Nothing -> Just (key <> ": not a parameter of this caveat")
            Just parameterType
                | valueMatches parameterType value -> Nothing
                | otherwise ->
                    Just
                        ( key
                            <> ": expected "
                            <> renderParameterType parameterType
                            <> ", stored "
                            <> renderValueType value
                        )

valueMatches :: CaveatParameterType -> CaveatValue -> Bool
valueMatches parameterType value =
    case (parameterType, value) of
        (ParameterText, ValueText _) -> True
        (ParameterBool, ValueBool _) -> True
        (ParameterInteger, ValueInteger _) -> True
        (ParameterTimestamp, ValueTimestamp _) -> True
        -- An enum narrowed to fewer members strands payloads carrying a dropped member, so
        -- membership is part of the type check rather than a separate reason.
        (ParameterEnum allowed, ValueEnum stored) -> stored `elem` allowed
        _ -> False

renderParameterType :: CaveatParameterType -> Text
renderParameterType = \case
    ParameterText -> "text"
    ParameterBool -> "bool"
    ParameterInteger -> "integer"
    ParameterTimestamp -> "timestamp"
    ParameterEnum allowed -> "enum(" <> Text.intercalate "|" allowed <> ")"

renderValueType :: CaveatValue -> Text
renderValueType = \case
    ValueText _ -> "text"
    ValueBool _ -> "bool"
    ValueInteger _ -> "integer"
    ValueTimestamp _ -> "timestamp"
    ValueEnum stored -> "enum value " <> stored

{- | What a scan found: the orphans, and how many live tuples were examined to find them.

@scanned@ is carried because "0 orphans" means two very different things over an empty store
and over a million grants, and an operator reading a report before a destructive schema
change needs to know which one they are looking at. It costs nothing — the scan visits every
row regardless.
-}
data OrphanReport = OrphanReport
    { scanned :: !Int
    , orphans :: ![TupleOrphan]
    }
    deriving stock (Eq, Show)

{- | Every live tuple at @revision@ that the candidate schema cannot interpret.

Anchored to one caller-held 'Revision', so writers may proceed throughout and the report
describes the graph as it stood when the scan began rather than a smear across it. This is a
sequential scan of the whole table by construction (see the module header); it is an
administrative operation, and saying so is more honest than an index that cannot exist.
-}
validateTuplesAgainstSchema ::
    (TupleStore :> es) =>
    ValidSchema ->
    Revision ->
    Eff es OrphanReport
validateTuplesAgainstSchema validSchema revision =
    drainFrom Nothing OrphanReport{scanned = 0, orphans = []}
  where
    drainFrom :: (TupleStore :> es) => Maybe StoreCursor -> OrphanReport -> Eff es OrphanReport
    drainFrom cursor report = do
        TuplePage{rows, state} <- readAllTuples revision scanPageSize cursor
        let found =
                OrphanReport
                    { scanned = report.scanned + length rows
                    , orphans = report.orphans <> mapMaybe (checkTupleAgainstSchema validSchema . (.tuple)) rows
                    }
        case state of
            Exhausted -> pure found
            -- `Truncated` means the store stopped short of the limit, not that the scan is
            -- over. A validation pass that treated it as the end would pass a schema that
            -- strands everything past the first short page.
            HasMore next -> drainFrom (Just next) found
            Truncated next -> drainFrom (Just next) found

    scanPageSize = 1000

{- | An orphan as one line of an operator's report, e.g.

@ORPHAN post:1#author\@user:alice — relation post#author not in candidate schema@
-}
renderTupleOrphan :: TupleOrphan -> Text
renderTupleOrphan TupleOrphan{tuple, reason} =
    "ORPHAN " <> renderTuple tuple <> " — " <> renderReason reason

renderReason :: OrphanReason -> Text
renderReason = \case
    OrphanUnknownObjectType (ObjectType objectType) ->
        "object type " <> objectType <> " not in candidate schema"
    OrphanUnknownRelation (ObjectType objectType) (RelationName relation) ->
        "relation " <> objectType <> "#" <> relation <> " not in candidate schema"
    OrphanUnknownSubjectType (ObjectType objectType) ->
        "subject object type " <> objectType <> " not in candidate schema"
    OrphanDisallowedSubject subject ->
        "subject " <> renderSubject subject <> " is not an allowed subject of this relation"
    OrphanUnknownCaveat (CaveatName caveat) ->
        "caveat " <> caveat <> " not in candidate schema"
    OrphanCaveatPayloadMismatch (CaveatName caveat) errors ->
        "caveat " <> caveat <> " payload does not fit its parameters: " <> Text.intercalate "; " errors

-- | @space:project-x#viewer\@user:alice@, with @[caveat_name]@ appended when caveated.
renderTuple :: Tuple -> Text
renderTuple Tuple{object, relation = RelationName relation, subject, caveat} =
    renderObject object
        <> "#"
        <> relation
        <> "@"
        <> renderSubject subject
        <> maybe "" (\TupleCaveat{name = CaveatName name} -> "[" <> name <> "]") caveat

renderObject :: ObjectRef -> Text
renderObject ObjectRef{objectType = ObjectType objectType, objectId} =
    objectType <> ":" <> objectId

renderSubject :: Subject -> Text
renderSubject = \case
    SubjectId object -> renderObject object
    SubjectSet object (RelationName relation) -> renderObject object <> "#" <> relation
    SubjectWildcard (ObjectType objectType) -> objectType <> ":*"

{- | The first reason, or the next question. @Maybe@'s own 'Data.Maybe.Alternative' would do,
but naming it says what the chain means: stop at the first thing wrong.
-}
orElse :: Maybe a -> Maybe a -> Maybe a
orElse first second =
    maybe second Just first
