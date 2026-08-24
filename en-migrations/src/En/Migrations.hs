-- | en's PostgreSQL schema, as a pg-migrate migration plan.
--
-- The SQL lives in @en-migrations\/migrations@ and is embedded into the binary at
-- compile time, so nothing reads a migrations directory at run time. The schema
-- defines:
--
--   * @relation_tuple@ -- the authorization facts, with @created_xid xid8@ and
--     @deleted_xid xid8@ (@NULL@ = live) for MVCC soft-delete.
--   * @en_transaction@ -- one row per write, carrying @xid xid8@ and
--     @snapshot pg_snapshot@ to anchor consistency tokens.
--   * @en_datastore_metadata@ -- this database's persistent identity.
--   * @en_gc_horizon@ -- the garbage-collection horizon's high-water mark.
--
-- See @docs\/spec\/0001-en-overview.md@ (Consistency).
--
-- Migrations are append-only. Add one with
-- @just make-migration name=0002-whatever@; never edit an applied file, because
-- its exact bytes are the checksum a database has already recorded, and changing
-- them makes @en-migrate verify@ fail. Apply them with
-- @cabal run en-migrate -- up@.
module En.Migrations
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    enMigrationPlan,
    enMigrations,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationPlan,
  )
import En.Migrations.Internal.Definition (enMigrations)

-- | The complete single-component migration plan for en.
--
-- The embedded manifest is validated at compile time, so a component-definition
-- failure here indicates a broken package invariant rather than an operator error.
enMigrationPlan :: Either PlanError MigrationPlan
enMigrationPlan =
  case enMigrations of
    Left definitionError ->
      error ("invalid embedded en migration component: " <> show definitionError)
    Right component -> migrationPlan (component :| [])
