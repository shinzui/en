{- | Runtime parser for en's text schema language.

The parser accepts the same compact object/relation/permission syntax used by
the schema quasi-quoter in "En.Schema.TH", but returns ordinary runtime values
and reports syntax plus schema assembly errors through 'EnError'.
-}
module En.Schema.Parse (
    parseSchema,
) where

import Data.Text (Text)
import Data.Text qualified as Text

import En.Error (EnError (SchemaViolation))
import En.Schema (Schema)
import En.Schema.Builder qualified as Builder

-- | Parse en's text schema language into a raw 'Schema'.
parseSchema :: Text -> Either EnError Schema
parseSchema input =
    case parseObjects (sourceLines input) of
        Left err -> Left (SchemaViolation (Text.pack err))
        Right objects -> sequence objects >>= Builder.build

sourceLines :: Text -> [Text]
sourceLines =
    filter (not . Text.null) . fmap normalizeLine . Text.lines
  where
    normalizeLine =
        Text.dropWhileEnd (== ';') . Text.strip

parseObjects :: [Text] -> Either String [Either EnError Builder.SchemaObject]
parseObjects =
    go []
  where
    go acc =
        \case
            [] -> Right (reverse acc)
            line : rest ->
                case parseObjectHeader line of
                    Nothing ->
                        Left ("expected object declaration, got: " <> Text.unpack line)
                    Just (name, InlineEmpty) -> do
                        go (Builder.object name [] : acc) rest
                    Just (name, StartsBlock) -> do
                        (body, remaining) <- takeObjectBody name rest
                        object <- parseObject name body
                        go (object : acc) remaining

data ObjectHeader
    = InlineEmpty
    | StartsBlock

parseObjectHeader :: Text -> Maybe (Text, ObjectHeader)
parseObjectHeader line = do
    rest <- Text.stripPrefix "object " line
    if Text.isSuffixOf "{}" rest
        then Just (Text.strip (Text.dropEnd 2 rest), InlineEmpty)
        else
            if Text.isSuffixOf "{" rest
                then Just (Text.strip (Text.dropEnd 1 rest), StartsBlock)
                else Nothing

takeObjectBody :: Text -> [Text] -> Either String ([Text], [Text])
takeObjectBody name lines' =
    case break (== "}") lines' of
        (_, []) -> Left ("object " <> Text.unpack name <> " is missing closing }")
        (body, _close : rest) -> Right (body, rest)

parseObject :: Text -> [Text] -> Either String (Either EnError Builder.SchemaObject)
parseObject name body = do
    relations <- traverse (parseObjectLine name) body
    pure (Builder.object name relations)

parseObjectLine :: Text -> Text -> Either String Builder.SchemaRelation
parseObjectLine objectName line
    | Just rest <- Text.stripPrefix "relation " line =
        parseRelation objectName rest
    | Just rest <- Text.stripPrefix "permission " line =
        parsePermission objectName rest
    | otherwise =
        Left ("inside object " <> Text.unpack objectName <> ", expected relation or permission, got: " <> Text.unpack line)

parseRelation :: Text -> Text -> Either String Builder.SchemaRelation
parseRelation objectName rest =
    case Text.breakOn ":" rest of
        (name, subjectsText)
            | Text.null subjectsText ->
                Left ("relation in object " <> Text.unpack objectName <> " is missing ':'")
            | otherwise -> do
                subjects <- traverse parseSubject (commaList (Text.drop 1 subjectsText))
                pure (Builder.relation (Text.strip name) subjects Builder.this)

parseSubject :: Text -> Either String Builder.SubjectSpec
parseSubject subjectText
    | Text.null subject = Left "empty subject"
    | Just objectType <- Text.stripSuffix ":*" subject = Right (Builder.wildcardSubject objectType)
    | otherwise =
        case Text.splitOn "#" subject of
            [objectType] -> Right (Builder.subject objectType)
            [objectType, relationName] -> Right (Builder.userset objectType relationName)
            _ -> Left ("invalid subject: " <> Text.unpack subject)
  where
    subject =
        Text.strip subjectText

parsePermission :: Text -> Text -> Either String Builder.SchemaRelation
parsePermission objectName rest =
    case Text.breakOn "=" rest of
        (name, rewriteText)
            | Text.null rewriteText ->
                Left ("permission in object " <> Text.unpack objectName <> " is missing '='")
            | otherwise -> do
                rewrite <- parsePermissionRewrite (Text.drop 1 rewriteText)
                pure (Builder.permission (Text.strip name) rewrite)

parsePermissionRewrite :: Text -> Either String Builder.PermissionRewrite
parsePermissionRewrite rewriteText =
    case pipeList rewriteText of
        [] -> Left "empty rewrite"
        first : rest -> do
            firstRewrite <- parsePermissionRewriteTerm first
            restRewrites <- traverse parsePermissionRewriteTerm rest
            pure $
                case restRewrites of
                    [] -> firstRewrite
                    _ -> Builder.anyOf firstRewrite restRewrites

parsePermissionRewriteTerm :: Text -> Either String Builder.PermissionRewrite
parsePermissionRewriteTerm term
    | Text.null trimmed = Left "empty rewrite term"
    | trimmed == "this" = Left "permission rewrite cannot contain this"
    | Just (tupleset, computedRelation) <- splitArrow trimmed = Right (Builder.arrow (Builder.relationRef tupleset) (Builder.relationRef computedRelation))
    | otherwise = Right (Builder.computed (Builder.relationRef trimmed))
  where
    trimmed =
        Text.strip term

splitArrow :: Text -> Maybe (Text, Text)
splitArrow term =
    case Text.splitOn "->" term of
        [tupleset, computed]
            | not (Text.null (Text.strip tupleset)) && not (Text.null (Text.strip computed)) ->
                Just (Text.strip tupleset, Text.strip computed)
        _ -> Nothing

commaList :: Text -> [Text]
commaList =
    filter (not . Text.null) . fmap Text.strip . Text.splitOn ","

pipeList :: Text -> [Text]
pipeList =
    filter (not . Text.null) . fmap Text.strip . Text.splitOn "|"
