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
  4. Attenuation-scoping tests pinning the @biscuit-haskell@ semantics the whole
     layer rests on: facts added by a holder-appended block are invisible to
     un-annotated queries, to 'En.Biscuit.Verify.verifyGrant', and to plain
     authorizer policies, so a holder can never widen a grant.
-}
module Main (main) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Exit (exitFailure)

import Auth.Biscuit (
    Biscuit,
    Block,
    OpenOrSealed,
    PublicKey,
    SecretKey,
    Verified,
    addBlock,
    authorizeBiscuit,
    authorizer,
    block,
    mkBiscuit,
    mkBiscuitWith,
    newSecret,
    parseB64,
    parseSecretKeyHex,
    query,
    queryRawBiscuitFacts,
    serializeB64,
    toPublic,
 )
import Auth.Biscuit.Datalog.AST (Query)
import Auth.Biscuit.Datalog.Executor (Bindings)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)

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
import En.Biscuit.Keys (IssuerKeyId (..), IssuerKeySet (..), singleKey)
import En.Biscuit.Mint (
    EnBiscuitMintError (..),
    MintConfig (..),
    MintedGrant (..),
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
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
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
    keyIdRoundTripTest
    verifyObjectTests
    verifyScopedTests
    keyRotationTest
    keySelectionAttackTest
    legacyTokenTest
    attenuationTests
    shomeiFlowTest
    attenuationForgedRightTest
    attenuationForgedExpiryTest
    attenuationForgedRevocationTest
    attenuationForgedScopeTest
    attenuationForgedSubjectTest
    authorizerScopingTest
    narrowingDirectionTest
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
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
    result <- mintObjectGrant config Allowed sampleObjectGrant
    bytes <- case result of
        Right b -> pure b.token
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
    let config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
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
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
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
        Right b -> pure b.token
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
        runMintEff $
            mintCheckedObjectGrant
                MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
                kikanGraph
                MinimizeLatency
                emptyCtx
                allowedGrant
    bytes <- case allowed of
        Right b -> pure b.token
        Left e -> die ("mint checked allowed: expected a token, got " <> show e)
    biscuit <- either (die . show) pure (parseB64 public bytes)
    auth <- authorizeBiscuit biscuit [authorizer|allow if en_right("space", "project-x", "view");|]
    case auth of
        Right _ -> pure ()
        Left e -> die ("mint checked allowed: token missing en_right: " <> show e)

    engineErr <-
        runMintEff $
            mintCheckedObjectGrant
                MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
                kikanGraph
                MinimizeLatency
                emptyCtx
                unknownGrant
    case engineErr of
        Left (EngineError _) -> pure ()
        other -> die ("mint checked: engine error should surface, got " <> showMintResult other)

{- | A token minted under a specific issuer key id carries a signature the
matching public key verifies. The key id changes which key a keyset verifier
selects (the rotation story, pinned in 'keyRotationTest'), not the signature
itself, so 'parseB64' with the right public key still succeeds.
-}
keyIdRoundTripTest :: IO ()
keyIdRoundTripTest = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 7, defaultTtl = 3600, now = pure sampleExpiry}
    minted <- either (die . show) pure =<< mintObjectGrant config Allowed sampleObjectGrant
    case parseB64 public minted.token of
        Right _ -> pure ()
        Left e ->
            die ("key id round-trip: token minted under key id 7 must verify with the matching public key, got " <> show e)

{- | Verify an object token: accept the in-scope request; reject wrong audience,
expired, wrong subject, wrong resource, unaccepted schema, and revoked.
-}
verifyObjectTests :: IO ()
verifyObjectTests = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
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
    minted <- either (die . show) pure =<< mintObjectGrant config Allowed grant
    let token = minted.token

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

    valid <- verifyGrant (keySetFor public) token ok
    case valid of
        Right VerifiedGrant{subject = s, operation = op} -> do
            assertEqual "verify: recovered subject" aliceSubject s
            assertEqual "verify: recovered operation" (RelationName "view") op
        Left e -> die ("verify valid: expected success, got " <> show e)

    assertVerifyError "wrong audience" WrongAudience
        =<< verifyGrant (keySetFor public) token ok{expectedAudience = Audience "other-service"}
    assertVerifyError "wrong subject" WrongSubject
        =<< verifyGrant (keySetFor public) token ok{expectedSubject = SubjectId (ObjectRef (ObjectType "user") "bob")}
    assertVerifyError "wrong resource" ResourceNotInScope
        =<< verifyGrant (keySetFor public) token ok{resource = ObjectRef (ObjectType "document") "other"}
    assertVerifyError "unaccepted schema" UnacceptedSchemaHash
        =<< verifyGrant (keySetFor public) token ok{acceptedSchemaHashes = Set.singleton (SchemaHash "sha-zzz")}
    assertVerifyError "revoked" Revoked
        =<< verifyGrant (keySetFor public) token ok{revoked = \r -> pure (r == RevocationId "rev-1")}

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
    assertVerifyError "expired" Expired =<< verifyGrant (keySetFor public) token expiredReq

