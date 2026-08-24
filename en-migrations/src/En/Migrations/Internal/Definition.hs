{-# LANGUAGE TemplateHaskell #-}
{- GHC 9.12 has no Template Haskell API for registering a directory as a
dependency, so a .sql file added to or removed from en-migrations/migrations
without touching the manifest would leave this module looking up to date and
silently skip manifest-membership validation. The plugin below is a no-op Core
plugin whose recompilation policy forces GHC to reconsider this module on every
build it runs. It cannot help when no Haskell source changes at all -- cabal then
reports "Up to date" and never invokes GHC -- but a clean build revalidates. -}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module En.Migrations.Internal.Definition
  ( embeddedMigrationEntries,
    enMigrations,
  )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    migrationComponentFromEmbeddedSql,
  )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)

-- | The manifest's files and their exact bytes, embedded at compile time.
--
-- The splice validates the manifest, registers every listed @.sql@ file as a
-- compiler dependency, and fails the build if a @.sql@ file sits in
-- @en-migrations\/migrations@ without being listed -- which is the mistake people
-- actually make.
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
  $(embedMigrationManifest "migrations/manifest")

-- | en's single migration component.
--
-- The component name @en@ is durable: it forms the first half of every migration's
-- stored identity (@en\/0001-en-bootstrap@), so changing it would orphan every
-- applied row in the ledger. The empty dependency set is not an oversight -- en
-- owns the only component in its plan, so there is nothing for it to follow.
enMigrations :: Either DefinitionError MigrationComponent
enMigrations =
  migrationComponentFromEmbeddedSql "en" Set.empty embeddedMigrationEntries
