{-# LANGUAGE TypeOperators #-}

module En.Example.Host (
    DocumentView (..),
    ResolverError (..),
    GuardedAPI,
    exampleSchema,
    inMemoryTupleStore,
    consistencyStore,
    failingConsistencyStore,
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
import Data.Text qualified as Text
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

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (ConsistencyStore (..), ResolvedConsistency (..), TokenMetadata (TokenMetadata))
import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    TupleStore (..),
    UsersetQuery (..),
 )
import En.Error (EnError (..))
import En.Reachability (compile)
import En.Revision (Consistency (..), ConsistencyToken (..), DatastoreId (..), Revision (..), SchemaHash (..))
import En.Schema (CaveatParameterType (..), ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Servant.Authorize (AuthorizationEnv (..), requirePermission)
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
    Schema.buildWithCaveats
        [ Schema.caveatWith
            "needs_clearance"
            [Schema.parameter "clearance" ParameterBool]
            (Schema.cmpEq (Schema.ctxParam "clearance") (Schema.litBool True))
        ]
        [ Schema.object "user" []
        , Schema.object
            "document"
            [ Schema.relation "viewer" [Schema.subject "user"] Schema.this
            , Schema.permission "view" (Schema.computed "viewer")
            ]
        , Schema.object
            "secret"
            [ Schema.relation "reader" [Schema.subject "user"] (Schema.caveated "needs_clearance" Schema.this)
            , Schema.permission "view" (Schema.computed "reader")
            ]
        ]

mkEnv :: ConsistencyStore IO -> TupleStore IO -> AuthorizationEnv
mkEnv cStore tStore =
    AuthorizationEnv
        { consistencyStore = cStore
        , tupleStore = tStore
        , graph = either (error . show) id (compile exampleSchema)
        }

server :: AuthorizationEnv -> Subject -> Server GuardedAPI
server env subject =
    viewDocument env subject

app :: AuthorizationEnv -> Subject -> Application
app env subject =
    serve guardedApi (server env subject)

guardedApi :: Proxy GuardedAPI
guardedApi =
    Proxy

viewDocument :: AuthorizationEnv -> Subject -> Text -> Handler DocumentView
viewDocument env subject docId = do
    requirePermission env MinimizeLatency emptyContext subject (RelationName "view") (documentRef docId)
    pure (DocumentView docId)

viewSecret :: AuthorizationEnv -> Subject -> Text -> Handler DocumentView
viewSecret env subject secretId = do
    requirePermission env MinimizeLatency emptyContext subject (RelationName "view") (secretRef secretId)
    pure (DocumentView secretId)

resolveDocument :: AuthorizationEnv -> Subject -> Text -> IO (Either ResolverError DocumentView)
resolveDocument env subject docId =
    resolveWithGate env subject (documentRef docId) (DocumentView docId)

resolveSecret :: AuthorizationEnv -> Subject -> Text -> IO (Either ResolverError DocumentView)
resolveSecret env subject secretId =
    resolveWithGate env subject (secretRef secretId) (DocumentView secretId)

resolveWithGate :: AuthorizationEnv -> Subject -> ObjectRef -> DocumentView -> IO (Either ResolverError DocumentView)
resolveWithGate env subject object result =
    check env.consistencyStore env.tupleStore env.graph MinimizeLatency emptyContext subject (RelationName "view") object >>= \case
        Right Allowed -> pure (Right result)
        Right Denied -> pure (Left ResolverForbidden)
        Right (Conditional _) -> pure (Left ResolverForbidden)
        Left _ -> pure (Left ResolverForbidden)

inMemoryTupleStore :: [Tuple] -> TupleStore IO
inMemoryTupleStore tuples =
    TupleStore
        { readObjectRelation = \_ object relation limit cursor ->
            pure (pageTuples limit cursor [tuple | tuple <- tuples, tuple.object == object, tuple.relation == relation])
        , readStartingWithUser = \_ query ->
            pure
                ( pageTuples
                    query.queryLimit
                    query.queryCursor
                    [ tuple
                    | tuple <- tuples
                    , tuple.object.objectType == query.queryType
                    , tuple.relation == query.queryRelation
                    , tuple.subject `elem` query.querySubjects
                    ]
                )
        , writeTuples = \_ -> pure (ConsistencyToken "example-write")
        , deleteTuples = \_ -> pure (ConsistencyToken "example-delete")
        , headRevision = pure testRevision
        , optimizedRevision = pure testRevision
        , oldestRetainedXid = pure 0
        , reapDeletedTuples = \_ -> pure 0
        }

pageTuples :: Int -> Maybe StoreCursor -> [Tuple] -> TuplePage
pageTuples limit cursor tuples =
    let start =
            maybe 0 decodeCursor cursor
        indexed =
            drop start (zip [start + 1 ..] tuples)
        (visible, extra) =
            splitAt limit indexed
        rows =
            uncurry tupleRow <$> visible
        state =
            case extra of
                [] -> Exhausted
                _ ->
                    let cursorIndex =
                            case visible of
                                [] -> start
                                visibleRows -> fst (last visibleRows)
                     in HasMore (StoreCursor (showText cursorIndex))
     in TuplePage{rows, state}

tupleRow :: Int -> Tuple -> TupleRow
tupleRow index tuple =
    TupleRow
        { rowId = TupleRowId (showText index)
        , tuple = tuple
        , createdAt = testRevision
        , deletedAt = Nothing
        }

decodeCursor :: StoreCursor -> Int
decodeCursor (StoreCursor cursorText) =
    case reads (Text.unpack cursorText) of
        [(value, "")] -> value
        _ -> 0

consistencyStore :: ConsistencyStore IO
consistencyStore =
    ConsistencyStore
        { decodeToken = \token ->
            pure (Right (TokenMetadata token testRevision (DatastoreId "en-example") (SchemaHash "schema") Nothing))
        , validateToken = \_ -> pure (Right ())
        , resolveConsistency = \consistency ->
            pure (Right ResolvedConsistency{consistency, revision = testRevision})
        }

failingConsistencyStore :: ConsistencyStore IO
failingConsistencyStore =
    consistencyStore
        { resolveConsistency = \_ -> pure (Left (StoreError "injected"))
        }

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

showText :: (Show a) => a -> Text
showText =
    Text.pack . show