{- | Verify a scoped token: a request for a container in scope succeeds; a
resource outside the scope fails.
-}
verifyScopedTests :: IO ()
verifyScopedTests = do
    secret <- loadSecret
    let public = toPublic secret
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}
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
    minted <- either (die . show) pure =<< mintScopedGrant config 5 grant
    let token = minted.token

    inScope <-
        verifyGrant (keySetFor public) token $
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
        verifyGrant (keySetFor public) token $
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

{- | The rotation story: an operator can rotate the issuer key by config alone.
Token TA (key A, id 1) and token TB (key B, id 2) both verify against a single
keyset trusting both keys — the overlap window, with the verifier constructed
once and never reconfigured between the two calls. Retiring key A from the keyset
then rejects TA while TB still verifies. No verifier binary is rebuilt.
-}
keyRotationTest :: IO ()
keyRotationTest = do
    secretA <- loadSecret
    secretB <- loadSecretB
    let pubA = toPublic secretA
        pubB = toPublic secretB
        configFor secret keyId =
            MintConfig{issuerSecretKey = secret, issuerKeyId = keyId, defaultTtl = 3600, now = pure sampleExpiry}
    mintedA <- either (die . show) pure =<< mintObjectGrant (configFor secretA (IssuerKeyId 1)) Allowed forgeableObjectGrant
    mintedB <- either (die . show) pure =<< mintObjectGrant (configFor secretB (IssuerKeyId 2)) Allowed forgeableObjectGrant
    let ta = mintedA.token
        tb = mintedB.token

    -- Overlap window: one keyset trusts both keys. Constructed once, used twice.
    let overlap =
            IssuerKeySet
                { keysById = Map.fromList [(IssuerKeyId 1, pubA), (IssuerKeyId 2, pubB)]
                , legacyKey = Nothing
                }
    assertVerified "rotation: overlap keyset verifies the key-A token"
        =<< verifyGrant overlap ta roadmapRequest
    assertVerified "rotation: overlap keyset verifies the key-B token"
        =<< verifyGrant overlap tb roadmapRequest

    -- Retire key A: only TB verifies now; TA fails signature selection.
    let retired = singleKey (IssuerKeyId 2) pubB
    assertVerified "rotation: retired keyset still verifies the key-B token"
        =<< verifyGrant retired tb roadmapRequest
    assertSignatureInvalid "rotation: retired keyset rejects the key-A token"
        =<< verifyGrant retired ta roadmapRequest

{- | A holder must not be able to steer which issuer key the verifier reaches for.
A token signed by key A but claiming root key id 2 (the id the verifier maps to
key B) models an attacker rewriting the envelope's key id. The verifier selects
key B by that id, and A's signature fails against B — fail closed. Selection is
attacker-visible metadata, so this is a new surface introduced by the keyset; it
must reject explicitly, not by accident.
-}
keySelectionAttackTest :: IO ()
keySelectionAttackTest = do
    secretA <- loadSecret
    secretB <- loadSecretB
    let pubB = toPublic secretB
    grantBlk <- either (die . show) pure (grantBlock (ObjectGrant forgeableObjectGrant))
    biscuit <- mkBiscuitWith (Just 2) secretA grantBlk
    let token = serializeB64 biscuit
        keySet = singleKey (IssuerKeyId 2) pubB
    assertSignatureInvalid "key selection: an A-signed token claiming key id 2 must not verify under key B"
        =<< verifyGrant keySet token roadmapRequest

