{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : En.Biscuit.Mint
-- Description : Turn successful en decisions into signed Biscuit tokens.
--
-- Minting is the bridge from an @en@ authorization /decision/ to a bearer
-- credential. The rule is the same fail-closed rule
-- 'En.Servant.Authorize.requirePermission' applies to route guards: __only an
-- 'Allowed' decision produces a token__. 'Denied', 'Conditional', engine errors,
-- and unencodable grants all return a 'Left' and never call @mkBiscuit@.
--
-- == Two layers
--
-- The __portable, required deliverable__ is the "decision → token" API
-- ('mintObjectGrant', 'mintScopedGrant'): it takes a /precomputed/
-- 'En.Decision.CheckDecision' and only performs Biscuit signing, so it stays
-- polymorphic over 'MonadIO' @m@ and never entangles the effectful engine. Host
-- applications call it from @Handler@, @ReaderT@, @Eff es@, or any @MonadIO@.
--
-- The __convenience layer__ that actually /runs/ a decision
-- ('mintCheckedObjectGrant') must live in @effectful@'s @Eff es@, because
-- 'En.Check.check' is an @Eff es@ computation constrained by
-- @(ConsistencyStore :> es, TupleStore :> es, Error EnError :> es)@. It discharges
-- the engine's @Error EnError@ locally and reports any failure as 'EngineError',
-- so its own caller does not need the @Error@ effect and no @MonadIO@-only surface
-- leaks back into @en-core@.
--
-- == Expiry
--
-- The issuer controls token lifetime. 'mintObjectGrant'/'mintScopedGrant' stamp the
-- expiry as @now + defaultTtl@ (from 'MintConfig'), overwriting whatever
-- 'En.Biscuit.Grant.EnGrant.expiresAt' the caller put in the grant, so a grant
-- builder cannot forge a long-lived token. Use the @…WithExpiry@ variants to
-- supply an explicit absolute expiry.
module En.Biscuit.Mint
  ( -- * Configuration
    MintConfig (..),

    -- * Result
    MintedGrant (..),

    -- * Errors
    EnBiscuitMintError (..),

    -- * Minting from a precomputed decision (portable, @MonadIO@)
    mintObjectGrant,
    mintObjectGrantWithExpiry,
    mintScopedGrant,
    mintScopedGrantWithExpiry,

    -- * Expiry
    resolveExpiry,

    -- * Minting by running a decision (@effectful@)
    mintCheckedObjectGrant,
  )
where

import Auth.Biscuit (SecretKey, getRevocationIds, mkBiscuitWith, serializeB64)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Time (NominalDiffTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import En.Biscuit.Grant
  ( EnBiscuitError,
    EnBiscuitGrant (..),
    EnGrant (..),
    EnScopedGrant (..),
    grantBlock,
  )
import En.Biscuit.Keys (IssuerKeyId (..))
import En.Check (check)
import En.Decision (CaveatObligation, CheckDecision (..))
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Prelude
import En.Reachability (ReachabilityGraph)
import En.Revision (Consistency)
import En.Tuple (CaveatContext)

-- | How to sign and time-box tokens. Parameterized over the monad @m@ so the
-- clock ('now') can be @IO@, @Handler@, @Eff es@, or a deterministic test clock.
-- The issuer secret key is separate from Shomei's JWT signing keys.
data MintConfig m = MintConfig
  { -- | The Biscuit issuer's private key; downstream services verify with the
    --     matching public key.
    issuerSecretKey :: SecretKey,
    -- | The identifier of 'issuerSecretKey', stamped into every minted token's
    --     Biscuit envelope so verifiers can select the matching public key from a
    --     keyset. Rotating the signing key means minting under a new id while
    --     verifiers trust both; see "En.Biscuit.Keys".
    issuerKeyId :: IssuerKeyId,
    -- | Token lifetime for the non-explicit mint functions: expiry is
    --     @now + defaultTtl@.
    defaultTtl :: NominalDiffTime,
    -- | The clock. Pass @getCurrentTime@ in production or a fixed action in
    --     tests.
    now :: m UTCTime
  }
  deriving stock (Generic)

-- | A freshly minted token and the metadata an issuer needs to track it. All
-- mint functions return this so a caller can record what it just handed out — in
-- particular the built-in block revocation ids, which are the only way to revoke a
-- token that carries no application-level @en_revocation_id@.
data MintedGrant = MintedGrant
  { -- | The URL-safe base64 serialized Biscuit ('Auth.Biscuit.serializeB64').
    token :: ByteString,
    -- | The expiry actually stamped into the token.
    expiresAt :: UTCTime,
    -- | Raw built-in revocation ids of every block ('getRevocationIds'), in
    --     block order (authority block first). Record these at mint time if you ever
    --     want to revoke the token before it expires: adding any of them to a
    --     verifier's revocation set kills the token regardless of whether it carries
    --     an application-level revocation id.
    revocationIds :: NonEmpty ByteString
  }
  deriving stock (Generic, Eq, Show)

-- | Why a grant did not produce a token. Every constructor is a non-mint.
data EnBiscuitMintError
  = -- | The decision was 'Denied'. Fail closed.
    DecisionDenied
  | -- | The decision was 'Conditional'; caveat context was not fully
    --       satisfied, so the grant is not portable. Carries the obligations for
    --       diagnostics.
    DecisionConditional [CaveatObligation]
  | -- | A decision-running helper hit an engine error; surfaced rather than
    --       minted.
    EngineError EnError
  | -- | A scoped grant carried no containers.
    EmptyLookupScope
  | -- | A scoped grant carried more containers than the configured maximum
    --       (@maximum@, @actual@). A token must not become a dump of every
    --       authorized resource.
    LookupScopeTooLarge Int Int
  | -- | The grant itself could not be encoded to facts (e.g. a non-concrete
    --       subject). Propagates the 'En.Biscuit.Grant.EnBiscuitError'.
    GrantEncodingError EnBiscuitError
  deriving stock (Eq, Show)

-- | Mint an object grant from a precomputed decision. Expiry is stamped as
-- @now + defaultTtl@. Mints only on 'Allowed'.
mintObjectGrant ::
  (MonadIO m) =>
  MintConfig m ->
  CheckDecision ->
  EnGrant ->
  m (Either EnBiscuitMintError MintedGrant)
mintObjectGrant config decision grant = do
  expiry <- resolveExpiry config
  mintObjectGrantWithExpiry config expiry decision grant

-- | 'mintObjectGrant' with an explicit absolute expiry instead of @now + defaultTtl@.
mintObjectGrantWithExpiry ::
  (MonadIO m) =>
  MintConfig m ->
  UTCTime ->
  CheckDecision ->
  EnGrant ->
  m (Either EnBiscuitMintError MintedGrant)
mintObjectGrantWithExpiry config expiry decision grant =
  case decision of
    Denied -> pure (Left DecisionDenied)
    Conditional obligations -> pure (Left (DecisionConditional obligations))
    Allowed ->
      let signedExpiry = biscuitTimestamp expiry
       in signGrant config signedExpiry (ObjectGrant (withObjectExpiry signedExpiry grant))

-- | Mint a container-scoped grant from a bounded list of containers the caller
-- already derived (e.g. from @en.lookup@). Expiry is stamped as @now + defaultTtl@.
-- Rejects an empty scope and a scope larger than @maxContainers@; a scoped token
-- must not carry the entire authorized set.
--
-- Unlike 'mintObjectGrant' there is no decision argument: the caller is responsible
-- for having established that each container is authorized. This mints the bounded
-- proof of that scope, it does not re-decide it.
mintScopedGrant ::
  (MonadIO m) =>
  MintConfig m ->
  Int ->
  EnScopedGrant ->
  m (Either EnBiscuitMintError MintedGrant)
mintScopedGrant config maxContainers grant = do
  expiry <- resolveExpiry config
  mintScopedGrantWithExpiry config expiry maxContainers grant

-- | 'mintScopedGrant' with an explicit absolute expiry instead of @now + defaultTtl@.
mintScopedGrantWithExpiry ::
  (MonadIO m) =>
  MintConfig m ->
  UTCTime ->
  Int ->
  EnScopedGrant ->
  m (Either EnBiscuitMintError MintedGrant)
mintScopedGrantWithExpiry config expiry maxContainers grant
  | n == 0 = pure (Left EmptyLookupScope)
  | n > maxContainers = pure (Left (LookupScopeTooLarge maxContainers n))
  | otherwise =
      let signedExpiry = biscuitTimestamp expiry
       in signGrant config signedExpiry (ScopedGrant (withScopedExpiry signedExpiry grant))
  where
    n = length (grant ^. #containers)

-- | The token expiry the non-explicit mint functions use: @now + defaultTtl@.
resolveExpiry :: (Monad m) => MintConfig m -> m UTCTime
resolveExpiry config = do
  t <- (config ^. #now)
  pure (addUTCTime (config ^. #defaultTtl) t)

-- Biscuit's Datalog date value is encoded at whole-second precision. Normalize
-- before building both the signed fact and 'MintedGrant', so HTTP metadata can
-- never claim fractional precision that verification cannot recover.
biscuitTimestamp :: UTCTime -> UTCTime
biscuitTimestamp = posixSecondsToUTCTime . fromInteger . floor . utcTimeToPOSIXSeconds

-- | Run @en.check@ for the grant's subject/permission/object and mint on
-- 'Allowed'. Engine errors become 'EngineError' (the token is not minted); the
-- @Error EnError@ effect is discharged here so callers need only
-- @(ConsistencyStore :> es, TupleStore :> es, IOE :> es)@.
--
-- This is the @effectful@ convenience layered on top of the portable
-- 'mintObjectGrant'; it is the only mint function that touches the engine.
mintCheckedObjectGrant ::
  (ConsistencyStore :> es, TupleStore :> es, IOE :> es) =>
  MintConfig (Eff es) ->
  ReachabilityGraph ->
  Consistency ->
  CaveatContext ->
  EnGrant ->
  Eff es (Either EnBiscuitMintError MintedGrant)
mintCheckedObjectGrant config graph consistency context grant = do
  outcome <-
    runErrorNoCallStack @EnError
      ( check
          graph
          consistency
          context
          (grant ^. #subject)
          (grant ^. #permission)
          (grant ^. #object)
      )
  case outcome of
    Left enErr -> pure (Left (EngineError enErr))
    -- 'checked.checkedAt' names the snapshot this decision was made at, and is
    -- not necessarily 'grant.consistencyToken', which the caller chose. Stamping
    -- the grant with it is the right thing and is deliberately not done here:
    -- see docs/plans/57-mint-biscuit-grants-over-http.md.
    Right checked -> mintObjectGrant config (checked ^. #decision) grant

-- | Rebuild an 'EnGrant' with a new expiry. Record /construction/ (not update)
-- so no @-Wambiguous-fields@ from the field name shared with 'EnScopedGrant'.
withObjectExpiry :: UTCTime -> EnGrant -> EnGrant
withObjectExpiry expiry g =
  EnGrant
    { subject = (g ^. #subject),
      permission = (g ^. #permission),
      object = (g ^. #object),
      consistencyToken = (g ^. #consistencyToken),
      schemaHash = (g ^. #schemaHash),
      expiresAt = expiry,
      audience = (g ^. #audience),
      requestId = (g ^. #requestId),
      revocationId = (g ^. #revocationId)
    }

-- | Rebuild an 'EnScopedGrant' with a new expiry. See 'withObjectExpiry'.
withScopedExpiry :: UTCTime -> EnScopedGrant -> EnScopedGrant
withScopedExpiry expiry g =
  EnScopedGrant
    { subject = (g ^. #subject),
      permission = (g ^. #permission),
      objectType = (g ^. #objectType),
      containers = (g ^. #containers),
      consistencyToken = (g ^. #consistencyToken),
      schemaHash = (g ^. #schemaHash),
      expiresAt = expiry,
      audience = (g ^. #audience),
      requestId = (g ^. #requestId),
      revocationId = (g ^. #revocationId)
    }

-- | Encode a grant to facts and sign them into a serialized Biscuit under the
-- config's issuer key id. The only place @mkBiscuitWith@ is called. Reports the
-- stamped @expiry@ and the freshly minted token's built-in block revocation ids in
-- the 'MintedGrant'.
signGrant ::
  (MonadIO m) =>
  MintConfig m ->
  UTCTime ->
  EnBiscuitGrant ->
  m (Either EnBiscuitMintError MintedGrant)
signGrant config expiry grant =
  case grantBlock grant of
    Left err -> pure (Left (GrantEncodingError err))
    Right blk -> do
      biscuit <- liftIO (mkBiscuitWith (Just keyId) (config ^. #issuerSecretKey) blk)
      pure
        ( Right
            MintedGrant
              { token = serializeB64 biscuit,
                expiresAt = expiry,
                revocationIds = getRevocationIds biscuit
              }
        )
  where
    IssuerKeyId keyId = (config ^. #issuerKeyId)
