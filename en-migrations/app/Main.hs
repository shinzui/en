-- | The @en-migrate@ administrative CLI.
--
-- en-server neither applies nor verifies migrations at startup: pg-migrate's
-- deployment guidance is that migrations run as an explicit deployment or
-- administrative job, not as a side effect of a service booting. This executable is
-- that job.
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
  ( ExitClass (..),
    MigrationCommand (..),
    OutputFormat (..),
    cliEnvironment,
    migrationCommandParser,
    renderMigrationCommandJson,
    renderMigrationCommandText,
    runMigrationCommand,
  )
import En.Migrations (enMigrationPlan)
import En.Prelude hiding (List)
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
  ( execParser,
    fullDesc,
    helper,
    info,
    progDesc,
    (<**>),
  )
import System.Environment (lookupEnv)
import System.Exit qualified as Exit

main :: IO ()
main = do
  plan <- either (fail . show) pure enMigrationPlan
  parsedCommand <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage en's PostgreSQL migration plan")
      )
  -- plan, list, check, and new never touch a database, so an absent
  -- DATABASE_URL must not stop them. An empty connection string is libpq's
  -- "use the defaults" (PGHOST, PGDATABASE, ...), which is exactly what the Nix
  -- development shell sets; the database-backed commands otherwise fail with
  -- hasql's own connection error rather than one invented here.
  defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
  let defaultSettings =
        Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
      environment = cliEnvironment defaultSettings plan defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  Exit.exitWith (exitCodeFor (outcome ^. #exitClass))

-- | Distinguish success, a verification report with issues, bad input, and a
-- runtime failure, so deployment automation can branch on the exit code rather than
-- parse prose.
exitCodeFor :: ExitClass -> Exit.ExitCode
exitCodeFor =
  \case
    ExitSucceeded -> Exit.ExitSuccess
    ExitVerificationFailed -> Exit.ExitFailure 2
    ExitUsageFailed -> Exit.ExitFailure 64
    ExitExecutionFailed -> Exit.ExitFailure 1

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat =
  \case
    Plan options -> options ^. #output . #outputFormat
    List options -> options ^. #output . #outputFormat
    Check options -> options ^. #output . #outputFormat
    Status options -> options ^. #output . #outputFormat
    Verify options -> options ^. #output . #outputFormat
    Up options -> options ^. #output . #outputFormat
    Repair options -> options ^. #output . #outputFormat
    New options -> options ^. #output . #outputFormat