{- | Legacy tokens minted before key ids existed carry no root key id. They verify
against a keyset whose 'legacyKey' is set, and fail against one without it — so
the fleet can keep honoring in-flight legacy tokens through a rotation while new
tokens carry ids.
-}
legacyTokenTest :: IO ()
legacyTokenTest = do
    secretLegacy <- loadSecret
    secretOther <- loadSecretB
    let pubLegacy = toPublic secretLegacy
        pubOther = toPublic secretOther
    grantBlk <- either (die . show) pure (grantBlock (ObjectGrant forgeableObjectGrant))
    -- mkBiscuit is mkBiscuitWith Nothing: no root key id in the envelope.
    biscuit <- mkBiscuit secretLegacy grantBlk
    let token = serializeB64 biscuit
        withLegacy =
            IssuerKeySet{keysById = Map.singleton (IssuerKeyId 1) pubOther, legacyKey = Just pubLegacy}
        withoutLegacy = singleKey (IssuerKeyId 1) pubOther
    assertVerified "legacy: a token with no key id verifies against a keyset carrying the legacy key"
        =<< verifyGrant withLegacy token roadmapRequest
    assertSignatureInvalid "legacy: the same token fails against a keyset without the legacy key"
        =<< verifyGrant withoutLegacy token roadmapRequest

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
        verifyGrant (keySetFor public) token $
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
        verifyGrant (keySetFor public) token $
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
        verifyGrant (keySetFor public) token $
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
        config = MintConfig{issuerSecretKey = secret, issuerKeyId = IssuerKeyId 1, defaultTtl = 3600, now = pure sampleExpiry}

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
    minted <- either (die . show) pure =<< mintObjectGrant config Allowed grant
    let token = minted.token

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
    sameCaller <- verifyGrant (keySetFor public) token (requestFor "alice")
    case sameCaller of
        Right _ -> pure ()
        Left e -> die ("shomei flow: same-subject request should verify, got " <> show e)

    -- Downstream authenticated a different caller -> fail closed (identity
    -- established by the downstream does not match the token's subject).
    impostor <- verifyGrant (keySetFor public) token (requestFor "mallory")
    assertVerifyError "shomei flow: different caller" WrongSubject impostor

{- | Attenuation scoping, forged @en_right@. A holder appends a block asserting a
right over a resource the authority never granted, and a broader permission on
the granted resource. Neither reaches the verifier: un-annotated queries — what
'En.Biscuit.Verify.verifyGrant' uses — read authority facts only.

This test doubles as the syntax spike for @trusting previous@ in the @query@
quasiquoter; if it stops parsing, every positive control below is vacuous.
-}
attenuationForgedRightTest :: IO ()
attenuationForgedRightTest = do
    secret <- loadSecret
    let public = toPublic secret

    -- Forged object: a right over document:secret, never granted.
    (forgedObject, parsedObject) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_right("document", "secret", "view");|]

    control <- queryOrDie "forged en_right" parsedObject [query|en_right("document", "secret", $p) trusting previous|]
    assertBool "forged en_right: the forged fact must be present in the token" (not (Set.null control))
    scoped <- queryOrDie "forged en_right" parsedObject [query|en_right("document", "secret", $p)|]
    assertBool "forged en_right: an un-annotated query must not see the holder block" (Set.null scoped)

    assertVerifyError "forged en_right: widened resource" ResourceNotInScope
        =<< verifyGrant (keySetFor public) forgedObject (roadmapRequest{resource = ObjectRef (ObjectType "document") "secret"})
    -- The genuine request must still succeed: had the forged fact been visible,
    -- two `en_right` rows would make extraction ambiguous and surface
    -- MalformedGrant rather than a verified grant.
    assertVerified "forged en_right: the genuine request still verifies"
        =<< verifyGrant (keySetFor public) forgedObject roadmapRequest

    -- Forged permission: admin on the granted resource.
    (forgedPerm, parsedPerm) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_right("document", "roadmap", "admin");|]

    permControl <- queryOrDie "forged permission" parsedPerm [query|en_right("document", "roadmap", "admin") trusting previous|]
    assertBool "forged permission: the forged fact must be present in the token" (not (Set.null permControl))

    assertVerifyError "forged permission: widened operation" OperationNotAuthorized
        =<< verifyGrant (keySetFor public) forgedPerm (objectRequest (RelationName "admin") roadmapRef verifyNow)
    assertVerified "forged permission: the genuine operation still verifies"
        =<< verifyGrant (keySetFor public) forgedPerm roadmapRequest

