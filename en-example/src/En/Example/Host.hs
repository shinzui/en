{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

module En.Example.Host (
    DocumentView (..),
    ResolverError (..),
    GuardedAPI,
    exampleSchema,
    ExampleEffects,
    runTupleStoreInMemory,
    runConsistencyStoreInMemory,
    runConsistencyStoreFailing,
    mkEnv,
    server,
    app,
    viewDocument,
    viewSecret,
    resolveDocument,
    resolveSecret,
    viewerTuple,
    secretReaderTuple,
    userRef,
    documentRef,
    secretRef,
) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Eff, IOE, runEff)
import Effectful qualified
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Servant (
    Application,
    Capture,
    Get,
    Handler,
    JSON,
    Proxy (..),
    Server,
    serve,
    type (:>),
 )

import En.Budget (defaultEvaluationBudget)
import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Conformance.Kikan qualified as Kikan
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (TokenMetadata))
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError (..))
import En.Lookup qualified as Lookup
import En.LookupSubjects qualified as LookupSubjects
import En.Reachability (compileSchema)
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (CaveatParameterType (..), ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Servant.Authorize (requirePermission)
import En.Servant.Seam (Env (..))
import En.Tuple (
    CaveatContext (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
 )

newtype DocumentView = DocumentView
    { documentId :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data ResolverError = ResolverForbidden
    deriving stock (Eq, Show)

type GuardedAPI =
    "documents" :> Capture "id" Text :> Get '[JSON] DocumentView

exampleSchema :: Schema
exampleSchema =
    either (error . ("invalid example schema fixture: " <>) . show) id $ do
        needsClearance <-
            Schema.caveatWith
                "needs_clearance"
                [Schema.parameter "clearance" ParameterBool]
                (Schema.cmpEq (Schema.ctxParam "clearance") (Schema.litBool True))
        userObject <- Schema.object "user" []
        documentObject <-
            Schema.object
                "document"
                [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
                , Schema.permission "view" (Schema.computed "viewer")
                ]
        secretObject <-
            Schema.object
                "secret"
                [ Schema.relation "reader" [Schema.subject "user"] (Schema.caveated "needs_clearance" Schema.this)
                , Schema.permission "view" (Schema.computed "reader")
                ]
        Schema.buildWithCaveats [needsClearance] [userObject, documentObject, secretObject]

type ExampleEffects = '[ConsistencyStore, TupleStore, Error EnError, IOE]

type ConsistencyInterpreter =
    forall a. Eff ExampleEffects a -> Eff '[TupleStore, Error EnError, IOE] a

type TupleInterpreter =
    forall a. Eff '[TupleStore, Error EnError, IOE] a -> Eff '[Error EnError, IOE] a

mkEnv :: ConsistencyInterpreter -> TupleInterpreter -> Env ExampleEffects
mkEnv cStore tStore =
    Env
        { runPorts = runEff . runErrorNoCallStack . tStore . cStore
        , graph = either (error . show) id (compileSchema exampleSchema)
        , checkOperation = check
        , lookupWithDeadlineOperation = Lookup.lookupWithDeadline
        , lookupSubjectsWithDeadlineOperation = LookupSubjects.lookupSubjectsWithDeadline
        , budget = defaultEvaluationBudget
        , maxBatchSize = 400
        , deadlineDefaultMillis = 3000
        , deadlineMaxMillis = 30000
        }

server :: Env ExampleEffects -> Subject -> Server GuardedAPI
server env subject =
    viewDocument env subject

app :: Env ExampleEffects -> Subject -> Application
app env subject =
    serve guardedApi (server env subject)

guardedApi :: Proxy GuardedAPI
guardedApi =
    Proxy

viewDocument :: Env ExampleEffects -> Subject -> Text -> Handler DocumentView
viewDocument env subject docId = do
    requirePermission env MinimizeLatency emptyContext subject (RelationName "view") (documentRef docId)
    pure (DocumentView docId)

viewSecret :: Env ExampleEffects -> Subject -> Text -> Handler DocumentView
viewSecret env subject secretId = do
    requirePermission env MinimizeLatency emptyContext subject (RelationName "view") (secretRef secretId)
    pure (DocumentView secretId)

resolveDocument :: Env ExampleEffects -> Subject -> Text -> IO (Either ResolverError DocumentView)
resolveDocument env subject docId =
    resolveWithGate env subject (documentRef docId) (DocumentView docId)

resolveSecret :: Env ExampleEffects -> Subject -> Text -> IO (Either ResolverError DocumentView)
resolveSecret env subject secretId =
    resolveWithGate env subject (secretRef secretId) (DocumentView secretId)

resolveWithGate :: Env ExampleEffects -> Subject -> ObjectRef -> DocumentView -> IO (Either ResolverError DocumentView)
resolveWithGate Env{runPorts, graph, checkOperation} subject object result =
    runPorts (checkOperation graph MinimizeLatency emptyContext subject (RelationName "view") object) >>= \case
        Right outcome ->
            case outcome.decision of
                Allowed -> pure (Right result)
                Denied -> pure (Left ResolverForbidden)
                Conditional _ -> pure (Left ResolverForbidden)
        Left _ -> pure (Left ResolverForbidden)

runTupleStoreInMemory :: (Error EnError Effectful.:> es) => [Tuple] -> Eff (TupleStore : es) a -> Eff es a
runTupleStoreInMemory =
    Kikan.runTupleStoreInMemory

runConsistencyStoreInMemory :: Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreInMemory =
    interpret_ \case
        DecodeToken token ->
            pure (TokenMetadata token testRevision (DatastoreId "en-example") (SchemaHash "schema") Nothing)
        ValidateToken _ ->
            pure ()
        ResolveConsistency consistency ->
            pure ResolvedConsistency{consistency, revision = testRevision}
        MintToken revision ->
            pure (ConsistencyToken ("en-example:" <> revision.revisionEncoding))

runConsistencyStoreFailing :: (Error EnError Effectful.:> es) => Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreFailing =
    interpret_ \case
        DecodeToken token ->
            pure (TokenMetadata token testRevision (DatastoreId "en-example") (SchemaHash "schema") Nothing)
        ValidateToken _ ->
            pure ()
        ResolveConsistency _ ->
            throwError (StoreError "injected")
        MintToken _ ->
            throwError (StoreError "injected")

viewerTuple :: Text -> ObjectRef -> Tuple
viewerTuple docId viewer =
    Tuple
        { object = documentRef docId
        , relation = RelationName "viewer"
        , subject = SubjectId viewer
        , caveat = Nothing
        }

secretReaderTuple :: Text -> ObjectRef -> Tuple
secretReaderTuple secretId reader =
    Tuple
        { object = secretRef secretId
        , relation = RelationName "reader"
        , subject = SubjectId reader
        , caveat = Nothing
        }

userRef :: Text -> ObjectRef
userRef userId =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = userId
        }

documentRef :: Text -> ObjectRef
documentRef docId =
    ObjectRef
        { objectType = ObjectType "document"
        , objectId = docId
        }

secretRef :: Text -> ObjectRef
secretRef secretId =
    ObjectRef
        { objectType = ObjectType "secret"
        , objectId = secretId
        }

emptyContext :: CaveatContext
emptyContext =
    CaveatContext Map.empty

testRevision :: Revision
testRevision =
    Revision "example-revision"
