{-# LANGUAGE QuasiQuotes #-}

{- | Tests for en-biscuit. Two groups:

  1. A dependency smoke test proving @biscuit-haskell@ is wired correctly
     (mint, serialize, re-parse, authorize a Biscuit).
  2. Grant-vocabulary tests proving 'En.Biscuit.Grant' renders the stable
     predicate vocabulary for object and container-scoped grants, encodes the
     subject/schema-hash/consistency-token/audience/expiry metadata, fails
     closed on non-concrete subjects, and cannot be broken out of via
     punctuation in field values.
-}
module Main (main) where

import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Exit (exitFailure)

import Auth.Biscuit (
    addBlock,
    authorizeBiscuit,
    authorizer,
    block,
    mkBiscuit,
    newSecret,
    parseB64,
    serializeB64,
    toPublic,
 )

import En.Biscuit.Grant (
    Audience (..),
    EnBiscuitError (..),
    EnBiscuitGrant (..),
    EnGrant (..),
    EnScopedGrant (..),
    RequestId (..),
    RevocationId (..),
    grantBlock,
    grantFactsText,
 )
import En.Revision (ConsistencyToken (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..))

main :: IO ()
main = do
    biscuitSmokeTest
    objectGrantTest
    scopedGrantTest
    unsupportedSubjectTest
    injectionSafetyTest
    putStrLn "en-biscuit tests PASS"

-- | Wiring check for the biscuit-haskell dependency.
biscuitSmokeTest :: IO ()
biscuitSmokeTest = do
    secret <- newSecret
    let public = toPublic secret

    let authority = [block|right("file1", "read");|]
    biscuit <- mkBiscuit secret authority
    attenuated <- addBlock [block|check if right("file1", $op), $op.length() > 0;|] biscuit

    let serialized = serializeB64 attenuated
    parsed <- either (fail . show) pure (parseB64 public serialized)

    let policy = [authorizer|allow if right("file1", "read");|]
    result <- authorizeBiscuit parsed policy
    case result of
        Left err -> die ("smoke test: authorization rejected: " <> show err)
        Right _ -> pure ()

    when (BS.null serialized) (die "smoke test: empty serialization")

-- | An object grant renders every expected object-grant predicate.
objectGrantTest :: IO ()
objectGrantTest = do
    let grant =
            ObjectGrant
                EnGrant
                    { subject = SubjectId (ObjectRef (ObjectType "user") "alice")
                    , permission = RelationName "view"
                    , object = ObjectRef (ObjectType "document") "roadmap"
                    , consistencyToken = ConsistencyToken "zk-123"
                    , schemaHash = SchemaHash "sha-abc"
                    , expiresAt = sampleExpiry
                    , audience = Audience "billing-service"
                    , requestId = Just (RequestId "req-9")
                    , revocationId = Just (RevocationId "rev-7")
                    }
    facts <- expectFacts grant
    assertInfix "object grant: en_subject" "en_subject(\"user\", \"alice\")" facts
    assertInfix "object grant: en_right" "en_right(\"document\", \"roadmap\", \"view\")" facts
    assertInfix "object grant: en_schema_hash" "en_schema_hash(\"sha-abc\")" facts
    assertInfix "object grant: en_consistency_token" "en_consistency_token(\"zk-123\")" facts
    assertInfix "object grant: en_audience" "en_audience(\"billing-service\")" facts
    assertInfix "object grant: en_expires_at" "en_expires_at(" facts
    assertInfix "object grant: en_request_id" "en_request_id(\"req-9\")" facts
    assertInfix "object grant: en_revocation_id" "en_revocation_id(\"rev-7\")" facts

{- | A scoped grant renders @en_scoped_right@ plus one @en_container_scope@ per
container, and omits the optional request/revocation facts when absent.
-}
scopedGrantTest :: IO ()
scopedGrantTest = do
    let grant =
            ScopedGrant
                EnScopedGrant
                    { subject = SubjectId (ObjectRef (ObjectType "user") "bob")
                    , permission = RelationName "edit"
                    , objectType = ObjectType "document"
                    , containers =
                        [ ObjectRef (ObjectType "folder") "f1"
                        , ObjectRef (ObjectType "folder") "f2"
                        ]
                    , consistencyToken = ConsistencyToken "zk-456"
                    , schemaHash = SchemaHash "sha-def"
                    , expiresAt = sampleExpiry
                    , audience = Audience "docs-service"
                    , requestId = Nothing
                    , revocationId = Nothing
                    }
    facts <- expectFacts grant
    assertInfix "scoped grant: en_scoped_right" "en_scoped_right(\"document\", \"edit\")" facts
    assertInfix "scoped grant: container f1" "en_container_scope(\"folder\", \"f1\")" facts
    assertInfix "scoped grant: container f2" "en_container_scope(\"folder\", \"f2\")" facts
    assertEqual
        "scoped grant: exactly one container fact per container"
        2
        (T.count "en_container_scope(" facts)
    assertBool
        "scoped grant: no request id when absent"
        (not ("en_request_id(" `T.isInfixOf` facts))
    assertBool
        "scoped grant: no revocation id when absent"
        (not ("en_revocation_id(" `T.isInfixOf` facts))

-- | Non-concrete subjects fail closed rather than widening authorization.
unsupportedSubjectTest :: IO ()
unsupportedSubjectTest = do
    let wildcard =
            ObjectGrant
                EnGrant
                    { subject = SubjectWildcard (ObjectType "user")
                    , permission = RelationName "view"
                    , object = ObjectRef (ObjectType "document") "roadmap"
                    , consistencyToken = ConsistencyToken "zk-1"
                    , schemaHash = SchemaHash "sha-1"
                    , expiresAt = sampleExpiry
                    , audience = Audience "svc"
                    , requestId = Nothing
                    , revocationId = Nothing
                    }
        userset =
            ObjectGrant
                EnGrant
                    { subject = SubjectSet (ObjectRef (ObjectType "group") "eng") (RelationName "member")
                    , permission = RelationName "view"
                    , object = ObjectRef (ObjectType "document") "roadmap"
                    , consistencyToken = ConsistencyToken "zk-1"
                    , schemaHash = SchemaHash "sha-1"
                    , expiresAt = sampleExpiry
                    , audience = Audience "svc"
                    , requestId = Nothing
                    , revocationId = Nothing
                    }
    case grantBlock wildcard of
        Left (UnsupportedSubject (SubjectWildcard _)) -> pure ()
        other -> die ("unsupported subject: wildcard should fail closed, got " <> showResult other)
    case grantBlock userset of
        Left (UnsupportedSubject (SubjectSet _ _)) -> pure ()
        other -> die ("unsupported subject: userset should fail closed, got " <> showResult other)

{- | Punctuation in a field value stays inside a single string term; it cannot
inject an extra queryable fact. Proven semantically: an object id crafted to
look like an extra @en_right@ fact is minted into a real Biscuit, and an
authorizer that queries that forged fact must fail to match.
-}
injectionSafetyTest :: IO ()
injectionSafetyTest = do
    -- This id, if naively concatenated, would close the real fact and open a
    -- forged @en_right("document", "secret", "view")@.
    let nastyId = "roadmap\"); en_right(\"document\", \"secret\", \"view"
        grant =
            ObjectGrant
                EnGrant
                    { subject = SubjectId (ObjectRef (ObjectType "user") "alice")
                    , permission = RelationName "view"
                    , object = ObjectRef (ObjectType "document") nastyId
                    , consistencyToken = ConsistencyToken "zk-123"
                    , schemaHash = SchemaHash "sha-abc"
                    , expiresAt = sampleExpiry
                    , audience = Audience "svc"
                    , requestId = Nothing
                    , revocationId = Nothing
                    }
    grantBlk <- either (die . show) pure (grantBlock grant)

    secret <- newSecret
    let public = toPublic secret
    biscuit <- mkBiscuit secret grantBlk
    parsed <- either (die . show) pure (parseB64 public (serializeB64 biscuit))

    -- Positive control: the genuine subject fact is present, so the token is
    -- valid and its facts are queryable.
    control <- authorizeBiscuit parsed [authorizer|allow if en_subject("user", "alice");|]
    case control of
        Right _ -> pure ()
        Left err -> die ("injection: positive control should pass: " <> show err)

    -- Exploit: the forged fact must not exist as a real Datalog fact.
    exploit <- authorizeBiscuit parsed [authorizer|allow if en_right("document", "secret", "view");|]
    case exploit of
        Left _ -> pure ()
        Right _ -> die "injection: forged en_right fact was queryable — breakout!"

sampleExpiry :: UTCTime
sampleExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 0)

-- | Render a grant to fact text, failing the test if the grant is unencodable.
expectFacts :: EnBiscuitGrant -> IO Text
expectFacts grant =
    case grantFactsText grant of
        Right facts -> pure facts
        Left err -> die ("expected an encodable grant, got: " <> show err)

showResult :: Either EnBiscuitError a -> String
showResult (Left err) = "Left " <> show err
showResult (Right _) = "Right <block>"

assertInfix :: String -> Text -> Text -> IO ()
assertInfix label needle haystack =
    assertBool
        (label <> "\nexpected to find: " <> T.unpack needle <> "\nin: " <> T.unpack haystack)
        (needle `T.isInfixOf` haystack)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
    unless (expected == actual) $
        die (label <> "\nexpected: " <> show expected <> "\nactual:   " <> show actual)

assertBool :: String -> Bool -> IO ()
assertBool label condition = unless condition (die label)

die :: String -> IO a
die msg = do
    putStrLn ("en-biscuit test FAILED: " <> msg)
    exitFailure
