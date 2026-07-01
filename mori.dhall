let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "en"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Haskell relationship-based authorization (ReBAC) toolkit — schema-parametric, Zanzibar-style check/lookup with consistency tokens and caveats; standalone service or embedded library (PostgreSQL)"
      , domains = [ "Backend", "Security" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "en", github = Some "shinzui/en" } ]
    , packages =
      [ Schema.Package::{
        , name = "en-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "en-core"
        , description = Some
            "Transport-/DB-agnostic engine: schema model, Schema→reachability compiler, check/lookup/expand, revision & consistency-token types, store effect interfaces (no Servant/WAI/PostgreSQL deps)"
        }
      , Schema.Package::{
        , name = "en-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "en-migrations"
        , description = Some
            "codd-managed PostgreSQL schema migrations: relation tuples with xid8 soft-delete and the revision/transaction table"
        , dependencies = [ Schema.Dependency.ByName "en-core" ]
        }
      , Schema.Package::{
        , name = "en-postgres"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "en-postgres"
        , description = Some
            "PostgreSQL implementations of the core store effects plus the pg_snapshot revision / consistency-token machinery"
        , dependencies =
          [ Schema.Dependency.ByName "en-core"
          , Schema.Dependency.ByName "en-migrations"
          ]
        }
      , Schema.Package::{
        , name = "en-servant"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "en-servant"
        , description = Some
            "Servant API and combinators: check/lookup/expand/write endpoints and a RequirePermission/Authorize guard"
        , dependencies = [ Schema.Dependency.ByName "en-core" ]
        }
      , Schema.Package::{
        , name = "en-server"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "en-server"
        , description = Some
            "Standalone authorization service — thin application layer over the libraries"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "en-core"
          , Schema.Dependency.ByName "en-postgres"
          , Schema.Dependency.ByName "en-migrations"
          , Schema.Dependency.ByName "en-servant"
          ]
        }
      , Schema.Package::{
        , name = "en-client"
        , type = Schema.PackageType.Client
        , language = Schema.Language.Haskell
        , path = Some "en-client"
        , description = Some
            "Haskell client for the standalone en authorization service"
        , dependencies =
          [ Schema.Dependency.ByName "en-core"
          , Schema.Dependency.ByName "en-servant"
          ]
        }
      , Schema.Package::{
        , name = "en-biscuit"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "en-biscuit"
        , description = Some
            "Optional Biscuit decision-token layer: mints short-lived, attenuable Biscuit tokens from successful en decisions and verifies them locally (depends on biscuit-haskell; en-core stays token-agnostic)"
        , dependencies = [ Schema.Dependency.ByName "en-core" ]
        }
      ]
    , dependencies =
      [ "haskell-servant/servant"
      , "hasql/hasql"
      , "mzabani/codd"
      , "haskell-hvr/uuid"
      , "haskell/time"
      , "system-f/validation"
      , "eclipse-biscuit/biscuit-haskell"
      ]
    }
