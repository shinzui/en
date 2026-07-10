{-# LANGUAGE TypeOperators #-}

{- | The en HTTP API, assembled from its vertical slices.

Each concept owns its own slice — routes, wire DTOs, and handlers together — under a
concept-first module path: "En.Tuple.Api", "En.Check.Api", "En.Lookup.Api",
"En.Expand.Api", and "En.Schema.Api". Vocabulary shared by two or more slices lives in
"En.Servant.Wire", and the @MultiVerb@ response machinery in "En.Servant.Response". This
module is the umbrella: it mounts the slice route records into one 'EnApi' record, builds
the server and the WAI 'Application', installs the error-envelope hook, and re-exports every
name it exported before the split, so external consumers (@nagare@, @kikan-en@) that import
@En.Servant.API@ see an unchanged interface.
-}
module En.Servant.API (
    -- * The API
    EnAPI,
    EnApi (..),
    apiProxy,
    EnServer,
    server,
    app,
    envelopeFormatters,

    -- * Re-exported seam
    ActiveSchema (..),
    Env (..),

    -- * Re-exported response machinery
    EnResponses,
    EnResult (..),

    -- * Re-exported wire vocabulary and slices
    module En.Servant.Wire,
    module En.Tuple.Api,
    module En.Check.Api,
    module En.Lookup.Api,
    module En.Expand.Api,
    module En.Schema.Api,
) where

import Data.Text qualified as Text
import Effectful (IOE)
import Effectful qualified
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Servant (
    Application,
    Context (..),
    Proxy (..),
    Server,
    serveWithContext,
    type (:>),
 )
import Servant.API (NamedRoutes)
import Servant.API.Generic (type (:-))
import Servant.Server (ErrorFormatter, ErrorFormatters (..), defaultErrorFormatters)

import En.Check.Api
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Expand.Api
import En.Lookup.Api
import En.Schema.Api
import En.Servant.Response (EnResponses, EnResult (..))
import En.Servant.Seam (
    ActiveSchema (..),
    EnServer,
    Env (..),
    badRequest,
    faultToServerError,
 )
import En.Servant.Seam qualified as Seam
import En.Servant.Wire
import En.Tuple.Api

{- | The en HTTP API as a servant @NamedRoutes@ record. Each field mounts one concept's
route record under the shared @\/v1@ prefix; the concept owns its routes in its own slice
module.

The wire contract is versioned by path. @\/v1@ is current; a future breaking change ships
as @\/v2@ served alongside it, rather than mutating these operations.

Notable shapes carried by the slices: tuple deletion is a @POST@ to
@\/v1\/relationships\/delete@, not a @DELETE@ carrying a body (HTTP intermediaries may drop
a @DELETE@ body, and a @405@ — which servant raises outside 'ErrorFormatters' — does not
consume the request body). @GET \/v1\/schema@ is the one non-@POST@: it reads the server's
configuration from memory and cannot fail. @POST \/v1\/grants@ is a @POST@ but, like schema,
not a @MultiVerb@: its non-200 statuses are a different set from the shared 'EnResponses',
so its handler throws 'Servant.ServerError' carrying the same 'ErrorEnvelopeWire'.
-}
data EnApi mode = EnApi
    { relationships :: mode :- "v1" :> NamedRoutes TupleRoutes
    , checks :: mode :- "v1" :> NamedRoutes CheckRoutes
    , lookups :: mode :- "v1" :> NamedRoutes LookupRoutes
    , expands :: mode :- "v1" :> NamedRoutes ExpandRoutes
    , schema :: mode :- "v1" :> NamedRoutes SchemaRoutes
    }
    deriving stock (Generic)

{- | Kept as a synonym so the internal references to @EnAPI@ (and @apiProxy@'s type) read
naturally. @Server (NamedRoutes EnApi)@ is @EnApi (AsServerT Handler)@.
-}
type EnAPI = NamedRoutes EnApi

apiProxy :: Proxy EnAPI
apiProxy = Proxy

server :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) => Env es -> Server EnAPI
server env =
    EnApi
        { relationships = tupleRoutesServer env
        , checks = checkRoutesServer env
        , lookups = lookupRoutesServer env
        , expands = expandRoutesServer env
        , schema = schemaRoutesServer env
        }

app :: (ConsistencyStore Effectful.:> es, TupleStore Effectful.:> es, Error EnError Effectful.:> es, IOE Effectful.:> es) => Env es -> Application
app env =
    serveWithContext apiProxy (envelopeFormatters :. EmptyContext) (server env)

{- | Make Servant's own errors speak the same envelope as en's.

A request that fails to parse, or that matches no route, is rejected before any
handler runs, so it cannot be a 'MultiVerb' response alternative. Without this the
caller would get Servant's plain-text body and an inconsistent error content type.

Not covered: @405 Method Not Allowed@ and @415 Unsupported Media Type@, which Servant
raises outside 'ErrorFormatters'. Both currently return an empty body. A 405 is what
@DELETE \/v1\/relationships@ now yields, and it notably does not consume the request
body — which is the reason deletion moved to @POST@.
-}
envelopeFormatters :: ErrorFormatters
envelopeFormatters =
    defaultErrorFormatters
        { bodyParserErrorFormatter = malformedBody
        , urlParseErrorFormatter = malformedBody
        , notFoundErrorFormatter = const Seam.notFound
        }
  where
    malformedBody :: ErrorFormatter
    malformedBody _typeRep _request detail =
        faultToServerError (badRequest "malformed_request_body" (Text.pack detail))
