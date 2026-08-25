-- | Write the OpenAPI document to @docs/api/openapi.json@.
--
-- Run from the repository root (@cabal run en-openapi@). @just openapi@ runs it and fails if
-- the checked-in file differs, so the artifact cannot drift from the route types.
--
-- Keys are sorted, so the output is byte-stable across runs and a diff is a real contract
-- change rather than a hash-order shuffle.
module Main (main) where

import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import En.Servant.OpenApi (enOpenApi)
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True "docs/api"
  BSL.writeFile "docs/api/openapi.json" (encodePretty' config enOpenApi <> "\n")
  putStrLn "wrote docs/api/openapi.json"
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare, confTrailingNewline = False}
