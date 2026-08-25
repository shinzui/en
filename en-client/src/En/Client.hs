-- | Typed Haskell client for the standalone en service.
--
-- The operations live under the @\/v1@ path prefix, which is carried in the API type
-- rather than in the 'Servant.Client.BaseUrl'. Point the 'Servant.Client.ClientEnv' at
-- the host root (e.g. @http:\/\/localhost:8080@) and the client appends @\/v1@ itself.
--
-- Every operation answers with an 'EnResult'. Engine and validation failures arrive as
-- 'EnClientError', 'EnUnprocessable', 'EnInternal', or 'EnUnavailable' — values to pattern-match, each
-- carrying an 'En.Servant.Problem.ProblemDetails' whose @code@ is stable and whose
-- @retryable@ says whether retrying can help. They are /not/ raised as
-- 'Servant.Client.ClientError'; that is reserved for transport failures and for errors
-- raised before a handler runs (an unmatched route, a malformed body, a rejected API
-- key), which are not part of the API type.
--
-- @
-- result <- runClientM (enClient.check request) clientEnv
-- case result of
--     Left transportError -> …
--     Right (EnOk response) -> …
--     Right (EnUnavailable envelope) | envelope.retryable -> retryLater
--     Right (EnClientError envelope) -> reportBug envelope.code
--     …
-- @
module En.Client
  ( EnClient (..),
    enClient,
    chainFrom,
    module En.Servant.API,
  )
where

import Data.Text (Text)
import En.Servant.API
import Servant.Client (ClientM)
import Servant.Client.Generic (AsClientT, genericClient)
import Prelude hiding (lookup)

data EnClient = EnClient
  { writeTuples :: WriteTuplesRequestWire -> ClientM (EnResult WriteTuplesResponseWire),
    deleteTuples :: DeleteTuplesRequestWire -> ClientM (EnResult WriteTuplesResponseWire),
    readRelationships :: ReadRelationshipsRequestWire -> ClientM (EnResult ReadRelationshipsResponseWire),
    deleteRelationships :: DeleteRelationshipsRequestWire -> ClientM (EnResult DeleteRelationshipsResponseWire),
    check :: CheckRequestWire -> ClientM (EnResult CheckResponseWire),
    batchCheck :: BatchCheckRequestWire -> ClientM (EnResult BatchCheckResponseWire),
    lookup :: LookupRequestWire -> ClientM (EnResult LookupPageWire),
    lookupSubjects :: LookupSubjectsRequestWire -> ClientM (EnResult LookupSubjectsPageWire),
    expand :: ExpandRequestWire -> ClientM (EnResult ExpandTreeWire),
    watch :: WatchRequestWire -> ClientM (EnResult WatchResponseWire),
    -- | Grant-specific outcomes are typed values: the shared error tail plus 403 when
    --     the decision is not Allowed and 404 when minting is disabled.
    mintGrant :: MintGrantRequestWire -> ClientM MintGrantResult,
    -- | Not an 'EnResult': @GET \/v1\/schema@ has no failure alternative to return into.
    readSchema :: ClientM SchemaInfoWire
  }

-- | Built from servant's 'genericClient', which derives one client function per field of
-- the 'En.Servant.API.EnApi' record. Association is by field name, so adding a route to the
-- record cannot silently rebind the others — the fragility the positional @:\<|\>@
-- destructuring this replaced was subject to. The @:: EnApi (AsClientT ClientM)@ annotation
-- fixes the client monad to 'ClientM'.
--
-- 'EnApi' mounts one sub-record per concept slice, so the derived client is nested: the
-- umbrella yields the five slice clients, and each slice client yields its operations. This
-- flat 'EnClient' is projected from them, one field at a time, so callers keep the flat
-- @client.check@ surface.
enClient :: EnClient
enClient =
  EnClient
    { writeTuples,
      deleteTuples,
      readRelationships,
      deleteRelationships,
      check,
      batchCheck,
      lookup,
      lookupSubjects,
      expand,
      watch,
      mintGrant,
      readSchema
    }
  where
    EnApi {relationships, checks, lookups, expands, schema} = genericClient :: EnApi (AsClientT ClientM)
    TupleRoutes {writeTuples, deleteTuples, readRelationships, deleteRelationships, watch} = relationships
    CheckRoutes {check, batchCheck, mintGrant} = checks
    LookupRoutes {lookup, lookupSubjects} = lookups
    ExpandRoutes {expand} = expands
    SchemaRoutes {readSchema} = schema

-- | Ask for a read at least as fresh as a previous response's @checkedAt@.
--
-- Every read response carries the token it was evaluated at. Feeding that token to
-- the next read chains the two: the second observes everything the first observed.
--
-- @
-- EnOk decided <- runClientM (enClient.check request) clientEnv
-- EnOk page <- runClientM (enClient.lookup followUp{consistency = chainFrom decided.checkedAt}) clientEnv
-- @
chainFrom :: Text -> ConsistencyWire
chainFrom =
  AtLeastAsFreshWire
