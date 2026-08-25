{-# LANGUAGE TypeOperators #-}

-- | The schema HTTP slice: @GET \/v1\/schema@, the one operation that is not a @POST@. It
-- reads the server's own active model out of memory, takes no body, and cannot fault, so
-- it is a plain 'Servant.Get' rather than a @MultiVerb@. The @\/v1@ prefix is factored to
-- the umbrella in "En.Servant.API".
module En.Schema.Api
  ( -- * Routes
    SchemaRoutes (..),
    schemaRoutesServer,

    -- * Wire types
    SchemaInfoWire (..),

    -- * Handlers
    schemaHandler,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), pairs, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime)
-- 'ReachabilityGraph' is imported for its @hash@ field, not its constructor: GHC solves the
-- @HasField "hash"@ constraint behind @active.graph.hash@ only when the field is in scope.
import En.Reachability (ReachabilityGraph (..))
import En.Revision (SchemaHash (..))
import En.Servant.Seam (ActiveSchema (..), Env (..))
import GHC.Generics (Generic)
import Servant (Get, Handler, JSON, type (:>))
import Servant.API.Generic (type (:-))
import Servant.Server.Generic (AsServerT)

-- * Routes

data SchemaRoutes mode = SchemaRoutes
  { readSchema ::
      mode :- "schema" :> Get '[JSON] SchemaInfoWire
  }
  deriving stock (Generic)

schemaRoutesServer :: Env es -> SchemaRoutes (AsServerT Handler)
schemaRoutesServer env =
  SchemaRoutes {readSchema = schemaHandler env}

-- * Wire types

-- | The authorization model the server is currently serving.
--
-- @source@ is the verbatim text the operator wrote, not a rendering of the compiled model:
-- there is no @Schema -> Text@ serializer for the loadable DSL, and the text is in any case
-- what a candidate schema should be diffed against. @origin@ is the file path it was read
-- from, or @builtin-demo@ when @EN_SCHEMA_PATH@ is unset. @loadedAt@ moves on every reload
-- that swaps the model.
--
-- This response carries no @checkedAt@ (see 'En.Check.Api.CheckResponseWire'). That field names
-- the tuple store snapshot a read was evaluated at, and this is not a read of the tuple store —
-- it is server metadata, held in memory, describing no revision. @loadedAt@ is the analogous
-- freshness handle, and it answers the only question a caller can ask of it.
data SchemaInfoWire = SchemaInfoWire
  { source :: !Text,
    hash :: !Text,
    origin :: !Text,
    loadedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON SchemaInfoWire where
  toJSON wire =
    Aeson.object
      [ "source" .= wire.source,
        "hash" .= wire.hash,
        "origin" .= wire.origin,
        "loadedAt" .= wire.loadedAt
      ]
  toEncoding wire =
    pairs
      ( "source" .= wire.source
          <> "hash" .= wire.hash
          <> "origin" .= wire.origin
          <> "loadedAt" .= wire.loadedAt
      )

instance FromJSON SchemaInfoWire where
  parseJSON = withObject "SchemaInfoWire" \o ->
    SchemaInfoWire <$> o .: "source" <*> o .: "hash" <*> o .: "origin" <*> o .: "loadedAt"

-- * Handlers

-- | The model this server is serving, right now.
--
-- Not an 'En.Servant.Response.EnResult': it reads one 'ActiveSchema' out of memory and cannot
-- fail, so it has no fault to return into a response alternative. Everything on the API that
-- can fail speaks the shared problem dialect; this operation cannot.
schemaHandler :: Env es -> Handler SchemaInfoWire
schemaHandler env = do
  active <- liftIO env.readActiveSchema
  let SchemaHash hash = active.graph.hash
  pure
    SchemaInfoWire
      { source = active.source,
        hash,
        origin = active.origin,
        loadedAt = active.loadedAt
      }
