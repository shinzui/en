{- | Ergonomic constructors for authoring 'Schema' values.

This module is a thin layer over "En.Schema": it builds the same public data
types that validation, schema hashing, reachability compilation, check, lookup,
and expand already consume.
-}
module En.Schema.Builder (
    SchemaObject,
    SchemaRelation,
    SubjectSpec,
    CaveatSpec,
    ParameterSpec,
    build,
    buildWithCaveats,
    object,
    relation,
    permission,
    subject,
    userset,
    caveat,
    parameter,
    this,
    computed,
    arrow,
    anyOf,
    allOf,
    minus,
    caveated,
) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)

import En.Schema (CaveatParameterType, Rewrite, Schema)
import En.Schema qualified as Raw

data SchemaObject = SchemaObject Raw.ObjectType (Map.Map Raw.RelationName Raw.Relation)

data SchemaRelation = SchemaRelation Raw.RelationName Raw.Relation

newtype SubjectSpec = SubjectSpec Raw.AllowedSubject

data CaveatSpec = CaveatSpec Raw.CaveatName Raw.CaveatDefinition

data ParameterSpec = ParameterSpec Raw.CaveatParameterName CaveatParameterType

build :: [SchemaObject] -> Schema
build =
    buildWithCaveats []

buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Schema
buildWithCaveats caveatSpecs objectSpecs =
    Raw.Schema (Map.fromList (objectEntry <$> objectSpecs)) (Map.fromList (caveatEntry <$> caveatSpecs))
  where
    objectEntry (SchemaObject name relations) =
        (name, relations)

    caveatEntry (CaveatSpec name definition) =
        (name, definition)

object :: Text -> [SchemaRelation] -> SchemaObject
object name relations =
    SchemaObject
        (Raw.ObjectType name)
        (Map.fromList (relationEntry <$> relations))
  where
    relationEntry (SchemaRelation relationName relationValue) =
        (relationName, relationValue)

relation :: Text -> [SubjectSpec] -> Rewrite -> SchemaRelation
relation name subjects rewrite =
    SchemaRelation
        relationName
        (Raw.Relation relationName (Set.fromList (subjectValue <$> subjects)) rewrite)
  where
    relationName =
        Raw.RelationName name

    subjectValue (SubjectSpec allowedSubject) =
        allowedSubject

permission :: Text -> Rewrite -> SchemaRelation
permission name =
    relation name []

subject :: Text -> SubjectSpec
subject name =
    SubjectSpec (Raw.AllowedSubject (Raw.ObjectType name) Nothing)

userset :: Text -> Text -> SubjectSpec
userset objectType relationName =
    SubjectSpec (Raw.AllowedSubject (Raw.ObjectType objectType) (Just (Raw.RelationName relationName)))

caveat :: Text -> [ParameterSpec] -> CaveatSpec
caveat name parameterSpecs =
    CaveatSpec
        caveatName
        (Raw.CaveatDefinition caveatName (Map.fromList (parameterEntry <$> parameterSpecs)))
  where
    caveatName =
        Raw.CaveatName name

    parameterEntry (ParameterSpec parameterName parameterType) =
        (parameterName, parameterType)

parameter :: Text -> CaveatParameterType -> ParameterSpec
parameter name =
    ParameterSpec (Raw.CaveatParameterName name)

this :: Rewrite
this =
    Raw.This

computed :: Text -> Rewrite
computed =
    Raw.ComputedUserset . Raw.RelationName

arrow :: Text -> Text -> Rewrite
arrow tupleset computedRelation =
    Raw.TupleToUserset (Raw.RelationName tupleset) (Raw.RelationName computedRelation)

anyOf :: Rewrite -> [Rewrite] -> Rewrite
anyOf first rest =
    Raw.Union (first : rest)

allOf :: Rewrite -> [Rewrite] -> Rewrite
allOf first rest =
    Raw.Intersection (first : rest)

minus :: Rewrite -> Rewrite -> Rewrite
minus =
    Raw.Exclusion

caveated :: Text -> Rewrite -> Rewrite
caveated name =
    Raw.Caveated (Raw.CaveatName name)
