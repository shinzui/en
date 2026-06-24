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
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Text.Read (readMaybe)

import En.Error (EnError (SchemaViolation))
import En.Schema (CaveatOperand, CaveatParameterType (..), CaveatPredicate, CaveatValue (..), Schema)
import En.Schema.Builder qualified as Builder

-- | Parse en's text schema language into a raw 'Schema'.
parseSchema :: Text -> Either EnError Schema
parseSchema input =
    case parseEntries (sourceLines input) of
        Left err -> Left (SchemaViolation (Text.pack err))
        Right (caveats, objects) -> do
            caveatSpecs <- sequence caveats
            objectSpecs <- sequence objects
            Builder.buildWithCaveats caveatSpecs objectSpecs

sourceLines :: Text -> [Text]
sourceLines =
    filter (not . Text.null) . fmap normalizeLine . Text.lines
  where
    normalizeLine =
        Text.dropWhileEnd (== ';') . Text.strip

parseEntries :: [Text] -> Either String ([Either EnError Builder.CaveatSpec], [Either EnError Builder.SchemaObject])
parseEntries =
    go [] []
  where
    go caveats objects =
        \case
            [] -> Right (reverse caveats, reverse objects)
            line : rest ->
                case parseCaveatHeader line of
                    Just (name, parameters) -> do
                        (body, remaining) <- takeBlockBody ("caveat " <> name) rest
                        caveatSpec <- parseCaveat name parameters body
                        go (caveatSpec : caveats) objects remaining
                    Nothing ->
                        case parseObjectHeader line of
                            Nothing ->
                                Left ("expected caveat or object declaration, got: " <> Text.unpack line)
                            Just (name, InlineEmpty) -> do
                                go caveats (Builder.object name [] : objects) rest
                            Just (name, StartsBlock) -> do
                                (body, remaining) <- takeBlockBody ("object " <> name) rest
                                object <- parseObject name body
                                go caveats (object : objects) remaining

parseCaveatHeader :: Text -> Maybe (Text, Text)
parseCaveatHeader line = do
    rest <- Text.stripPrefix "caveat " line
    let (name, parameterTextWithOpen) = Text.breakOn "(" rest
    parameterText <- Text.stripPrefix "(" parameterTextWithOpen
    let (parameters, closeAndOpen) = Text.breakOn ")" parameterText
    afterClose <- Text.stripPrefix ")" closeAndOpen
    if Text.strip afterClose == "{"
        then Just (Text.strip name, parameters)
        else Nothing

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

takeBlockBody :: Text -> [Text] -> Either String ([Text], [Text])
takeBlockBody name lines' =
    case break (== "}") lines' of
        (_, []) -> Left (Text.unpack name <> " is missing closing }")
        (body, _close : rest) -> Right (body, rest)

parseCaveat :: Text -> Text -> [Text] -> Either String (Either EnError Builder.CaveatSpec)
parseCaveat name parameterText body = do
    parameterParts <- topLevelSplit "," parameterText
    parameters <- traverse parseCaveatParameter (filter (not . Text.null) parameterParts)
    predicate <- parseCaveatPredicate (Text.unwords body)
    pure (Builder.caveatWith name parameters predicate)

parseCaveatParameter :: Text -> Either String Builder.ParameterSpec
parseCaveatParameter parameterText =
    case Text.breakOn ":" parameterText of
        (name, typeText)
            | Text.null typeText ->
                Left ("caveat parameter is missing ':': " <> Text.unpack parameterText)
            | Text.null (Text.strip name) ->
                Left "caveat parameter has empty name"
            | otherwise ->
                Builder.parameter (Text.strip name) <$> parseCaveatParameterType (Text.drop 1 typeText)

parseCaveatParameterType :: Text -> Either String CaveatParameterType
parseCaveatParameterType typeText =
    case Text.strip typeText of
        "text" -> Right ParameterText
        "bool" -> Right ParameterBool
        "integer" -> Right ParameterInteger
        "timestamp" -> Right ParameterTimestamp
        enumText
            | Just rawValues <- parseBracketed "enum" enumText -> do
                values <- topLevelSplit "," rawValues
                case filter (not . Text.null) values of
                    [] -> Left "enum caveat parameter must declare at least one value"
                    nonEmpty -> Right (ParameterEnum nonEmpty)
        unknown ->
            Left ("unknown caveat parameter type: " <> Text.unpack unknown)

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
    | Just (body, caveatName) <- splitCaveated trimmed = Builder.caveated caveatName <$> parsePermissionRewriteTerm body
    | Just inner <- stripOuterParens trimmed = parsePermissionRewrite inner
    | Just (tupleset, computedRelation) <- splitArrow trimmed = Right (Builder.arrow (Builder.relationRef tupleset) (Builder.relationRef computedRelation))
    | otherwise = Right (Builder.computed (Builder.relationRef trimmed))
  where
    trimmed =
        Text.strip term

