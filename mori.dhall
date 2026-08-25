let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9899d4544790da7120e8150c73e56cb53fe35191/package.dhall
        sha256:4024df757a0178e37fb0b5f04d7deb284dc3ee9bfea89a6610b793338101e284

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
            "pg-migrate-managed PostgreSQL schema migrations: relation tuples with xid8 soft-delete and the revision/transaction table"
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
      [ "haskell-servant/servant:servant"
      , "haskell-servant/servant:servant-client"
      , "haskell-servant/servant:servant-client-core"
      , "haskell-servant/servant:servant-server"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-pool"
      , "shinzui/pg-migrate:pg-migrate"
      , "shinzui/pg-migrate:pg-migrate-embed"
      , "shinzui/pg-migrate:pg-migrate-cli"
      , "haskell-hvr/uuid:uuid"
      , "haskell/time"
      , "system-f/validation"
      , "eclipse-biscuit/biscuit-haskell:biscuit-haskell"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client-core"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-server"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-pool"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-embed"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-cli"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-hvr"
        , name = "uuid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "uuid"
        }
      , Schema.MoriRef::{ namespace = "haskell", name = "time" }
      , Schema.MoriRef::{ namespace = "system-f", name = "validation" }
      , Schema.MoriRef::{
        , namespace = "eclipse-biscuit"
        , name = "biscuit-haskell"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "biscuit-haskell"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What en provides today, one concept per capability, with evidence"
        }
      ]
    }
