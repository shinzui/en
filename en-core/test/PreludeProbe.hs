module PreludeProbe
  ( assertPreludeProbe,
  )
where

import Data.Generics.Labels ()
import En.Prelude

data Probe = Probe
  { name :: !Text,
    count :: !Int
  }
  deriving stock (Generic, Eq, Show)

assertPreludeProbe :: IO ()
assertPreludeProbe = do
  let initial = Probe "a" 1
  unless (initial ^. #name == "a") $
    fail "En.Prelude must re-export (^.) and generic-lens must resolve #name"
  unless ((initial & #count .~ 7) == Probe "a" 7) $
    fail "En.Prelude must re-export (&) and (.~), and generic-lens must resolve #count"
