{-# LANGUAGE RankNTypes #-}

-- | The seam between en's effectful engine stack and servant's 'Handler'.
module En.Servant.Seam (
    AppEffects,
    Env (..),
    EnServer,
    ErrorWire (..),
    runEngine,
    enErrorToServerError,
    jsonError,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON, encode)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Servant (Handler, ServerError (..), err500, throwError)

import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Postgres.Database (Database)
import En.Reachability (ReachabilityGraph)

type AppEffects = '[ConsistencyStore, TupleStore, Error EnError, Database, IOE]

data Env es = Env
    { runPorts :: !(forall a. Eff es a -> IO (Either EnError a))
    , graph :: !ReachabilityGraph
    , maxBatchSize :: !Int
    }

type EnServer = Env AppEffects

newtype ErrorWire = ErrorWire
    { error :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

runEngine :: Env es -> Eff es a -> Handler a
runEngine Env{runPorts} action = do
    result <- liftIO (runPorts action)
    either (throwError . enErrorToServerError) pure result

enErrorToServerError :: EnError -> ServerError
enErrorToServerError =
    jsonError err500 . Text.pack . show

jsonError :: ServerError -> Text -> ServerError
jsonError err message =
    err
        { errBody = encode ErrorWire{error = message}
        , errHeaders = [("Content-Type", Text.encodeUtf8 "application/json")]
        }
