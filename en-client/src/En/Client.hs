-- | Typed Haskell client for the standalone en service.
module En.Client (
    EnClient (..),
    enClient,
    module En.Servant.API,
) where

import Prelude hiding (lookup)

import Servant.API ((:<|>) (..))
import Servant.Client (ClientM, client)

import En.Servant.API

data EnClient = EnClient
    { writeTuples :: WriteTuplesRequestWire -> ClientM WriteTuplesResponseWire
    , deleteTuples :: DeleteTuplesRequestWire -> ClientM WriteTuplesResponseWire
    , check :: CheckRequestWire -> ClientM CheckResponseWire
    , lookup :: LookupRequestWire -> ClientM LookupPageWire
    , expand :: ExpandRequestWire -> ClientM ExpandTreeWire
    }

enClient :: EnClient
enClient =
    EnClient
        { writeTuples
        , deleteTuples
        , check
        , lookup
        , expand
        }
  where
    writeTuples
        :<|> deleteTuples
        :<|> check
        :<|> lookup
        :<|> expand = client apiProxy