{- | Attenuation scoping, forged @en_expires_at@. A holder cannot extend the life
of a token by asserting a later expiry.
-}
attenuationForgedExpiryTest :: IO ()
attenuationForgedExpiryTest = do
    secret <- loadSecret
    let public = toPublic secret

    (token, parsed) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_expires_at(2027-01-01T00:00:00Z);|]

    control <- queryOrDie "forged expiry" parsed [query|en_expires_at($e) trusting previous|]
    assertEqual "forged expiry: the token carries both the real and the forged expiry" 2 (Set.size control)
    scoped <- queryOrDie "forged expiry" parsed [query|en_expires_at($e)|]
    assertEqual "forged expiry: an un-annotated query sees only the authority expiry" 1 (Set.size scoped)

    -- afterExpiry (02:00Z) is past the real expiry (01:00Z) and far short of the
    -- forged one (2027). The verifier must read the real one.
    assertVerifyError "forged expiry: past the real expiry" Expired
        =<< verifyGrant (keySetFor public) token (objectRequest (RelationName "view") roadmapRef afterExpiry)
    assertVerified "forged expiry: before the real expiry" =<< verifyGrant (keySetFor public) token roadmapRequest

{- | Attenuation scoping, forged @en_revocation_id@, in both directions: a holder
can neither shadow a real revocation id to escape revocation, nor plant one in a
token that has none.
-}
attenuationForgedRevocationTest :: IO ()
attenuationForgedRevocationTest = do
    secret <- loadSecret
    let public = toPublic secret

    -- Shadowing: the authority names rev-1; the holder adds rev-clean, hoping
    -- the verifier reads theirs (or reads neither, because two rows are
    -- ambiguous, and so skips the revocation check entirely).
    (shadowed, _) <-
        forgedToken
            secret
            (ObjectGrant (forgeableObjectGrantWith (Just (RevocationId "rev-1"))))
            [block|en_revocation_id("rev-clean");|]
    let revokesRev1 r = pure (r == RevocationId "rev-1")
    assertVerifyError "forged revocation: shadowing does not evade revocation" Revoked
        =<< verifyGrant (keySetFor public) shadowed roadmapRequest{revoked = revokesRev1}

    -- Planting: the authority names no revocation id, so the verifier must never
    -- consult the caller's revocation check at all.
    (planted, parsedPlanted) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_revocation_id("rev-x");|]
    control <- queryOrDie "planted revocation" parsedPlanted [query|en_revocation_id("rev-x") trusting previous|]
    assertBool "planted revocation: the forged id must be present in the token" (not (Set.null control))

    asked <- newIORef []
    let recordAsk r = modifyIORef' asked (r :) >> pure False
    assertVerified "planted revocation: the token still verifies"
        =<< verifyGrant (keySetFor public) planted roadmapRequest{revoked = recordAsk}
    consulted <- readIORef asked
    assertEqual "planted revocation: the forged id never reached the revocation check" [] consulted

{- | Attenuation scoping, forged @en_container_scope@. A scoped grant lists its
containers as separate facts, so a holder-added container is the most natural
widening attack: 'En.Biscuit.Verify.resolveScope' collects /every/ matching row.
-}
attenuationForgedScopeTest :: IO ()
attenuationForgedScopeTest = do
    secret <- loadSecret
    let public = toPublic secret

    (token, parsed) <-
        forgedToken secret (ScopedGrant forgeableScopedGrant) [block|en_container_scope("folder", "f9");|]

    control <- queryOrDie "forged scope" parsed [query|en_container_scope($t, $i) trusting previous|]
    assertEqual "forged scope: the token carries three containers" 3 (Set.size control)
    scoped <- queryOrDie "forged scope" parsed [query|en_container_scope($t, $i)|]
    assertEqual "forged scope: an un-annotated query sees only the authority's two" 2 (Set.size scoped)

    assertVerifyError "forged scope: the added container is out of scope" ResourceNotInScope
        =<< verifyGrant (keySetFor public) token (scopedRequest (ObjectRef (ObjectType "folder") "f9"))
    assertVerified "forged scope: a genuine container still verifies"
        =<< verifyGrant (keySetFor public) token (scopedRequest (ObjectRef (ObjectType "folder") "f1"))

