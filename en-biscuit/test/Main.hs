{-# LANGUAGE QuasiQuotes #-}

{- | Tests for en-biscuit. Three groups:

  1. A dependency smoke test proving @biscuit-haskell@ is wired correctly
     (mint, serialize, re-parse, authorize a Biscuit).
  2. Grant-vocabulary tests proving 'En.Biscuit.Grant' renders the stable
     predicate vocabulary for object and container-scoped grants, encodes the
     subject/schema-hash/consistency-token/audience/expiry metadata, fails
     closed on non-concrete subjects, and cannot be broken out of via
     punctuation in field values.
  3. Minting tests proving 'En.Biscuit.Mint' mints only on 'Allowed', fails
     closed on 'Denied'/'Conditional'/engine errors, stamps @now + defaultTtl@
     expiry, propagates consistency token and schema hash, and bounds scoped
     grants.
-}
module Main (main) where

import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Exit (exitFailure)

import Auth.Biscuit (
    SecretKey,
    addBlock,
    authorizeBiscuit,
    authorizer,
    block,
    mkBiscuit,
    newSecret,
    parseB64,
    parseSecretKeyHex,
    serializeB64,
    toPublic,
 )
import Effectful (runEff)

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
import En.Biscuit.Mint (
    EnBiscuitMintError (..),
    MintConfig (..),
    mintCheckedObjectGrant,
    mintObjectGrant,
    mintScopedGrant,
 )
import En.Biscuit.Verify (
    Attenuation (..),
    EnBiscuitVerifyError (..),
    VerifiedGrant (..),
    VerifyRequest (..),
    attenuateGrant,
    noAttenuation,
    verifyGrant,
 )
import En.Conformance.Kikan (
    fixtureTuples,
    kikanGraph,
    runConsistencyStoreInMemory,
    runTupleStoreInMemory,
 )
import En.Decision (CaveatObligation (..), CheckDecision (..))
import En.Revision (Consistency (..), ConsistencyToken (..), SchemaHash (..))
import En.Schema (CaveatName (..), ObjectType (..), RelationName (..))
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..))

main :: IO ()
main = do
    biscuitSmokeTest
    objectGrantTest
    scopedGrantTest
    unsupportedSubjectTest
    injectionSafetyTest
    mintAllowedTest
    mintFailClosedTest
    mintScopedTest
    mintCheckedTest
    verifyObjectTests
    verifyScopedTests
    attenuationTests
    shomeiFlowTest
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

{- | An 'Allowed' object decision mints a token carrying @en_right@, propagates
the consistency token and schema hash, and stamps @now + defaultTtl@ expiry.
-}
mintAllowedTest :: IO ()
mintAllowedTest = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
    result <- mintObjectGrant config Allowed sampleObjectGrant
    bytes <- case result of
        Right b -> pure b
        Left e -> die ("mint allowed: expected a token, got " <> show e)
    biscuit <- either (die . show) pure (parseB64 public bytes)
    -- One authorization proves en_right + consistency token + schema hash are
    -- present, and the expiry sits in (now+30m, now+90m) i.e. equals now+60m.
    auth <-
        authorizeBiscuit
            biscuit
            [authorizer|
              allow if
                en_right("document", "roadmap", "view"),
                en_consistency_token("zk-123"),
                en_schema_hash("sha-abc"),
                en_expires_at($t), $t > 2026-07-01T00:30:00Z, $t < 2026-07-01T01:30:00Z;
            |]
    case auth of
        Right _ -> pure ()
        Left e -> die ("mint allowed: token missing expected facts or expiry: " <> show e)

-- | 'Denied', 'Conditional', and (below) engine errors never mint a token.
mintFailClosedTest :: IO ()
mintFailClosedTest = do
    secret <- loadSecret
    let config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
    denied <- mintObjectGrant config Denied sampleObjectGrant
    assertEqual "mint denied fails closed" (Left DecisionDenied) denied
    let obligations = [CaveatObligation{caveat = CaveatName "within_hours", missingContext = ["now"]}]
    conditional <- mintObjectGrant config (Conditional obligations) sampleObjectGrant
    assertEqual "mint conditional fails closed" (Left (DecisionConditional obligations)) conditional

