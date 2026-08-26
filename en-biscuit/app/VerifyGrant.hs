-- |
-- Module      : Main
-- Description : @en-verify-grant@ — verify and attenuate an en Biscuit grant locally.
--
-- A tiny downstream verifier so the @POST \/v1\/grants@ acceptance does not require
-- writing Haskell at demo time. It reads a serialized token on stdin, verifies it
-- against the issuer keyset in @EN_BISCUIT_ISSUER_PUBLIC_KEYS@ entirely in this
-- process — no call to @en-server@ — and prints the recovered grant, or a rejection
-- and a non-zero exit.
--
-- With @--attenuate-service@ it additionally demonstrates offline attenuation: it
-- re-parses the token as 'Auth.Biscuit.Open', appends a service-narrowing block, and
-- verifies the narrowed token twice — once for the narrowed service (which must
-- still verify) and once for the original service (which must now be rejected with
-- 'RestrictionFailed'). Service is the dimension a single-object grant can narrow:
-- the grant fixes its subject, operation, and one resource, so narrowing any of
-- those and then requesting a different value is refused by the grant itself, not by
-- the added block — whereas the service is a purely ambient fact the added block
-- alone constrains.
--
-- Usage:
--
-- @
-- en-verify-grant \\
--   --subject user:alice --operation view --resource space:project-x \\
--   --audience document-service --schema-hash \<hash\> \\
--   [--service \<name\>] [--attenuate-service \<name\>] \< token
-- @
module Main (main) where

import Auth.Biscuit
  ( Biscuit,
    BiscuitEncoding (..),
    Open,
    ParseError,
    ParserConfig (..),
    Verified,
    asOpen,
    parseWith,
    serializeB64,
  )
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.Char (isSpace)
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import En.Biscuit.Grant (Audience (..), RequestId (..))
import En.Biscuit.Keys (IssuerKeySet, parseIssuerKeySetText, selectIssuerKey)
import En.Biscuit.Verify
  ( EnBiscuitVerifyError (..),
    VerifiedScope (..),
    VerifyRequest (..),
    attenuateGrant,
    noAttenuation,
    verifyGrant,
  )
import En.Prelude hiding (op)
import En.Revision (SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..))
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The verify request assembled from the command line.
data Args = Args
  { subject :: !Subject,
    operation :: !RelationName,
    resource :: !ObjectRef,
    audience :: !Audience,
    -- | This verifying service's own identity; defaults to the audience.
    service :: !Audience,
    schemaHash :: !SchemaHash,
    attenuateService :: !(Maybe Audience)
  }
  deriving stock (Generic)

