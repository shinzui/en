{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : En.Biscuit.Verify
-- Description : Local, fail-closed verification and attenuation of en Biscuit grants.
--
-- A downstream service uses this module to check a Biscuit token /in its own
-- process/ — no call to @en-server@ — and to attenuate a token before forwarding
-- it further down the chain. It is the delegated, local counterpart of
-- 'En.Servant.Authorize.requirePermission': same fail-closed posture, but the
-- decision was already made upstream and is carried in the signed token.
--
-- == What verification checks
--
-- 'verifyGrant' verifies, in order:
--
--   1. the issuer signature ('Auth.Biscuit.parseWith', selecting the trusted issuer
--      public key from the keyset by the token's root key id — so an operator can
--      rotate the issuer key by config alone);
--   2. token expiry against the request clock;
--   3. the token subject matches the authenticated subject;
--   4. the token audience matches the expected audience;
--   5. the token schema hash is one the service accepts;
--   6. the requested operation and resource are within the grant (an object grant
--      names one resource; a scoped grant lists its containers and the resource
--      must be one of them);
--   7. the token is not revoked — its built-in block revocation ids are checked
--      against the caller's revocation set on every parse ('revokedBlockIds', which
--      applies to every token), and any application-level @en_revocation_id@ is
--      checked too ('revoked', an optional convenience);
--   8. any attenuation restrictions added by intermediate holders still allow this
--      exact request.
--
-- Each failure is a distinct, explicit 'EnBiscuitVerifyError'. The verifier never
-- falls back to calling @en@; a caller may choose to after a local failure, but
-- that is its decision.
--
-- == Two fact layers
--
-- The token's authority block carries the immutable @en_*@ grant facts from
-- "En.Biscuit.Grant" (checked in steps 2–7 by extracting them and comparing in
-- Haskell, which is where the precise error values come from). Attenuation
-- (step 8) adds blocks of Datalog @check if@ clauses that constrain the /ambient
-- request facts/ the verifier supplies to an authorizer — @operation@, @resource@,
-- @service@, @time@. Biscuit guarantees an added block can only add checks, never
-- remove authority or broaden an earlier one, so attenuation is monotonic
-- narrowing.
module En.Biscuit.Verify
  ( -- * Verification
    VerifyRequest (..),
    VerifiedGrant (..),
    VerifiedScope (..),
    EnBiscuitVerifyError (..),
    verifyGrant,

    -- * Attenuation
    Attenuation (..),
    noAttenuation,
    attenuateGrant,
  )
where

import Auth.Biscuit
  ( Biscuit,
    BiscuitEncoding (..),
    Block,
    FromValue (..),
    Open,
    OpenOrSealed,
    ParseError (..),
    ParserConfig (..),
    Verified,
    addBlock,
    authorizeBiscuit,
    authorizer,
    block,
    getSingleVariableValue,
    parseWith,
    query,
    queryRawBiscuitFacts,
  )
import Auth.Biscuit.Datalog.AST (Query)
import Auth.Biscuit.Datalog.Executor (Bindings)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import En.Biscuit.Grant (Audience (..), RequestId (..), RevocationId (..))
import En.Biscuit.Keys (IssuerKeySet, selectIssuerKey)
import En.Prelude hiding (op)
import En.Revision (ConsistencyToken (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..))

-- | What the downstream service asserts about the current request. Parameterized
-- over @m@ so the revocation check can run in the host's monad (@IO@, @Handler@,
-- @Eff es@, …).
data VerifyRequest m = VerifyRequest
  { -- | The authenticated principal (usually mapped from a verified Shomei
    --     identity); must equal the token's @en_subject@.
    expectedSubject :: Subject,
    -- | The audience the token must have been minted for; must equal
    --     @en_audience@.
    expectedAudience :: Audience,
    -- | The operation being attempted; must equal the grant's permission.
    operation :: RelationName,
    -- | The target object; must equal the object grant's resource or be one of a
    --     scoped grant's containers.
    resource :: ObjectRef,
    -- | This verifying service's own identity, supplied to the authorizer as the
    --     @service@ fact. Attenuation can narrow which service may use the token.
    serviceName :: Audience,
    -- | Schema hashes this service trusts; the token's @en_schema_hash@ must be
    --     one of them.
    acceptedSchemaHashes :: Set SchemaHash,
    -- | The request clock, checked against @en_expires_at@ and any narrowed
    --     expiry.
    now :: UTCTime,
    -- | Whether the token's application-level @en_revocation_id@ (if any) is
    --     revoked. An optional convenience layer: it fires only for tokens that carry
    --     an @en_revocation_id@ fact. For unconditional revocation use
    --     'revokedBlockIds', which applies to every token.
    revoked :: RevocationId -> m Bool,
    -- | Whether ANY of the token's built-in block revocation ids is revoked.
    --     Consulted on every verification, before blocks are decoded, so it applies to
    --     every token regardless of whether it carries an application-level
    --     @en_revocation_id@. The argument is the set of the token's block revocation
    --     ids (signature bytes, one per block, including any attenuation blocks). Build
    --     it with 'Auth.Biscuit.fromRevocationList' from a static revocation list, or
    --     pass @const (pure False)@ if you do not maintain a revocation set.
    revokedBlockIds :: Set ByteString -> m Bool
  }
  deriving stock (Generic)

