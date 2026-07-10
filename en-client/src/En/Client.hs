{- | Typed Haskell client for the standalone en service.

The operations live under the @\/v1@ path prefix, which is carried in the API type
rather than in the 'Servant.Client.BaseUrl'. Point the 'Servant.Client.ClientEnv' at
the host root (e.g. @http:\/\/localhost:8080@) and the client appends @\/v1@ itself.

Every operation answers with an 'EnResult'. Engine and validation failures arrive as
'EnClientError', 'EnUnprocessable', or 'EnUnavailable' — values to pattern-match, each
carrying an 'En.Servant.Seam.ErrorEnvelopeWire' whose @code@ is stable and whose
@retryable@ says whether retrying can help. They are /not/ raised as
'Servant.Client.ClientError'; that is reserved for transport failures and for errors
raised before a handler runs (an unmatched route, a malformed body, a rejected API
key), which are not part of the API type.

@
result <- runClientM (enClient.check request) clientEnv
case result of
    Left transportError -> …
    Right (EnOk response) -> …
    Right (EnUnavailable envelope) | envelope.retryable -> retryLater
    Right (EnClientError envelope) -> reportBug envelope.code
    …
@
-}
module En.Client (
    EnClient (..),
    enClient,
    chainFrom,
    module En.Servant.API,
) where

import Prelude hiding (lookup)

import Data.Text (Text)
import Servant.Client (ClientM)
import Servant.Client.Generic (AsClientT, genericClient)

import En.Servant.API

data EnClient = EnClient
    { writeTuples :: WriteTuplesRequestWire -> ClientM (EnResult WriteTuplesResponseWire)
    , deleteTuples :: DeleteTuplesRequestWire -> ClientM (EnResult WriteTuplesResponseWire)
    , readRelationships :: ReadRelationshipsRequestWire -> ClientM (EnResult ReadRelationshipsResponseWire)
    , deleteRelationships :: DeleteRelationshipsRequestWire -> ClientM (EnResult DeleteRelationshipsResponseWire)
    , check :: CheckRequestWire -> ClientM (EnResult CheckResponseWire)
    , batchCheck :: BatchCheckRequestWire -> ClientM (EnResult BatchCheckResponseWire)
    , lookup :: LookupRequestWire -> ClientM (EnResult LookupPageWire)
    , lookupSubjects :: LookupSubjectsRequestWire -> ClientM (EnResult LookupSubjectsPageWire)
    , expand :: ExpandRequestWire -> ClientM (EnResult ExpandTreeWire)
    , watch :: WatchRequestWire -> ClientM (EnResult WatchResponseWire)
    , mintGrant :: MintGrantRequestWire -> ClientM MintGrantResponseWire
    {- ^ Not an 'EnResult': @POST \/v1\/grants@ throws its non-200 outcomes (404 when minting
    is disabled, 403 when the decision is not Allowed, 400 on a bad request) as client
    errors rather than returning them, so 'runClientM' surfaces them as 'Left'.
    -}
    , readSchema :: ClientM SchemaInfoWire
    -- ^ Not an 'EnResult': @GET \/v1\/schema@ has no failure alternative to return into.
    }

{- | Built from servant's 'genericClient', which derives one client function per field of
the 'En.Servant.API.EnApi' record. Association is by field name, so adding a route to the
record cannot silently rebind the others — the fragility the positional @:\<|\>@
destructuring this replaced was subject to. The @:: EnApi (AsClientT ClientM)@ annotation
fixes the client monad to 'ClientM'.
-}
enClient :: EnClient
enClient =
    EnClient
        { writeTuples
        , deleteTuples
        , readRelationships
        , deleteRelationships
        , check
        , batchCheck
        , lookup
        , lookupSubjects
        , expand
        , watch
        , mintGrant
        , readSchema
        }
  where
    EnApi
        { writeTuples
        , deleteTuples
        , readRelationships
        , deleteRelationships
        , check
        , batchCheck
        , lookup
        , lookupSubjects
        , expand
        , watch
        , mintGrant
        , readSchema
        } = genericClient :: EnApi (AsClientT ClientM)

{- | Ask for a read at least as fresh as a previous response's @checkedAt@.

Every read response carries the token it was evaluated at. Feeding that token to
the next read chains the two: the second observes everything the first observed.

@
EnOk decided <- runClientM (enClient.check request) clientEnv
EnOk page <- runClientM (enClient.lookup followUp{consistency = chainFrom decided.checkedAt}) clientEnv
@
-}
chainFrom :: Text -> ConsistencyWire
chainFrom =
    AtLeastAsFreshWire