{- | Attenuation scoping, forged @en_subject@. A holder cannot re-point a grant at
another principal.
-}
attenuationForgedSubjectTest :: IO ()
attenuationForgedSubjectTest = do
    secret <- loadSecret
    let public = toPublic secret

    (token, parsed) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_subject("user", "mallory");|]

    control <- queryOrDie "forged subject" parsed [query|en_subject("user", "mallory") trusting previous|]
    assertBool "forged subject: the forged fact must be present in the token" (not (Set.null control))
    scoped <- queryOrDie "forged subject" parsed [query|en_subject($t, $i)|]
    assertEqual "forged subject: an un-annotated query sees only the authority subject" 1 (Set.size scoped)

    let mallory = SubjectId (ObjectRef (ObjectType "user") "mallory")
    assertVerifyError "forged subject: mallory cannot use alice's grant" WrongSubject
        =<< verifyGrant (keySetFor public) token roadmapRequest{expectedSubject = mallory}
    assertVerified "forged subject: alice's own request still verifies"
        =<< verifyGrant (keySetFor public) token roadmapRequest

{- | The same guarantee for consumers that never touch en's verifier: a plain
@allow if@ policy is scoped to the authority block too, so a forged fact cannot
satisfy it. This is what @docs/user/biscuit-decision-tokens.md@ promises services
in other stacks.
-}
authorizerScopingTest :: IO ()
authorizerScopingTest = do
    secret <- loadSecret
    (_, parsed) <-
        forgedToken secret (ObjectGrant forgeableObjectGrant) [block|en_right("document", "secret", "view");|]

    forged <- authorizeBiscuit parsed [authorizer|allow if en_right("document", "secret", "view");|]
    case forged of
        Left _ -> pure ()
        Right _ -> die "authorizer scoping: a forged holder fact satisfied an allow policy — breakout!"

    genuine <- authorizeBiscuit parsed [authorizer|allow if en_right("document", "roadmap", "view");|]
    case genuine of
        Right _ -> pure ()
        Left err -> die ("authorizer scoping: the authority fact should satisfy the policy: " <> show err)

{- | Attenuation is one-way. 'attenuationTests' already pins the legal direction
(a narrowed token fails requests its parent passed). This pins the illegal one,
with the strongest block an attacker can write: a forged widening fact /plus/ a
check that matches it, since a block's own checks may read its own facts.
-}
narrowingDirectionTest :: IO ()
narrowingDirectionTest = do
    secret <- loadSecret
    let public = toPublic secret
        f1 = ObjectRef (ObjectType "folder") "f1"
        f9 = ObjectRef (ObjectType "folder") "f9"

    grantBlk <- either (die . show) pure (grantBlock (ScopedGrant forgeableScopedGrant))
    parent <- serializeB64 <$> mkBiscuit secret grantBlk

    (attacked, _) <-
        forgedToken
            secret
            (ScopedGrant forgeableScopedGrant)
            [block|
              en_container_scope("folder", "f9");
              check if resource($t, $i), $t == "folder", $i == "f9";
            |]

    -- The parent passes f1 and fails f9. The attack block cannot flip f9.
    assertVerified "narrowing: the parent token authorizes a genuine container"
        =<< verifyGrant (keySetFor public) parent (scopedRequest f1)
    assertVerifyError "narrowing: the parent token rejects a container it never held" ResourceNotInScope
        =<< verifyGrant (keySetFor public) parent (scopedRequest f9)
    assertVerifyError "narrowing: a forged fact plus a matching check cannot widen the scope" ResourceNotInScope
        =<< verifyGrant (keySetFor public) attacked (scopedRequest f9)

    -- And the block's own check can only narrow: it now rejects f1, which the
    -- parent allowed.
    assertRestrictionFailed "narrowing: the attacker's own check narrows their token"
        =<< verifyGrant (keySetFor public) attacked (scopedRequest f1)

{- | Mint an authority block for @grant@, then let a holder append @forged@. The
result is exactly what a malicious bearer can produce from a genuine token.
-}
forgedToken :: SecretKey -> EnBiscuitGrant -> Block -> IO (ByteString, Biscuit OpenOrSealed Verified)
forgedToken secret grant forged = do
    grantBlk <- either (die . show) pure (grantBlock grant)
    authority <- mkBiscuit secret grantBlk
    tampered <- addBlock forged authority
    let bytes = serializeB64 tampered
    parsed <- either (die . show) pure (parseB64 (toPublic secret) bytes)
    pure (bytes, parsed)

queryOrDie :: String -> Biscuit OpenOrSealed Verified -> Query -> IO (Set Bindings)
queryOrDie label biscuit q =
    either (\err -> die (label <> ": query failed: " <> err)) pure (queryRawBiscuitFacts biscuit q)

