{-# LANGUAGE PackageImports #-}

-- | en's project prelude. One @import En.Prelude@ replaces the imports that
-- appear in nearly every module.
--
-- The @PackageImports@ pragma is per-file deliberately: package-qualified
-- imports exist only to disambiguate this module's re-exports, and enabling the
-- extension project-wide would encourage them elsewhere, where they add noise
-- without benefit.
--
-- NOTE: do not import @Data.Generics.Labels@ here. Its orphan @IsLabel@ instance
-- is what gives @#field@ its generic-lens meaning, and re-exporting it from the
-- prelude forces that meaning on every module in the project. Import it in each
-- module that uses @#label@ over a @Generic@ record.
module En.Prelude
  ( module X,
    module Control.Lens,
  )
where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)