-- | Scoped minting emits one container fact per container and bounds the scope.
mintScopedTest :: IO ()
mintScopedTest = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
        grant =
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
                , audience = Audience "svc"
                , requestId = Nothing
                , revocationId = Nothing
                }
    ok <- mintScopedGrant config 5 grant
    bytes <- case ok of
        Right b -> pure b
        Left e -> die ("mint scoped: expected a token, got " <> show e)
    biscuit <- either (die . show) pure (parseB64 public bytes)
    auth <-
        authorizeBiscuit
            biscuit
            [authorizer|
              allow if
                en_scoped_right("document", "edit"),
                en_container_scope("folder", "f1"),
                en_container_scope("folder", "f2");
            |]
    case auth of
        Right _ -> pure ()
        Left e -> die ("mint scoped: token missing scope facts: " <> show e)

    tooBig <- mintScopedGrant config 1 grant
    assertEqual "mint scoped rejects oversized scope" (Left (LookupScopeTooLarge 1 2)) tooBig

    emptyScope <- mintScopedGrant config 5 grant{containers = []}
    assertEqual "mint scoped rejects empty scope" (Left EmptyLookupScope) emptyScope

{- | The @effectful@ convenience runs @en.check@: it mints on 'Allowed' and
surfaces engine errors as 'EngineError' without minting.
-}
mintCheckedTest :: IO ()
mintCheckedTest = do
    secret <- loadSecret
    let public = toPublic secret
        emptyCtx = CaveatContext Map.empty
        allowedGrant =
            objectGrantFor
                (SubjectId (ObjectRef (ObjectType "user") "alice"))
                (RelationName "view")
                (ObjectRef (ObjectType "space") "project-x")
        unknownGrant =
            objectGrantFor
                (SubjectId (ObjectRef (ObjectType "user") "alice"))
                (RelationName "no-such-permission")
                (ObjectRef (ObjectType "space") "project-x")

    allowed <-
        runEff . runTupleStoreInMemory fixtureTuples . runConsistencyStoreInMemory $
            mintCheckedObjectGrant
                MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
                kikanGraph
                MinimizeLatency
                emptyCtx
                allowedGrant
    bytes <- case allowed of
        Right b -> pure b
        Left e -> die ("mint checked allowed: expected a token, got " <> show e)
    biscuit <- either (die . show) pure (parseB64 public bytes)
    auth <- authorizeBiscuit biscuit [authorizer|allow if en_right("space", "project-x", "view");|]
    case auth of
        Right _ -> pure ()
        Left e -> die ("mint checked allowed: token missing en_right: " <> show e)

    engineErr <-
        runEff . runTupleStoreInMemory fixtureTuples . runConsistencyStoreInMemory $
            mintCheckedObjectGrant
                MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
                kikanGraph
                MinimizeLatency
                emptyCtx
                unknownGrant
    case engineErr of
        Left (EngineError _) -> pure ()
        other -> die ("mint checked: engine error should surface, got " <> showMintResult other)

{- | Verify an object token: accept the in-scope request; reject wrong audience,
expired, wrong subject, wrong resource, unaccepted schema, and revoked.
-}
verifyObjectTests :: IO ()
verifyObjectTests = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
        grant =
            EnGrant
                { subject = aliceSubject
                , permission = RelationName "view"
                , object = ObjectRef (ObjectType "document") "roadmap"
                , consistencyToken = ConsistencyToken "zk-123"
                , schemaHash = SchemaHash "sha-abc"
                , expiresAt = sampleExpiry
                , audience = Audience "billing-service"
                , requestId = Just (RequestId "req-1")
                , revocationId = Just (RevocationId "rev-1")
                }
    token <- either (die . show) pure =<< mintObjectGrant config Allowed grant

    let ok =
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "document") "roadmap")
                (Audience "billing-service")
                acceptedSchemas
                verifyNow
                (const (pure False))

    valid <- verifyGrant public token ok
    case valid of
        Right VerifiedGrant{subject = s, operation = op} -> do
            assertEqual "verify: recovered subject" aliceSubject s
            assertEqual "verify: recovered operation" (RelationName "view") op
        Left e -> die ("verify valid: expected success, got " <> show e)

    assertVerifyError "wrong audience" WrongAudience
        =<< verifyGrant public token ok{expectedAudience = Audience "other-service"}
    assertVerifyError "wrong subject" WrongSubject
        =<< verifyGrant public token ok{expectedSubject = SubjectId (ObjectRef (ObjectType "user") "bob")}
    assertVerifyError "wrong resource" ResourceNotInScope
        =<< verifyGrant public token ok{resource = ObjectRef (ObjectType "document") "other"}
    assertVerifyError "unaccepted schema" UnacceptedSchemaHash
        =<< verifyGrant public token ok{acceptedSchemaHashes = Set.singleton (SchemaHash "sha-zzz")}
    assertVerifyError "revoked" Revoked
        =<< verifyGrant public token ok{revoked = \r -> pure (r == RevocationId "rev-1")}

    -- Expired needs a request clock after expiry (now + defaultTtl = 01:00Z).
    let expiredReq =
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "document") "roadmap")
                (Audience "billing-service")
                acceptedSchemas
                afterExpiry
                (const (pure False))
    assertVerifyError "expired" Expired =<< verifyGrant public token expiredReq