-- | The scope a verified grant authorizes.
data VerifiedScope
  = -- | An object grant: exactly this resource.
    VerifiedObject ObjectRef
  | -- | A scoped grant: any of these containers.
    VerifiedContainers [ObjectRef]
  deriving stock (Generic, Eq, Show)

-- | The facts recovered from a successfully verified token, so a handler can log
-- or propagate them without re-parsing.
data VerifiedGrant = VerifiedGrant
  { subject :: Subject,
    audience :: Audience,
    operation :: RelationName,
    scope :: VerifiedScope,
    schemaHash :: SchemaHash,
    consistencyToken :: ConsistencyToken,
    expiresAt :: UTCTime,
    requestId :: Maybe RequestId
  }
  deriving stock (Generic, Eq, Show)

-- | Why a token was rejected. Every constructor is a fail-closed rejection.
data EnBiscuitVerifyError
  = -- | Parsing or signature verification failed (carries the shown
    --       @ParseError@).
    SignatureInvalid Text
  | -- | A required @en_*@ fact was missing or unreadable.
    MalformedGrant Text
  | -- | @now@ is at or after the token's expiry.
    Expired
  | -- | The token subject does not match 'expectedSubject'.
    WrongSubject
  | -- | The token audience does not match 'expectedAudience'.
    WrongAudience
  | -- | The token schema hash is not in 'acceptedSchemaHashes'.
    UnacceptedSchemaHash
  | -- | The grant's permission does not match the requested 'operation'.
    OperationNotAuthorized
  | -- | The requested 'resource' is not the object grant's resource, nor one
    --       of a scoped grant's containers.
    ResourceNotInScope
  | -- | The token's @en_revocation_id@ is revoked.
    Revoked
  | -- | An attenuation restriction rejects this request (carries the shown
    --       authorizer error).
    RestrictionFailed Text
  deriving stock (Eq, Show)

-- | Verify a serialized token against a trusted issuer keyset and the request.
-- The token's root key id selects which key in the keyset checks the signature
-- ('selectIssuerKey'), so rotating the issuer key is a keyset config change, not a
-- verifier redeploy. Returns the recovered grant on success, or the first failing
-- check.
verifyGrant ::
  (MonadIO m) =>
  IssuerKeySet ->
  ByteString ->
  VerifyRequest m ->
  m (Either EnBiscuitVerifyError VerifiedGrant)
