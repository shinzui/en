-- | Ergonomic constructors for authoring 'Schema' values.
--
-- This module is a thin layer over "En.Schema": it builds the same public data
-- types that validation, schema hashing, reachability compilation, check, lookup,
-- and expand already consume.
module En.Schema.Builder
  ( SchemaObject,
    SchemaRelation,
    PermissionRewrite,
    RewriteExpr (..),
    RelationHandle,
    relationRef,
    SubjectSpec,
    CaveatSpec,
    ParameterSpec,
    build,
    buildWithCaveats,
    object,
    relation,
    relationH,
    permission,
    subject,
    userset,
    wildcardSubject,
    caveat,
    caveatWith,
    parameter,
    ctxParam,
    payloadParam,
    litText,
    litBool,
    litInteger,
    litTimestamp,
    litEnum,
    cmpEq,
    cmpNe,
    cmpLt,
    cmpLe,
    cmpGt,
    cmpGe,
    predTrue,
    predAnd,
    predOr,
    predNot,
    predMember,
    this,
  )
where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import En.Error (EnError (SchemaViolation))
import En.Schema (CaveatCompare (..), CaveatOperand (..), CaveatParameterType, CaveatPredicate (..), CaveatSource (..), CaveatValue (..), Rewrite, Schema)
import En.Schema qualified as Raw

data SchemaObject = SchemaObject Raw.ObjectType (Map.Map Raw.RelationName Raw.Relation)

data SchemaRelation = SchemaRelation Raw.RelationName Raw.Relation

newtype PermissionRewrite = PermissionRewrite Rewrite

newtype RelationHandle = RelationHandle Raw.RelationName

newtype SubjectSpec = SubjectSpec Raw.AllowedSubject

data CaveatSpec = CaveatSpec Raw.CaveatName Raw.CaveatDefinition

data ParameterSpec = ParameterSpec Raw.CaveatParameterName CaveatParameterType

build :: [SchemaObject] -> Either EnError Schema
build =
  buildWithCaveats []

buildWithCaveats :: [CaveatSpec] -> [SchemaObject] -> Either EnError Schema
buildWithCaveats caveatSpecs objectSpecs = do
  objectTypes <- fromListUnique duplicateObjectType (objectEntry <$> objectSpecs)
  caveats <- fromListUnique duplicateCaveat (caveatEntry <$> caveatSpecs)
  pure (Raw.Schema objectTypes caveats)
  where
    objectEntry (SchemaObject name relations) =
      (name, relations)

    caveatEntry (CaveatSpec name definition) =
      (name, definition)

    duplicateObjectType (Raw.ObjectType name) =
      SchemaViolation ("duplicate object type declared: " <> name)

    duplicateCaveat (Raw.CaveatName name) =
      SchemaViolation ("duplicate caveat declared: " <> name)

object :: Text -> [SchemaRelation] -> Either EnError SchemaObject
object name relations = do
  relationMap <- fromListUnique duplicateRelation (relationEntry <$> relations)
  pure (SchemaObject objectType relationMap)
  where
    objectType =
      Raw.ObjectType name

    relationEntry (SchemaRelation relationName relationValue) =
      (relationName, relationValue)

    duplicateRelation (Raw.RelationName relationName) =
      SchemaViolation ("duplicate relation declared: " <> name <> "#" <> relationName)

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

relationH :: Text -> [SubjectSpec] -> Rewrite -> (SchemaRelation, RelationHandle)
relationH name subjects rewrite =
  (relation name subjects rewrite, RelationHandle (Raw.RelationName name))

relationRef :: Text -> RelationHandle
relationRef =
  RelationHandle . Raw.RelationName

instance IsString RelationHandle where
  fromString =
    relationRef . Text.pack

permission :: Text -> PermissionRewrite -> SchemaRelation
permission name =
  relation name [] . permissionRewrite

permissionRewrite :: PermissionRewrite -> Rewrite
permissionRewrite (PermissionRewrite rewrite) =
  rewrite

subject :: Text -> SubjectSpec
subject name =
  SubjectSpec (Raw.AllowedSubject (Raw.ObjectType name) Nothing False)

userset :: Text -> Text -> SubjectSpec
userset objectType relationName =
  SubjectSpec (Raw.AllowedSubject (Raw.ObjectType objectType) (Just (Raw.RelationName relationName)) False)

wildcardSubject :: Text -> SubjectSpec
wildcardSubject name =
  SubjectSpec (Raw.AllowedSubject (Raw.ObjectType name) Nothing True)

