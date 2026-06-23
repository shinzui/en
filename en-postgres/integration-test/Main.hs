{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)

import En.Check (CheckDecision (..), check)
import En.Effect.ConsistencyStore (TokenMetadata (..))
import En.Effect.TupleStore (PageState (..), TuplePage (..), TupleStore (..), UsersetQuery (..))
import En.Postgres.Revision (ConsistencyConfig (..), postgresConsistencyStore, tokenMetadataFromPayload)
import En.Postgres.TupleStore (postgresTupleStoreIO)
import En.Reachability (compile)
import En.Revision (Consistency (..), DatastoreId (..))
import En.Schema (AllowedSubject (..), ObjectType (..), Relation (..), RelationName (..), Rewrite (..), Schema (..))
import En.Schema qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Session qualified as Session

main :: IO ()
main = do
    result <- Pg.with \database -> do
        connection <- acquire database
        resetSchema connection
        runTupleStoreScenario connection
        Connection.release connection
    case result of
        Left err -> fail ("ephemeral-pg failed to start: " <> Text.unpack (Pg.renderStartError err))
        Right () -> pure ()

acquire :: Pg.Database -> IO Connection.Connection
acquire database =
    Connection.acquire (Pg.connectionSettings database) >>= \case
        Right connection -> pure connection
        Left err -> fail ("Could not connect to PostgreSQL: " <> show err)

resetSchema :: Connection.Connection -> IO ()
resetSchema connection =
    Connection.use connection (Session.script schemaSql) >>= \case
        Right () -> pure ()
        Left err -> fail ("Could not reset schema: " <> show err)

runTupleStoreScenario :: Connection.Connection -> IO ()
runTupleStoreScenario connection = do
    let config =
            ConsistencyConfig
                { datastoreId = DatastoreId "test-datastore"
                , schemaHash = Schema.schemaHash checkSchema
                }
        store = postgresTupleStoreIO connection config
        consistencyStore =
            postgresConsistencyStore config (pure testTime) store.optimizedRevision store.headRevision
        tuple =
            Tuple
                { object = ObjectRef (ObjectType "space") "project-x"
                , relation = RelationName "viewer"
                , subject = SubjectId (ObjectRef (ObjectType "user") "alice")
                , caveat = Nothing
                }
        query =
            UsersetQuery
                { queryType = ObjectType "space"
                , queryRelation = RelationName "viewer"
                , querySubjects = [SubjectId (ObjectRef (ObjectType "user") "alice")]
                , queryLimit = 10
                , queryCursor = Nothing
                }
    writeToken <- store.writeTuples [tuple]
    TokenMetadata{revision = writeRevision} <- either (fail . show) pure (tokenMetadataFromPayload writeToken)
    TuplePage{rows = rowsAtWrite, state = stateAtWrite} <- store.readStartingWithUser writeRevision query
    assertEqual "write token read sees tuple count" 1 (length rowsAtWrite)
    assertEqual "write token read is exhausted" Exhausted stateAtWrite
    graph <- either (fail . show) pure (compile checkSchema)
    checkDecision <- check consistencyStore store graph (AtLeastAsFresh writeToken) (CaveatContext Map.empty) tuple.subject (RelationName "view") tuple.object
    assertEqual "postgres-backed check sees written tuple" (Right Allowed) checkDecision
    deleteToken <- store.deleteTuples [tuple]
    TokenMetadata{revision = deleteRevision} <- either (fail . show) pure (tokenMetadataFromPayload deleteToken)
    TuplePage{rows = rowsAtOldRevision} <- store.readStartingWithUser writeRevision query
    TuplePage{rows = rowsAtDelete} <- store.readStartingWithUser deleteRevision query
    assertEqual "old revision still sees deleted tuple" 1 (length rowsAtOldRevision)
    assertEqual "delete revision hides tuple" 0 (length rowsAtDelete)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
    | expected == actual = pure ()
    | otherwise =
        fail $
            label
                <> "\nexpected: "
                <> show expected
                <> "\nactual:   "
                <> show actual

checkSchema :: Schema
checkSchema =
    Schema
        { objectTypes =
            Map.fromList
                [ (ObjectType "user", Map.empty)
                ,
                    ( ObjectType "space"
                    , Map.fromList
                        [ relationEntry "viewer" userSubject This
                        , relationEntry "view" Set.empty (ComputedUserset (RelationName "viewer"))
                        ]
                    )
                ]
        , caveats = Map.empty
        }

relationEntry :: Text -> Set.Set AllowedSubject -> Rewrite -> (RelationName, Relation)
relationEntry name allowedSubjects rewrite =
    ( RelationName name
    , Relation
        { relationName = RelationName name
        , allowedSubjects = allowedSubjects
        , rewrite = rewrite
        }
    )

userSubject :: Set.Set AllowedSubject
userSubject =
    Set.singleton AllowedSubject{objectType = ObjectType "user", relation = Nothing}

testTime :: UTCTime
testTime =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" "2026-06-23T00:00:00Z"

schemaSql :: Text
schemaSql =
    """
    DROP TABLE IF EXISTS relation_tuple;
    DROP TABLE IF EXISTS en_transaction;

    CREATE TABLE en_transaction
      ( xid xid8 PRIMARY KEY
      , snapshot pg_snapshot NOT NULL DEFAULT pg_current_snapshot()
      , schema_hash text NOT NULL
      , created_at timestamptz NOT NULL DEFAULT now()
      );

    CREATE TABLE relation_tuple
      ( id bigserial PRIMARY KEY
      , object_type text NOT NULL
      , object_id text NOT NULL
      , relation text NOT NULL
      , subject_type text NOT NULL
      , subject_id text NOT NULL
      , subject_relation text NULL
      , caveat_name text NULL
      , caveat_payload jsonb NULL
      , created_xid xid8 NOT NULL
      , deleted_xid xid8 NULL
      , CHECK ((subject_relation IS NULL) OR (subject_relation <> ''))
      );

    CREATE UNIQUE INDEX relation_tuple_live_unique
      ON relation_tuple
        (object_type, object_id, relation, subject_type, subject_id, coalesce(subject_relation, ''), coalesce(caveat_name, ''))
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_object_live_idx
      ON relation_tuple (object_type, object_id, relation, id)
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_subject_live_idx
      ON relation_tuple
        (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id)
      WHERE deleted_xid IS NULL;

    CREATE INDEX relation_tuple_created_xid_idx
      ON relation_tuple (created_xid);

    CREATE INDEX relation_tuple_deleted_xid_idx
      ON relation_tuple (deleted_xid)
      WHERE deleted_xid IS NOT NULL;
    """