{- | Verify a scoped token: a request for a container in scope succeeds; a
resource outside the scope fails.
-}
verifyScopedTests :: IO ()
verifyScopedTests = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}
        grant =
            EnScopedGrant
                { subject = aliceSubject
                , permission = RelationName "view"
                , objectType = ObjectType "document"
                , containers =
                    [ ObjectRef (ObjectType "folder") "f1"
                    , ObjectRef (ObjectType "folder") "f2"
                    ]
                , consistencyToken = ConsistencyToken "zk-456"
                , schemaHash = SchemaHash "sha-abc"
                , expiresAt = sampleExpiry
                , audience = Audience "billing-service"
                , requestId = Nothing
                , revocationId = Nothing
                }
    token <- either (die . show) pure =<< mintScopedGrant config 5 grant

    inScope <-
        verifyGrant public token $
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "folder") "f1")
                (Audience "billing-service")
                acceptedSchemas
                verifyNow
                (const (pure False))
    case inScope of
        Right _ -> pure ()
        Left e -> die ("verify scoped in-scope: expected success, got " <> show e)

    outOfScope <-
        verifyGrant public token $
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "folder") "f9")
                (Audience "billing-service")
                acceptedSchemas
                verifyNow
                (const (pure False))
    assertVerifyError "scoped resource outside scope" ResourceNotInScope outOfScope

{- | Attenuate a scoped token to one resource and one service; the narrowed
request still verifies, but the original broader requests do not.
-}
attenuationTests :: IO ()
attenuationTests = do
    secret <- loadSecret
    let public = toPublic secret
        grant =
            EnScopedGrant
                { subject = aliceSubject
                , permission = RelationName "view"
                , objectType = ObjectType "document"
                , containers =
                    [ ObjectRef (ObjectType "folder") "f1"
                    , ObjectRef (ObjectType "folder") "f2"
                    ]
                , consistencyToken = ConsistencyToken "zk-456"
                , schemaHash = SchemaHash "sha-abc"
                , expiresAt = laterExpiry
                , audience = Audience "billing-service"
                , requestId = Nothing
                , revocationId = Nothing
                }
    grantBlk <- either (die . show) pure (grantBlock (ScopedGrant grant))
    biscuit <- mkBiscuit secret grantBlk
    narrowed <-
        attenuateGrant
            noAttenuation
                { narrowedResource = Just (ObjectRef (ObjectType "folder") "f1")
                , narrowedService = Just (Audience "document-service")
                }
            biscuit
    let token = serializeB64 narrowed

    narrowedOk <-
        verifyGrant public token $
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "folder") "f1")
                (Audience "document-service")
                acceptedSchemas
                verifyNow
                (const (pure False))
    case narrowedOk of
        Right _ -> pure ()
        Left e -> die ("attenuation: narrowed request should verify, got " <> show e)

    otherResource <-
        verifyGrant public token $
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "folder") "f2")
                (Audience "document-service")
                acceptedSchemas
                verifyNow
                (const (pure False))
    assertRestrictionFailed "attenuation blocks the other in-scope resource" otherResource

    otherService <-
        verifyGrant public token $
            mkVerifyRequest
                aliceSubject
                (Audience "billing-service")
                (RelationName "view")
                (ObjectRef (ObjectType "folder") "f1")
                (Audience "thumbnail-service")
                acceptedSchemas
                verifyNow
                (const (pure False))
    assertRestrictionFailed "attenuation blocks a different service" otherService

{- | A stand-in for a verified Shomei principal. @en-biscuit@ does not depend on
Shomei; the real host maps @Shomei.Servant.Auth.AuthUser@ the same way.
-}
newtype AuthenticatedUser = AuthenticatedUser {authUserId :: Text}

{- | The whole coupling between authentication and authorization: a verified user
id becomes an en subject.
-}
subjectFromUserId :: Text -> Subject
subjectFromUserId userId = SubjectId (ObjectRef (ObjectType "user") userId)

