-- | PostgreSQL @pg_snapshot@ revisions and consistency-token codec.
module En.Postgres.Revision (
    PgSnapshot (..),
    TokenPayload (..),
    TokenDecodeError (..),
    parsePgSnapshot,
    renderPgSnapshot,
    revisionFromPgSnapshot,
    revisionToPgSnapshot,
    transactionVisible,
    comparePgSnapshot,
    comparePostgresRevision,
    encodeToken,
    decodeToken,
) where

import Data.Char (digitToInt, isDigit, ord)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Word (Word64)
import Numeric (readDec, showHex)
import Text.Read (readMaybe)

import En.Revision (
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    RevisionOrder (..),
    SchemaHash (..),
 )

-- | A PostgreSQL MVCC snapshot, rendered as @xmin:xmax:xip1,xip2,...@.
data PgSnapshot = PgSnapshot
    { xmin :: !Word64
    , xmax :: !Word64
    , xip :: ![Word64]
    }
    deriving stock (Eq, Show)

data TokenPayload = TokenPayload
    { tokenDatastoreId :: !DatastoreId
    , tokenSchemaHash :: !SchemaHash
    , tokenRevision :: !Revision
    , tokenExpiresAt :: !(Maybe UTCTime)
    }
    deriving stock (Eq, Show)

data TokenDecodeError
    = TokenBadPrefix
    | TokenBadFieldCount
    | TokenBadEscape Text
    | TokenBadSnapshot Text
    deriving stock (Eq, Show)

parsePgSnapshot :: Text -> Either Text PgSnapshot
parsePgSnapshot input =
    case Text.splitOn ":" input of
        [xminText, xmaxText, xipText] -> do
            parsedXmin <- parseWord "xmin" xminText
            parsedXmax <- parseWord "xmax" xmaxText
            parsedXip <-
                if Text.null xipText
                    then Right []
                    else traverse (parseWord "xip") (Text.splitOn "," xipText)
            if parsedXmin > parsedXmax
                then Left "xmin must be <= xmax"
                else Right PgSnapshot{xmin = parsedXmin, xmax = parsedXmax, xip = sort (nub parsedXip)}
        _ -> Left "pg_snapshot must have xmin:xmax:xip shape"

renderPgSnapshot :: PgSnapshot -> Text
renderPgSnapshot PgSnapshot{xmin, xmax, xip} =
    Text.pack (show xmin)
        <> ":"
        <> Text.pack (show xmax)
        <> ":"
        <> Text.intercalate "," (Text.pack . show <$> sort (nub xip))

revisionFromPgSnapshot :: PgSnapshot -> Revision
revisionFromPgSnapshot =
    Revision . renderPgSnapshot

revisionToPgSnapshot :: Revision -> Either Text PgSnapshot
revisionToPgSnapshot =
    parsePgSnapshot . revisionEncoding

{- | Whether a transaction id is visible in a snapshot, mirroring PostgreSQL's
@pg_visible_in_snapshot@ rules for committed transaction ids.
-}
transactionVisible :: Word64 -> PgSnapshot -> Bool
transactionVisible txid PgSnapshot{xmin, xmax, xip}
    | txid < xmin = True
    | txid >= xmax = False
    | otherwise = txid `notElem` xip

comparePgSnapshot :: PgSnapshot -> PgSnapshot -> RevisionOrder
comparePgSnapshot left right =
    case (snapshotIncludes left right, snapshotIncludes right left) of
        (True, True) -> REqual
        (True, False) -> RAfter
        (False, True) -> RBefore
        (False, False) -> RConcurrent

comparePostgresRevision :: Revision -> Revision -> Either Text RevisionOrder
comparePostgresRevision left right =
    comparePgSnapshot <$> revisionToPgSnapshot left <*> revisionToPgSnapshot right