main :: IO ()
main = do
  rawArgs <- getArgs
  args <- either die pure (parseArgs rawArgs)
  keySet <- loadKeySet
  token <- readToken
  now <- getCurrentTime

  let request svc =
        VerifyRequest
          { expectedSubject = (args ^. #subject),
            expectedAudience = (args ^. #audience),
            operation = (args ^. #operation),
            resource = (args ^. #resource),
            serviceName = svc,
            acceptedSchemaHashes = Set.singleton (args ^. #schemaHash),
            now = now,
            revoked = const (pure False),
            revokedBlockIds = const (pure False)
          }

  -- 1. Verify the token as received.
  verifyGrant keySet token (request (args ^. #service)) >>= \case
    Left err -> die ("REJECTED: " <> show err)
    Right grant ->
      putStrLn
        ( "verified: subject="
            <> T.unpack (renderSubject (grant ^. #subject))
            <> " operation="
            <> T.unpack (renderOperation (grant ^. #operation))
            <> " resource="
            <> T.unpack (renderScope (grant ^. #scope))
            <> " expires="
            <> show (grant ^. #expiresAt)
            <> maybe "" (\(RequestId r) -> " requestId=" <> T.unpack r) (grant ^. #requestId)
        )

  -- 2. Offline attenuation demonstration, if asked.
  case (args ^. #attenuateService) of
    Nothing -> pure ()
    Just narrowedSvc -> demonstrateAttenuation keySet token request narrowedSvc

-- | Narrow the token to one service offline, then show the narrowed token verifies
-- for that service and is rejected for the original one — with no issuer contact.
demonstrateAttenuation ::
  IssuerKeySet ->
  ByteString ->
  (Audience -> VerifyRequest IO) ->
  Audience ->
  IO ()
demonstrateAttenuation keySet token request narrowedSvc = do
  open <- either (die . ("could not re-parse token as Open: " <>)) pure =<< parseOpen keySet token
  narrowed <- attenuateGrant (noAttenuation & #narrowedService ?~ narrowedSvc) open
  let narrowedToken = serializeB64 narrowed

  -- The narrowed service must still verify.
  verifyGrant keySet narrowedToken (request narrowedSvc) >>= \case
    Left err -> die ("attenuation: narrowed request should verify, got " <> show err)
    Right _ -> pure ()

  -- A different service must now be refused by the added check.
  let Audience narrowedName = narrowedSvc
  verifyGrant keySet narrowedToken (request (Audience "en-verify-grant-other-service")) >>= \case
    Left (RestrictionFailed _) ->
      putStrLn
        ( "attenuated: narrowed to service "
            <> T.unpack narrowedName
            <> "; that service verifies, a different service is REJECTED (RestrictionFailed)"
        )
    Left err -> die ("attenuation: broader request should be RestrictionFailed, got " <> show err)
    Right _ -> die "attenuation: broader request verified but should have been rejected"

-- | Re-parse the serialized token as an 'Open' biscuit so a block can be appended.
parseOpen :: IssuerKeySet -> ByteString -> IO (Either String (Biscuit Open Verified))
parseOpen keySet token = do
  parsed <- parseWith (parserConfig keySet) token
  pure $ case parsed of
    Left err -> Left (renderParseError err)
    Right biscuit -> maybe (Left "token is sealed and cannot be attenuated") Right (asOpen biscuit)

parserConfig :: IssuerKeySet -> ParserConfig IO
parserConfig keySet =
  ParserConfig
    { encoding = UrlBase64,
      isRevoked = const (pure False),
      getPublicKey = selectIssuerKey keySet
    }

renderParseError :: ParseError -> String
renderParseError = show

-- Rendering -----------------------------------------------------------------

renderSubject :: Subject -> Text
renderSubject = \case
  SubjectId ref -> renderRef ref
  SubjectSet ref (RelationName relation) -> renderRef ref <> "#" <> relation
  SubjectWildcard (ObjectType objectType) -> objectType <> ":*"

renderOperation :: RelationName -> Text
renderOperation (RelationName op) = op

renderScope :: VerifiedScope -> Text
renderScope = \case
  VerifiedObject ref -> renderRef ref
  VerifiedContainers refs -> T.intercalate "," (map renderRef refs)

renderRef :: ObjectRef -> Text
renderRef (ObjectRef (ObjectType objectType) objectId) = objectType <> ":" <> objectId

-- Input ---------------------------------------------------------------------

-- | Read the serialized token from stdin, dropping surrounding whitespace. The
-- URL-safe base64 alphabet has no whitespace, so filtering it out is safe and
-- tolerates a trailing newline from @echo@ or @jq -r@.
readToken :: IO ByteString
readToken = do
  raw <- Char8.getContents
  let token = Char8.filter (not . isSpace) raw
  if Char8.null token
    then die "no token on stdin"
    else pure token

loadKeySet :: IO IssuerKeySet
loadKeySet =
  lookupEnv "EN_BISCUIT_ISSUER_PUBLIC_KEYS" >>= \case
    Nothing -> die "EN_BISCUIT_ISSUER_PUBLIC_KEYS is not set (expected \"<id>:<hex>,…[,legacy:<hex>]\")"
    Just raw -> either (die . ("Invalid EN_BISCUIT_ISSUER_PUBLIC_KEYS: " <>) . T.unpack) pure (parseIssuerKeySetText (T.pack raw))

-- Argument parsing ----------------------------------------------------------

parseArgs :: [String] -> Either String Args
parseArgs raw = do
  flags <- toPairs raw
  subjectRef <- required flags "--subject" >>= parseRef
  operation <- RelationName <$> requiredText flags "--operation"
  resource <- required flags "--resource" >>= parseRef
  audienceText <- requiredText flags "--audience"
  schemaHashText <- requiredText flags "--schema-hash"
  let audience = Audience audienceText
      service = maybe audience (Audience . T.pack) (lookup "--service" flags)
      attenuateService = Audience . T.pack <$> lookup "--attenuate-service" flags
  pure
    Args
      { subject = SubjectId subjectRef,
        operation,
        resource,
        audience,
        service,
        schemaHash = SchemaHash schemaHashText,
        attenuateService
      }
  where
    required flags name = maybe (Left ("missing " <> name)) Right (lookup name flags)
    requiredText flags name = T.pack <$> required flags name

-- | Fold @--flag value@ pairs into an association list. A flag without a value, or
-- a bare token where a flag was expected, is an error rather than silently dropped.
toPairs :: [String] -> Either String [(String, String)]
toPairs = go
  where
    go [] = Right []
    go (flag : value : rest)
      | isFlag flag && not (isFlag value) = ((flag, value) :) <$> go rest
    go (flag : _)
      | isFlag flag = Left (flag <> " expects a value")
      | otherwise = Left ("unexpected argument " <> flag)
    isFlag ('-' : '-' : _) = True
    isFlag _ = False

parseRef :: String -> Either String ObjectRef
parseRef s =
  case break (== ':') s of
    (objectType, ':' : objectId)
      | not (null objectType) && not (null objectId) ->
          Right (ObjectRef (ObjectType (T.pack objectType)) (T.pack objectId))
    _ -> Left ("expected <type>:<id>, got " <> show s)

die :: String -> IO a
die message = do
  hPutStrLn stderr message
  exitFailure