{- | End-to-end: gateway maps a verified identity to a subject and mints on
Allowed; a downstream that authenticates the SAME subject verifies the token,
but a downstream that authenticates a different caller fails closed.
-}
shomeiFlowTest :: IO ()
shomeiFlowTest = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, defaultTtl = 3600, now = pure sampleExpiry}

    -- Gateway: verified Shomei identity -> en subject -> mint.
    let AuthenticatedUser{authUserId = gatewayUserId} = AuthenticatedUser{authUserId = "alice"}
        subject = subjectFromUserId gatewayUserId
        grant =
            EnGrant
                { subject = subject
                , permission = RelationName "view"
                , object = ObjectRef (ObjectType "document") "roadmap"
                , consistencyToken = ConsistencyToken "zk-123"
                , schemaHash = SchemaHash "sha-abc"
                , expiresAt = sampleExpiry
                , audience = Audience "document-service"
                , requestId = Nothing
                , revocationId = Nothing
                }
    token <- either (die . show) pure =<< mintObjectGrant config Allowed grant

    let requestFor authenticated =
            mkVerifyRequest
                (subjectFromUserId authenticated)
                (Audience "document-service")
                (RelationName "view")
                (ObjectRef (ObjectType "document") "roadmap")
                (Audience "document-service")
                acceptedSchemas
                verifyNow
                (const (pure False))

    -- Downstream authenticated the same caller -> the decision proof verifies.
    sameCaller <- verifyGrant public token (requestFor "alice")
    case sameCaller of
        Right _ -> pure ()
        Left e -> die ("shomei flow: same-subject request should verify, got " <> show e)

    -- Downstream authenticated a different caller -> fail closed (identity
    -- established by the downstream does not match the token's subject).
    impostor <- verifyGrant public token (requestFor "mallory")
    assertVerifyError "shomei flow: different caller" WrongSubject impostor

verifyNow :: UTCTime
verifyNow = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 1800)

afterExpiry :: UTCTime
afterExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 7200)

laterExpiry :: UTCTime
laterExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 3600)

aliceSubject :: Subject
aliceSubject = SubjectId (ObjectRef (ObjectType "user") "alice")

acceptedSchemas :: Set SchemaHash
acceptedSchemas = Set.singleton (SchemaHash "sha-abc")

mkVerifyRequest ::
    Subject ->
    Audience ->
    RelationName ->
    ObjectRef ->
    Audience ->
    Set SchemaHash ->
    UTCTime ->
    (RevocationId -> IO Bool) ->
    VerifyRequest IO
mkVerifyRequest subj aud op res svc schemas nowT rev =
    VerifyRequest
        { expectedSubject = subj
        , expectedAudience = aud
        , operation = op
        , resource = res
        , serviceName = svc
        , acceptedSchemaHashes = schemas
        , now = nowT
        , revoked = rev
        }

assertVerifyError :: String -> EnBiscuitVerifyError -> Either EnBiscuitVerifyError VerifiedGrant -> IO ()
assertVerifyError label expected result =
    case result of
        Left err | err == expected -> pure ()
        other -> die ("verify " <> label <> ": expected Left " <> show expected <> ", got " <> showVerify other)

assertRestrictionFailed :: String -> Either EnBiscuitVerifyError VerifiedGrant -> IO ()
assertRestrictionFailed label result =
    case result of
        Left (RestrictionFailed _) -> pure ()
        other -> die (label <> ": expected RestrictionFailed, got " <> showVerify other)

showVerify :: Either EnBiscuitVerifyError VerifiedGrant -> String
showVerify (Left err) = "Left " <> show err
showVerify (Right _) = "Right <verified grant>"

sampleExpiry :: UTCTime
sampleExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 0)

{- | The deterministic issuer key from @Auth.Biscuit.Example@, so tokens sign
reproducibly across runs.
-}
loadSecret :: IO SecretKey
loadSecret =
    maybe
        (die "could not parse the deterministic secret key")
        pure
        (parseSecretKeyHex "a2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecc")

{- | A default object grant; @consistencyToken@/@schemaHash@ match the mint
authorizers above.
-}
objectGrantFor :: Subject -> RelationName -> ObjectRef -> EnGrant
objectGrantFor subj perm obj =
    EnGrant
        { subject = subj
        , permission = perm
        , object = obj
        , consistencyToken = ConsistencyToken "zk-123"
        , schemaHash = SchemaHash "sha-abc"
        , expiresAt = sampleExpiry
        , audience = Audience "svc"
        , requestId = Nothing
        , revocationId = Nothing
        }

sampleObjectGrant :: EnGrant
sampleObjectGrant =
    objectGrantFor
        (SubjectId (ObjectRef (ObjectType "user") "alice"))
        (RelationName "view")
        (ObjectRef (ObjectType "document") "roadmap")

showMintResult :: Either EnBiscuitMintError a -> String
showMintResult (Left err) = "Left " <> show err
showMintResult (Right _) = "Right <token>"

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
