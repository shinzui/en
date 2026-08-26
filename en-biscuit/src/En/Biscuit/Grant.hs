{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : En.Biscuit.Grant
-- Description : Typed en authorization grants and their stable Biscuit vocabulary.
--
-- An /en grant/ is the bounded, serializable proof of a single successful @en@
-- decision: "this subject may perform this permission on this object" (an
-- 'EnGrant'), or "this subject may perform this permission on objects inside these
-- containers" (an 'EnScopedGrant'). This module owns two things that every later
-- plan consumes:
--
--   1. The typed grant model, built directly from @en-core@ vocabulary
--      ('En.Tuple.Subject', 'En.Tuple.ObjectRef', 'En.Schema.RelationName',
--      'En.Schema.ObjectType', 'En.Revision.ConsistencyToken',
--      'En.Revision.SchemaHash') plus a few token-local newtypes.
--
--   2. The __stable Biscuit Datalog fact vocabulary__ the grant serializes to.
--      ExecPlan 30 (minting) emits exactly these predicates and ExecPlan 31
--      (verification) consumes them, so the names and arities here are a contract.
--
-- == Stable predicate vocabulary
--
--   * @en_subject($type, $id)@                    — the granted subject (concrete id only)
--   * @en_right($object_type, $object_id, $permission)@ — an object grant
--   * @en_scoped_right($object_type, $permission)@      — a container-scoped grant
--   * @en_container_scope($container_type, $container_id)@ — one per scoped container
--   * @en_schema_hash($hash)@
--   * @en_consistency_token($token)@
--   * @en_audience($audience)@
--   * @en_expires_at($timestamp)@
--   * @en_request_id($request_id)@                — only when present
--   * @en_revocation_id($revocation_id)@          — only when present
--
-- @en_subject_wildcard()@ is intentionally __not__ emitted: 'En.Tuple.Subject' has
-- a 'SubjectWildcard' constructor, but wildcard grants are deferred. A
-- 'SubjectWildcard' or 'SubjectSet' subject therefore fails closed with
-- 'UnsupportedSubject' rather than silently widening authorization.
--
-- == Injection safety
--
-- Facts are never assembled by string concatenation. Each fact is built through
-- the @biscuit-haskell@ @[block| ... |]@ quasiquoter with @{haskellVariable}@
-- antiquotation, so every dynamic value becomes a single typed Datalog term via
-- @ToTerm@. A subject id containing quotes, commas, or semicolons cannot break out
-- into an extra fact — it stays one string term. 'grantFactsText' renders the same
-- 'Block' the grant mints, so tests observe exactly what would be signed.
module En.Biscuit.Grant
  ( -- * Token-local newtypes
    Audience (..),
    RequestId (..),
    RevocationId (..),

    -- * Grants
    EnGrant (..),
    EnScopedGrant (..),
    EnBiscuitGrant (..),

    -- * Errors
    EnBiscuitError (..),

    -- * Rendering
    grantBlock,
    grantFactsText,
  )
where

import Auth.Biscuit (Block, block)
import Auth.Biscuit.Datalog.AST (renderBlock)
import Data.Generics.Labels ()
import En.Prelude
import En.Revision (ConsistencyToken (..), SchemaHash (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef (..), Subject (..))

-- | The service (or set of services) a grant is intended for. Verifiers reject a
-- token whose 'Audience' does not match their own.
newtype Audience = Audience Text
  deriving stock (Generic, Eq, Ord, Show)

-- | An optional correlation id tying a grant back to the request that produced
-- the @en@ decision.
newtype RequestId = RequestId Text
  deriving stock (Generic, Eq, Ord, Show)

-- | An optional revocation id, so a verifier can reject a specific token even
-- before its expiry (via a revocation list).
newtype RevocationId = RevocationId Text
  deriving stock (Generic, Eq, Ord, Show)

-- | A grant for a single concrete object: @subject@ may perform @permission@ on
-- @object@. This is the Biscuit counterpart of a successful @en.check@.
data EnGrant = EnGrant
  { subject :: Subject,
    permission :: RelationName,
    object :: ObjectRef,
    consistencyToken :: ConsistencyToken,
    schemaHash :: SchemaHash,
    expiresAt :: UTCTime,
    audience :: Audience,
    requestId :: Maybe RequestId,
    revocationId :: Maybe RevocationId
  }
  deriving stock (Generic, Eq, Show)

-- | A grant scoped to a set of containers: @subject@ may perform @permission@ on
-- objects of @objectType@ that live inside any of @containers@. This is the
-- Biscuit counterpart of a bounded @en.lookup@-style result — it does not copy the
-- relationship graph, only the container boundary the decision was made under.
data EnScopedGrant = EnScopedGrant
  { subject :: Subject,
    permission :: RelationName,
    objectType :: ObjectType,
    containers :: [ObjectRef],
    consistencyToken :: ConsistencyToken,
    schemaHash :: SchemaHash,
    expiresAt :: UTCTime,
    audience :: Audience,
    requestId :: Maybe RequestId,
    revocationId :: Maybe RevocationId
  }
  deriving stock (Generic, Eq, Show)

-- | Either kind of grant. Minting and verification are defined over this sum.
data EnBiscuitGrant
  = ObjectGrant EnGrant
  | ScopedGrant EnScopedGrant
  deriving stock (Eq, Show)

-- | Why a grant could not be turned into Biscuit facts.
data EnBiscuitError
  = -- | The subject is a userset ('SubjectSet') or wildcard
    --       ('SubjectWildcard'); only concrete 'SubjectId' subjects are encodable
    --       in this vocabulary. Fails closed rather than widening authorization.
    UnsupportedSubject Subject
  deriving stock (Eq, Show)

-- | Render a grant to the 'Block' of Biscuit facts that represents it. This is
-- the single source of truth for the fact vocabulary; minting appends this block
-- to a token and verification checks these facts.
--
-- Returns 'Left' 'UnsupportedSubject' for non-concrete subjects.
grantBlock :: EnBiscuitGrant -> Either EnBiscuitError Block
grantBlock (ObjectGrant g) = do
  subjectB <- subjectFact (g ^. #subject)
  let RelationName perm = (g ^. #permission)
      (objType, objId) = objectRefParts (g ^. #object)
      rightB = [block|en_right({objType}, {objId}, {perm});|]
  pure $
    mconcat
      [ subjectB,
        rightB,
        metaFacts
          (g ^. #consistencyToken)
          (g ^. #schemaHash)
          (g ^. #expiresAt)
          (g ^. #audience)
          (g ^. #requestId)
          (g ^. #revocationId)
      ]
grantBlock (ScopedGrant g) = do
  subjectB <- subjectFact (g ^. #subject)
  let RelationName perm = (g ^. #permission)
      ObjectType objType = (g ^. #objectType)
      scopedRightB = [block|en_scoped_right({objType}, {perm});|]
      containerB = mconcat (containerFact <$> (g ^. #containers))
  pure $
    mconcat
      [ subjectB,
        scopedRightB,
        containerB,
        metaFacts
          (g ^. #consistencyToken)
          (g ^. #schemaHash)
          (g ^. #expiresAt)
          (g ^. #audience)
          (g ^. #requestId)
          (g ^. #revocationId)
      ]

-- | Render a grant to its Datalog fact text, exactly as it appears in the signed
-- block. Intended for tests and debugging; minting uses 'grantBlock' directly.
grantFactsText :: EnBiscuitGrant -> Either EnBiscuitError Text
grantFactsText = fmap renderBlock . grantBlock

-- | @en_subject($type, $id)@ for a concrete subject; fail closed otherwise.
subjectFact :: Subject -> Either EnBiscuitError Block
subjectFact (SubjectId ref) =
  let (subjType, subjId) = objectRefParts ref
   in Right [block|en_subject({subjType}, {subjId});|]
subjectFact s = Left (UnsupportedSubject s)

-- | @en_container_scope($container_type, $container_id)@ for one container.
containerFact :: ObjectRef -> Block
containerFact ref =
  let (ctype, cid) = objectRefParts ref
   in [block|en_container_scope({ctype}, {cid});|]

-- | The metadata facts common to both grant shapes.
metaFacts ::
  ConsistencyToken ->
  SchemaHash ->
  UTCTime ->
  Audience ->
  Maybe RequestId ->
  Maybe RevocationId ->
  Block
metaFacts (ConsistencyToken ct) (SchemaHash sh) expiresAt (Audience aud) mReq mRev =
  mconcat $
    [ [block|en_consistency_token({ct});|],
      [block|en_schema_hash({sh});|],
      [block|en_expires_at({expiresAt});|],
      [block|en_audience({aud});|]
    ]
      <> foldMap (\(RequestId r) -> [[block|en_request_id({r});|]]) mReq
      <> foldMap (\(RevocationId r) -> [[block|en_revocation_id({r});|]]) mRev

-- | Split an 'ObjectRef' into its @(type, id)@ 'Text' components.
objectRefParts :: ObjectRef -> (Text, Text)
objectRefParts (ObjectRef (ObjectType t) i) = (t, i)