verifyGrant keySet token request = do
  parsed <-
    parseWith
      ParserConfig
        { encoding = UrlBase64,
          -- Unconditional revocation: the parser hands us the set of the
          -- token's built-in block revocation ids before any block is
          -- decoded, so every token is revocable regardless of whether it
          -- carries an application-level en_revocation_id.
          isRevoked = (request ^. #revokedBlockIds),
          getPublicKey = selectIssuerKey keySet
        }
      token
  case parsed of
    -- A built-in block revocation id was in the caller's set; distinct from a
    -- bad signature so the caller can tell revocation from forgery.
    Left RevokedBiscuit -> pure (Left Revoked)
    Left parseErr -> pure (Left (SignatureInvalid (tshow parseErr)))
    Right biscuit ->
      case extractAndCheck biscuit request of
        Left err -> pure (Left err)
        Right (grant, mRevocationId) -> do
          appRevoked <- maybe (pure False) (request ^. #revoked) mRevocationId
          if appRevoked
            then pure (Left Revoked)
            else do
              restriction <- runRestrictions biscuit request
              pure (grant <$ restriction)

-- | Pure part of verification: recover the @en_*@ facts and run every check that
-- does not need 'm'. Returns the verified grant and the optional revocation id (so
-- the caller can run the effectful revocation check).
extractAndCheck ::
  Biscuit OpenOrSealed Verified ->
  VerifyRequest m ->
  Either EnBiscuitVerifyError (VerifiedGrant, Maybe RevocationId)
extractAndCheck biscuit request = do
  subjectBindings <- queryFacts biscuit [query|en_subject($t, $i)|]
  subjectType <- single subjectBindings "t" "en_subject type"
  subjectId <- single subjectBindings "i" "en_subject id"
  let subject = SubjectId (ObjectRef (ObjectType subjectType) subjectId)

  audienceBindings <- queryFacts biscuit [query|en_audience($a)|]
  audience <- Audience <$> single audienceBindings "a" "en_audience"

  schemaBindings <- queryFacts biscuit [query|en_schema_hash($h)|]
  schemaHash <- SchemaHash <$> single schemaBindings "h" "en_schema_hash"

  tokenBindings <- queryFacts biscuit [query|en_consistency_token($c)|]
  consistencyToken <- ConsistencyToken <$> single tokenBindings "c" "en_consistency_token"

  expiryBindings <- queryFacts biscuit [query|en_expires_at($e)|]
  expiresAt <- single expiryBindings "e" "en_expires_at"

  requestIdBindings <- queryFacts biscuit [query|en_request_id($r)|]
  let requestId = RequestId <$> getSingleVariableValue requestIdBindings "r"

  revocationBindings <- queryFacts biscuit [query|en_revocation_id($r)|]
  let revocationId = RevocationId <$> getSingleVariableValue revocationBindings "r"

  (operation, scope) <- resolveScope biscuit

  assertThat ((request ^. #now) < expiresAt) Expired
  assertThat (subject == (request ^. #expectedSubject)) WrongSubject
  assertThat (audience == (request ^. #expectedAudience)) WrongAudience
  assertThat (schemaHash `Set.member` (request ^. #acceptedSchemaHashes)) UnacceptedSchemaHash
  assertThat (operation == (request ^. #operation)) OperationNotAuthorized
  assertThat (resourceInScope (request ^. #resource) scope) ResourceNotInScope

  pure
    ( VerifiedGrant
        { subject,
          audience,
          operation,
          scope,
          schemaHash,
          consistencyToken,
          expiresAt,
          requestId
        },
      revocationId
    )

-- | Determine whether the grant is an object grant or a scoped grant and recover
-- its permission and scope.
resolveScope ::
  Biscuit OpenOrSealed Verified ->
  Either EnBiscuitVerifyError (RelationName, VerifiedScope)
resolveScope biscuit = do
  objectBindings <- queryFacts biscuit [query|en_right($ot, $oid, $perm)|]
  scopedBindings <- queryFacts biscuit [query|en_scoped_right($ot, $perm)|]
  if not (Set.null objectBindings)
    then do
      objectType <- single objectBindings "ot" "en_right object_type"
      objectId <- single objectBindings "oid" "en_right object_id"
      permission <- single objectBindings "perm" "en_right permission"
      pure (RelationName permission, VerifiedObject (ObjectRef (ObjectType objectType) objectId))
    else
      if not (Set.null scopedBindings)
        then do
          permission <- single scopedBindings "perm" "en_scoped_right permission"
          containerBindings <- queryFacts biscuit [query|en_container_scope($ct, $ci)|]
          let containers =
                [ ObjectRef (ObjectType ctype) cid
                | (ctype, cid) <- containerRefs containerBindings
                ]
          pure (RelationName permission, VerifiedContainers containers)
        else Left (MalformedGrant "grant has neither en_right nor en_scoped_right")

-- | Is the requested resource within the verified scope?
resourceInScope :: ObjectRef -> VerifiedScope -> Bool
resourceInScope resource = \case
  VerifiedObject ref -> resource == ref
  VerifiedContainers refs -> resource `elem` refs

-- | Enforce any attenuation restrictions by running an authorizer that supplies
-- the request's ambient facts and a permissive @allow@. An un-attenuated token has
-- no block checks, so this always succeeds; added @check if@ blocks are enforced
-- here.
runRestrictions ::
  (MonadIO m) =>
  Biscuit OpenOrSealed Verified ->
  VerifyRequest m ->
  m (Either EnBiscuitVerifyError ())
runRestrictions biscuit request = do
  let RelationName operationText = (request ^. #operation)
      ObjectRef (ObjectType resourceType) resourceId = (request ^. #resource)
      Audience serviceText = (request ^. #serviceName)
      nowValue = (request ^. #now)
      ambient =
        [authorizer|
              operation({operationText});
              resource({resourceType}, {resourceId});
              service({serviceText});
              time({nowValue});
              allow if true;
            |]
  result <- liftIO (authorizeBiscuit biscuit ambient)
  pure $ case result of
    Left executionErr -> Left (RestrictionFailed (tshow executionErr))
    Right _ -> Right ()

-- | Narrowing restrictions to add to a token before forwarding it. 'Nothing'
-- leaves that dimension unrestricted. Every field can only narrow: it adds a
-- @check if@ that the corresponding request fact must satisfy.
data Attenuation = Attenuation
  { -- | Restrict which 'serviceName' may use the token.
    narrowedService :: Maybe Audience,
    -- | Restrict which operation the token authorizes.
    narrowedOperation :: Maybe RelationName,
    -- | Restrict the token to a single resource.
    narrowedResource :: Maybe ObjectRef,
    -- | Restrict the token to expire no later than this time.
    narrowedExpiry :: Maybe UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | An attenuation that narrows nothing; set the fields you want to restrict.
noAttenuation :: Attenuation
noAttenuation =
  Attenuation
    { narrowedService = Nothing,
      narrowedOperation = Nothing,
      narrowedResource = Nothing,
      narrowedExpiry = Nothing
    }

-- | Add a block of narrowing checks to an open, verified token. The result is a
-- strictly less-authorized token that any holder can forward; it cannot remove the
-- authority block or broaden an earlier check.
attenuateGrant ::
  (MonadIO m) =>
  Attenuation ->
  Biscuit Open Verified ->
  m (Biscuit Open Verified)
attenuateGrant attenuation biscuit =
  liftIO (addBlock (attenuationBlock attenuation) biscuit)

-- | The @check if@ block that enforces an 'Attenuation' against ambient request
-- facts.
attenuationBlock :: Attenuation -> Block
attenuationBlock attenuation =
  mconcat $
    catMaybes
      [ serviceCheck <$> (attenuation ^. #narrowedService),
        operationCheck <$> (attenuation ^. #narrowedOperation),
        resourceCheck <$> (attenuation ^. #narrowedResource),
        expiryCheck <$> (attenuation ^. #narrowedExpiry)
      ]
  where
    serviceCheck (Audience aud) = [block|check if service($s), $s == {aud};|]
    operationCheck (RelationName op) = [block|check if operation($o), $o == {op};|]
    resourceCheck (ObjectRef (ObjectType rt) rid) =
      [block|check if resource($t, $i), $t == {rt}, $i == {rid};|]
    expiryCheck expiry = [block|check if time($t), $t < {expiry};|]

-- Helpers -------------------------------------------------------------------

-- | Run a fact query, mapping a query failure to 'MalformedGrant'.
queryFacts ::
  Biscuit OpenOrSealed Verified ->
  Query ->
  Either EnBiscuitVerifyError (Set Bindings)
queryFacts biscuit q = first (MalformedGrant . T.pack) (queryRawBiscuitFacts biscuit q)

-- | Extract the single value bound to a variable (any 'FromValue' type), or fail.
single ::
  (Ord a, FromValue a) =>
  Set Bindings ->
  Text ->
  Text ->
  Either EnBiscuitVerifyError a
single bindings variable label =
  maybe (Left (MalformedGrant ("missing or ambiguous " <> label))) Right (getSingleVariableValue bindings variable)

-- | Recover @(type, id)@ pairs from an @en_container_scope@ result, preserving
-- the pairing per fact row.
containerRefs :: Set Bindings -> [(Text, Text)]
containerRefs = mapMaybe pairOf . Set.toList
  where
    pairOf row = (,) <$> (fromValue =<< Map.lookup "ct" row) <*> (fromValue =<< Map.lookup "ci" row)

assertThat :: Bool -> EnBiscuitVerifyError -> Either EnBiscuitVerifyError ()
assertThat condition err = if condition then Right () else Left err

tshow :: (Show a) => a -> Text
tshow = T.pack . show