splitCaveated :: Text -> Maybe (Text, Text)
splitCaveated term =
    case either (const []) id (topLevelSplit " with " term) of
        [body, caveatName]
            | not (Text.null body) && not (Text.null caveatName) -> Just (body, caveatName)
        _ -> Nothing

parseCaveatPredicate :: Text -> Either String CaveatPredicate
parseCaveatPredicate =
    parsePredicateOr . Text.strip

parsePredicateOr :: Text -> Either String CaveatPredicate
parsePredicateOr predicateText = do
    parts <- topLevelSplit "|" predicateText
    case parts of
        [] -> Left "empty caveat predicate"
        [body] -> parsePredicateAnd body
        bodies -> Builder.predOr <$> traverse parsePredicateAnd bodies

parsePredicateAnd :: Text -> Either String CaveatPredicate
parsePredicateAnd predicateText = do
    parts <- topLevelSplit "&" predicateText
    case parts of
        [] -> Left "empty caveat predicate"
        [body] -> parsePredicateNot body
        bodies -> Builder.predAnd <$> traverse parsePredicateNot bodies

parsePredicateNot :: Text -> Either String CaveatPredicate
parsePredicateNot predicateText
    | Text.null trimmed = Left "empty caveat predicate"
    | Just rest <- Text.stripPrefix "!" trimmed = Builder.predNot <$> parsePredicateNot (Text.strip rest)
    | otherwise = parsePredicateAtom trimmed
  where
    trimmed =
        Text.strip predicateText

parsePredicateAtom :: Text -> Either String CaveatPredicate
parsePredicateAtom predicateText
    | Text.null trimmed = Left "empty caveat predicate"
    | trimmed == "true" = Right Builder.predTrue
    | Just inner <- stripOuterParens trimmed = parseCaveatPredicate inner
    | otherwise = parseMembershipOrComparison trimmed
  where
    trimmed =
        Text.strip predicateText

parseMembershipOrComparison :: Text -> Either String CaveatPredicate
parseMembershipOrComparison predicateText =
    case topLevelSplit " in " predicateText of
        Right [operandText, valuesText] -> do
            operand <- parseCaveatOperand operandText
            values <- parseCaveatValueList valuesText
            pure (Builder.predMember operand values)
        Right [_] -> parseComparison predicateText
        Right _ -> Left ("invalid membership predicate: " <> Text.unpack predicateText)
        Left err -> Left err

parseComparison :: Text -> Either String CaveatPredicate
parseComparison predicateText =
    firstComparison comparisonParsers
  where
    comparisonParsers =
        [ ("==", Builder.cmpEq)
        , ("!=", Builder.cmpNe)
        , ("<=", Builder.cmpLe)
        , (">=", Builder.cmpGe)
        , ("<", Builder.cmpLt)
        , (">", Builder.cmpGt)
        ]

    firstComparison =
        \case
            [] -> Left ("expected caveat predicate comparison, membership, true, !, or parentheses: " <> Text.unpack predicateText)
            (operatorText, constructor) : rest ->
                case topLevelSplit operatorText predicateText of
                    Right [leftText, rightText] -> constructor <$> parseCaveatOperand leftText <*> parseCaveatOperand rightText
                    Right [_] -> firstComparison rest
                    Right _ -> Left ("invalid caveat comparison: " <> Text.unpack predicateText)
                    Left err -> Left err

parseCaveatOperand :: Text -> Either String CaveatOperand
parseCaveatOperand operandText
    | Text.null trimmed = Left "empty caveat operand"
    | Just name <- Text.stripPrefix "context." trimmed =
        if Text.null name
            then Left "context caveat operand has empty parameter name"
            else Right (Builder.ctxParam name)
    | Just name <- Text.stripPrefix "payload." trimmed =
        if Text.null name
            then Left "payload caveat operand has empty parameter name"
            else Right (Builder.payloadParam name)
    | otherwise = literalOperand <$> parseCaveatLiteral trimmed
  where
    trimmed =
        Text.strip operandText

