-- | The fast, database-free check that en's migration plan is well formed.
--
-- The manifest is validated when this package compiles, but component definition
-- and plan construction are ordinary values that only run when someone forces them.
-- This suite forces them, so an invalid component name, a @.sql@ file the embedder
-- accepted but the definition layer rejects, or a plan-level ordering fault fails in
-- CI before anything touches a database.
module Main (main) where

import En.Migrations (enMigrationPlan, enMigrations)
import System.Exit qualified as Exit

main :: IO ()
main = do
  case enMigrations of
    Left definitionError ->
      die ("en migration component is invalid: " <> show definitionError)
    Right _ -> pure ()
  case enMigrationPlan of
    Left planError ->
      die ("en migration plan is invalid: " <> show planError)
    Right _ -> pure ()
  putStrLn "en-migrations tests PASS"

die :: String -> IO a
die message = do
  putStrLn message
  Exit.exitFailure