assertVerified :: String -> Either EnBiscuitVerifyError VerifiedGrant -> IO ()
assertVerified label result =
    case result of
        Right _ -> pure ()
        Left err -> die (label <> ": expected success, got " <> show err)

{- | An object grant for alice over @document:roadmap@, expiring at 01:00Z so
'verifyNow' (00:30Z) is inside it and 'afterExpiry' (02:00Z) is outside.
-}
forgeableObjectGrant :: EnGrant
forgeableObjectGrant = forgeableObjectGrantWith Nothing

-- | 'forgeableObjectGrant', optionally carrying an application revocation id.
forgeableObjectGrantWith :: Maybe RevocationId -> EnGrant
forgeableObjectGrantWith mRevocationId =
    EnGrant
        { subject = aliceSubject
        , permission = RelationName "view"
        , object = roadmapRef
        , consistencyToken = ConsistencyToken "zk-123"
        , schemaHash = SchemaHash "sha-abc"
        , expiresAt = laterExpiry
        , audience = Audience "billing-service"
        , requestId = Nothing
        , revocationId = mRevocationId
        }

roadmapRef :: ObjectRef
roadmapRef = ObjectRef (ObjectType "document") "roadmap"

-- | A scoped grant for alice over @folder:f1@ and @folder:f2@, expiring at 01:00Z.
forgeableScopedGrant :: EnScopedGrant
forgeableScopedGrant =
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

-- | The request 'forgeableObjectGrant' authorizes, at a clock before its expiry.
roadmapRequest :: VerifyRequest IO
roadmapRequest = objectRequest (RelationName "view") roadmapRef verifyNow

-- | An alice/billing-service request for a given operation, resource, and clock.
objectRequest :: RelationName -> ObjectRef -> UTCTime -> VerifyRequest IO
objectRequest op resourceRef nowT =
    mkVerifyRequest
        aliceSubject
        (Audience "billing-service")
        op
        resourceRef
        (Audience "billing-service")
        acceptedSchemas
        nowT
        (const (pure False))

-- | The request 'forgeableScopedGrant' authorizes for a given container.
scopedRequest :: ObjectRef -> VerifyRequest IO
scopedRequest container = objectRequest (RelationName "view") container verifyNow

verifyNow :: UTCTime
verifyNow = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 1800)

afterExpiry :: UTCTime
afterExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 7200)

laterExpiry :: UTCTime
laterExpiry = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 3600)

aliceSubject :: Subject
aliceSubject = SubjectId (ObjectRef (ObjectType "user") "alice")

{- | A single-key keyset under key id 1, the default the mint tests sign with.
Most verify tests trust exactly the issuer that minted their token.
-}
keySetFor :: PublicKey -> IssuerKeySet
keySetFor = singleKey (IssuerKeyId 1)

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

{- | Assert a signature/parse rejection without pinning the underlying
@ParseError@ text, which the library owns.
-}
assertSignatureInvalid :: String -> Either EnBiscuitVerifyError VerifiedGrant -> IO ()
assertSignatureInvalid label result =
    case result of
        Left (SignatureInvalid _) -> pure ()
        other -> die (label <> ": expected SignatureInvalid, got " <> showVerify other)

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

{- | A second deterministic issuer key, distinct from 'loadSecret', for the
rotation and key-selection tests. Any 32 bytes is a valid ed25519 secret.
-}
loadSecretB :: IO SecretKey
loadSecretB =
    maybe
        (die "could not parse the second deterministic secret key")
        pure
        (parseSecretKeyHex "b2c4ead323536b925f3488ee83e0888b79c2761405ca7c0c9a018c7c1905eecd")

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

{- | Run a mint against the in-memory stores.

The @Error EnError@ handler is required by 'runTupleStoreInMemory', which can now
raise 'WritePreconditionFailed'. Minting only reads, so it never fires; if it ever
does, that is a bug worth dying on rather than folding into the mint's own error
type.
-}
runMintEff :: Eff '[ConsistencyStore, TupleStore, Error EnError, IOE] a -> IO a
runMintEff action = do
    outcome <-
        runEff
            . runErrorNoCallStack @EnError
            . runTupleStoreInMemory fixtureTuples
            . runConsistencyStoreInMemory
            $ action
    either (die . ("in-memory store raised: " <>) . show) pure outcome

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