encodeToken :: TokenPayload -> ConsistencyToken
encodeToken TokenPayload{tokenDatastoreId, tokenSchemaHash, tokenRevision, tokenExpiresAt} =
    ConsistencyToken $
        Text.intercalate
            "."
            [ "en1"
            , escapeText datastore
            , escapeText schemaHash
            , escapeText revision
            , maybe "" (escapeText . Text.pack . show) tokenExpiresAt
            ]
  where
    DatastoreId datastore = tokenDatastoreId
    SchemaHash schemaHash = tokenSchemaHash
    revision = revisionEncoding tokenRevision

decodeToken :: ConsistencyToken -> Either TokenDecodeError TokenPayload
decodeToken (ConsistencyToken tokenText) =
    case Text.splitOn "." tokenText of
        ["en1", datastoreText, schemaText, revisionText, expiresText] -> do
            datastore <- unescapeText datastoreText
            schema <- unescapeText schemaText
            revision <- unescapeText revisionText
            expires <- traverse parseExpiry (nonEmptyText expiresText)
            case parsePgSnapshot revision of
                Left err -> Left (TokenBadSnapshot err)
                Right _ ->
                    Right
                        TokenPayload
                            { tokenDatastoreId = DatastoreId datastore
                            , tokenSchemaHash = SchemaHash schema
                            , tokenRevision = Revision revision
                            , tokenExpiresAt = expires
                            }
        prefix : _ | prefix /= "en1" -> Left TokenBadPrefix
        _ -> Left TokenBadFieldCount

snapshotIncludes :: PgSnapshot -> PgSnapshot -> Bool
snapshotIncludes candidate required =
    candidate.xmax >= required.xmax
        && all
            (\txid -> not (transactionVisible txid required) || transactionVisible txid candidate)
            probeTxids
  where
    probeTxids =
        sort . nub $
            [minBounded required.xmin, required.xmin, minBounded required.xmax]
                <> required.xip
                <> candidate.xip

minBounded :: Word64 -> Word64
minBounded 0 = 0
minBounded word = word - 1

parseExpiry :: Text -> Either TokenDecodeError UTCTime
parseExpiry text =
    case readMaybe (Text.unpack text) of
        Just value -> Right value
        Nothing -> Left (TokenBadEscape text)

parseWord :: Text -> Text -> Either Text Word64
parseWord fieldName textValue
    | Text.null textValue = Left (fieldName <> " is empty")
    | Text.any (not . isDigit) textValue = Left (fieldName <> " is not decimal")
    | otherwise =
        case readDec (Text.unpack textValue) of
            [(value, "")] -> Right value
            _ -> Left (fieldName <> " is not a Word64")

escapeText :: Text -> Text
escapeText =
    Text.concatMap
        ( \char ->
            if isTokenChar char
                then Text.singleton char
                else Text.pack ('%' : pad2 (showHex (ord char) ""))
        )

unescapeText :: Text -> Either TokenDecodeError Text
unescapeText text =
    Text.pack <$> go (Text.unpack text)
  where
    go [] = Right []
    go ('%' : a : b : rest)
        | isHex a && isHex b =
            let value = digitToInt a * 16 + digitToInt b
             in (toEnum value :) <$> go rest
    go ('%' : rest) = Left (TokenBadEscape (Text.pack ('%' : rest)))
    go (char : rest) = (char :) <$> go rest

isTokenChar :: Char -> Bool
isTokenChar char =
    char >= 'a' && char <= 'z'
        || char >= 'A' && char <= 'Z'
        || char >= '0' && char <= '9'
        || char == '-'
        || char == '_'

isHex :: Char -> Bool
isHex char =
    char >= '0' && char <= '9'
        || char >= 'a' && char <= 'f'
        || char >= 'A' && char <= 'F'

pad2 :: String -> String
pad2 [char] = ['0', char]
pad2 chars = chars

nonEmptyText :: Text -> Maybe Text
nonEmptyText text
    | Text.null text = Nothing
    | otherwise = Just text