literalOperand :: CaveatValue -> CaveatOperand
literalOperand =
    \case
        ValueText value -> Builder.litText value
        ValueBool value -> Builder.litBool value
        ValueInteger value -> Builder.litInteger value
        ValueTimestamp value -> Builder.litTimestamp value
        ValueEnum value -> Builder.litEnum value

parseCaveatValueList :: Text -> Either String [CaveatValue]
parseCaveatValueList valuesText =
    case parseBracketed "" (Text.strip valuesText) of
        Nothing -> Left ("expected caveat value list in brackets, got: " <> Text.unpack valuesText)
        Just rawValues -> do
            values <- topLevelSplit "," rawValues
            traverse parseCaveatLiteral (filter (not . Text.null) values)

parseCaveatLiteral :: Text -> Either String CaveatValue
parseCaveatLiteral literalText
    | Just value <- parseQuoted literal = Right (ValueText value)
    | literal == "true" = Right (ValueBool True)
    | literal == "false" = Right (ValueBool False)
    | Just rawTimestamp <- parseCall "timestamp" literal = ValueTimestamp <$> parseTimestamp rawTimestamp
    | Just rawEnum <- parseCall "enum" literal = ValueEnum <$> parseQuotedOrError "enum literal" rawEnum
    | Just integer <- readMaybe (Text.unpack literal) = Right (ValueInteger integer)
    | otherwise = Left ("unknown caveat literal: " <> Text.unpack literal)
  where
    literal =
        Text.strip literalText

parseTimestamp :: Text -> Either String UTCTime
parseTimestamp rawTimestamp = do
    timestampText <- parseQuotedOrError "timestamp literal" rawTimestamp
    case iso8601ParseM (Text.unpack timestampText) of
        Just value -> Right value
        Nothing -> Left ("invalid ISO-8601 timestamp literal: " <> Text.unpack timestampText)

parseCall :: Text -> Text -> Maybe Text
parseCall name input = do
    rest <- Text.stripPrefix (name <> "(") input
    Text.stripSuffix ")" rest

parseBracketed :: Text -> Text -> Maybe Text
parseBracketed prefix input = do
    rest <- Text.stripPrefix (prefix <> "[") input
    Text.stripSuffix "]" rest

parseQuotedOrError :: String -> Text -> Either String Text
parseQuotedOrError label input =
    case parseQuoted (Text.strip input) of
        Just value -> Right value
        Nothing -> Left ("expected quoted " <> label <> ", got: " <> Text.unpack input)

parseQuoted :: Text -> Maybe Text
parseQuoted input
    | Text.length input >= 2 && Text.head input == '"' && Text.last input == '"' =
        Just (Text.init (Text.tail input))
    | otherwise = Nothing

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
        parts <- go 0 False [] [] input
        pure (Text.strip <$> parts)
  where
    go :: Int -> Bool -> [Text] -> [Text] -> Text -> Either String [Text]
    go depth inQuote current acc remaining
        | Text.null remaining =
            if depth == 0 && not inQuote
                then Right (reverse (Text.concat (reverse current) : acc))
                else Left "unclosed parenthesis in rewrite"
        | depth == 0 && not inQuote && delimiter `Text.isPrefixOf` remaining =
            go depth inQuote [] (Text.concat (reverse current) : acc) (Text.drop (Text.length delimiter) remaining)
        | otherwise =
            let char = Text.head remaining
                rest = Text.tail remaining
             in case char of
                    '"' -> go depth (not inQuote) (Text.singleton char : current) acc rest
                    '(' | not inQuote -> go (depth + 1) inQuote (Text.singleton char : current) acc rest
                    '[' | not inQuote -> go (depth + 1) inQuote (Text.singleton char : current) acc rest
                    ')'
                        | not inQuote ->
                            if depth <= 0
                                then Left "unexpected closing parenthesis in rewrite"
                                else go (depth - 1) inQuote (Text.singleton char : current) acc rest
                    ']'
                        | not inQuote ->
                            if depth <= 0
                                then Left "unexpected closing bracket in expression"
                                else go (depth - 1) inQuote (Text.singleton char : current) acc rest
                    ')' ->
                        go depth inQuote (Text.singleton char : current) acc rest
                    ']' ->
                        go depth inQuote (Text.singleton char : current) acc rest
                    _ -> go depth inQuote (Text.singleton char : current) acc rest

commaList :: Text -> [Text]
commaList =
    filter (not . Text.null) . fmap Text.strip . Text.splitOn ","