caveat :: Text -> [ParameterSpec] -> Either EnError CaveatSpec
caveat name parameterSpecs =
  caveatWith name parameterSpecs PredTrue

caveatWith :: Text -> [ParameterSpec] -> CaveatPredicate -> Either EnError CaveatSpec
caveatWith name parameterSpecs predicate = do
  parameterMap <- fromListUnique duplicateParameter (parameterEntry <$> parameterSpecs)
  pure (CaveatSpec caveatName (Raw.CaveatDefinition caveatName parameterMap predicate))
  where
    caveatName =
      Raw.CaveatName name

    parameterEntry (ParameterSpec parameterName parameterType) =
      (parameterName, parameterType)

    duplicateParameter (Raw.CaveatParameterName parameterName) =
      SchemaViolation ("duplicate caveat parameter declared: " <> name <> "." <> parameterName)

fromListUnique :: (Ord k) => (k -> EnError) -> [(k, v)] -> Either EnError (Map.Map k v)
fromListUnique onDuplicate =
  foldM insertUnique Map.empty
  where
    insertUnique acc (key, value)
      | Map.member key acc = Left (onDuplicate key)
      | otherwise = Right (Map.insert key value acc)

parameter :: Text -> CaveatParameterType -> ParameterSpec
parameter name =
  ParameterSpec (Raw.CaveatParameterName name)

ctxParam :: Text -> CaveatOperand
ctxParam =
  OperandParam FromContext . Raw.CaveatParameterName

payloadParam :: Text -> CaveatOperand
payloadParam =
  OperandParam FromPayload . Raw.CaveatParameterName

litText :: Text -> CaveatOperand
litText =
  OperandLiteral . ValueText

litBool :: Bool -> CaveatOperand
litBool =
  OperandLiteral . ValueBool

litInteger :: Integer -> CaveatOperand
litInteger =
  OperandLiteral . ValueInteger

litTimestamp :: UTCTime -> CaveatOperand
litTimestamp =
  OperandLiteral . ValueTimestamp

litEnum :: Text -> CaveatOperand
litEnum =
  OperandLiteral . ValueEnum

cmpEq :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpEq =
  PredCompare CmpEq

cmpNe :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpNe =
  PredCompare CmpNe

cmpLt :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpLt =
  PredCompare CmpLt

cmpLe :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpLe =
  PredCompare CmpLe

cmpGt :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpGt =
  PredCompare CmpGt

cmpGe :: CaveatOperand -> CaveatOperand -> CaveatPredicate
cmpGe =
  PredCompare CmpGe

predTrue :: CaveatPredicate
predTrue =
  PredTrue

predAnd :: [CaveatPredicate] -> CaveatPredicate
predAnd =
  PredAnd

predOr :: [CaveatPredicate] -> CaveatPredicate
predOr =
  PredOr

predNot :: CaveatPredicate -> CaveatPredicate
predNot =
  PredNot

predMember :: CaveatOperand -> [CaveatValue] -> CaveatPredicate
predMember =
  PredMember

this :: Rewrite
this =
  Raw.This

class RewriteExpr r where
  computed :: RelationHandle -> r
  arrow :: RelationHandle -> RelationHandle -> r
  anyOf :: r -> [r] -> r
  allOf :: r -> [r] -> r
  minus :: r -> r -> r
  caveated :: Text -> r -> r

instance RewriteExpr Rewrite where
  computed =
    Raw.ComputedUserset . relationHandleName

  arrow tupleset computedRelation =
    Raw.TupleToUserset (relationHandleName tupleset) (relationHandleName computedRelation)

  anyOf first rest =
    Raw.Union (first : rest)

  allOf first rest =
    Raw.Intersection (first : rest)

  minus =
    Raw.Exclusion

  caveated name =
    Raw.Caveated (Raw.CaveatName name)

instance RewriteExpr PermissionRewrite where
  computed =
    PermissionRewrite . computed

  arrow tupleset computedRelation =
    PermissionRewrite (arrow tupleset computedRelation)

  anyOf first rest =
    PermissionRewrite (Raw.Union (permissionRewrite <$> (first : rest)))

  allOf first rest =
    PermissionRewrite (Raw.Intersection (permissionRewrite <$> (first : rest)))

  minus left right =
    PermissionRewrite (Raw.Exclusion (permissionRewrite left) (permissionRewrite right))

  caveated name body =
    PermissionRewrite (Raw.Caveated (Raw.CaveatName name) (permissionRewrite body))

relationHandleName :: RelationHandle -> Raw.RelationName
relationHandleName (RelationHandle relationName) =
  relationName
