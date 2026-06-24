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
    parseExclusion (Text.strip rewriteText)

parseExclusion :: Text -> Either String Builder.PermissionRewrite
parseExclusion rewriteText = do
    parts <- topLevelSplit "but not" rewriteText
    case parts of
        [] -> Left "empty rewrite"
        [body] -> parseUnion body
        [left, right] -> Builder.minus <$> parseUnion left <*> parseUnion right
        _ -> Left "exclusion rewrite may contain only one 'but not'"

parseUnion :: Text -> Either String Builder.PermissionRewrite
parseUnion rewriteText = do
    parts <- topLevelSplit "|" rewriteText
    case parts of
        [] -> Left "empty rewrite"
        first : rest -> do
            firstRewrite <- parseIntersection first
            restRewrites <- traverse parseIntersection rest
            pure $
                case restRewrites of
                    [] -> firstRewrite
                    _ -> Builder.anyOf firstRewrite restRewrites

parseIntersection :: Text -> Either String Builder.PermissionRewrite
parseIntersection rewriteText = do
    parts <- topLevelSplit "&" rewriteText
    case parts of
        [] -> Left "empty rewrite"
        first : rest -> do
            firstRewrite <- parsePermissionRewriteTerm first
            restRewrites <- traverse parsePermissionRewriteTerm rest
            pure $
                case restRewrites of
                    [] -> firstRewrite
                    _ -> Builder.allOf firstRewrite restRewrites

parsePermissionRewriteTerm :: Text -> Either String Builder.PermissionRewrite
parsePermissionRewriteTerm term
    | Text.null trimmed = Left "empty rewrite term"
    | trimmed == "this" = Left "permission rewrite cannot contain this"
    | Just inner <- stripOuterParens trimmed = parsePermissionRewrite inner
    | Just (tupleset, computedRelation) <- splitArrow trimmed = Right (Builder.arrow (Builder.relationRef tupleset) (Builder.relationRef computedRelation))
    | otherwise = Right (Builder.computed (Builder.relationRef trimmed))
  where
    trimmed =
        Text.strip term

splitArrow :: Text -> Maybe (Text, Text)
splitArrow term =
    case either (const []) id (topLevelSplit "->" term) of
        [tupleset, computed]
            | not (Text.null (Text.strip tupleset)) && not (Text.null (Text.strip computed)) ->
                Just (Text.strip tupleset, Text.strip computed)
        _ -> Nothing

stripOuterParens :: Text -> Maybe Text
stripOuterParens input
    | Text.length input < 2 = Nothing
    | Text.head input /= '(' || Text.last input /= ')' = Nothing
    | otherwise =
        if outerParensWrap input
            then Just (Text.init (Text.tail input))
            else Nothing

outerParensWrap :: Text -> Bool
outerParensWrap input =
    go 0 0
  where
    lastIndex =
        Text.length input - 1

    go :: Int -> Int -> Bool
    go index depth
        | index > lastIndex = depth == 0
        | otherwise =
            case Text.index input index of
                '(' -> go (index + 1) (depth + 1)
                ')'
                    | depth == 1 && index < lastIndex -> False
                    | depth <= 0 -> False
                    | otherwise -> go (index + 1) (depth - 1)
                _ -> go (index + 1) depth

topLevelSplit :: Text -> Text -> Either String [Text]
topLevelSplit delimiter input
    | Text.null (Text.strip input) = Right []
    | Text.null delimiter = Left "empty delimiter"
    | otherwise = do
        parts <- go 0 [] [] input
        pure (Text.strip <$> parts)
  where
    go :: Int -> [Text] -> [Text] -> Text -> Either String [Text]
    go depth current acc remaining
        | Text.null remaining =
            if depth == 0
                then Right (reverse (Text.concat (reverse current) : acc))
                else Left "unclosed parenthesis in rewrite"
        | depth == 0 && delimiter `Text.isPrefixOf` remaining =
            go depth [] (Text.concat (reverse current) : acc) (Text.drop (Text.length delimiter) remaining)
        | otherwise =
            let char = Text.head remaining
                rest = Text.tail remaining
             in case char of
                    '(' -> go (depth + 1) (Text.singleton char : current) acc rest
                    ')' ->
                        if depth <= 0
                            then Left "unexpected closing parenthesis in rewrite"
                            else go (depth - 1) (Text.singleton char : current) acc rest
                    _ -> go depth (Text.singleton char : current) acc rest

commaList :: Text -> [Text]
commaList =
    filter (not . Text.null) . fmap Text.strip . Text.splitOn ","
