module Main (main) where

import Servant (Handler, ServerError (..), runHandler)

import En.Example.Host (
    DocumentView (..),
    ResolverError (..),
    mkEnv,
    resolveDocument,
    resolveSecret,
    runConsistencyStoreFailing,
    runConsistencyStoreInMemory,
    runTupleStoreInMemory,
    secretReaderTuple,
    userRef,
    viewDocument,
    viewSecret,
    viewerTuple,
 )
import En.Tuple (Subject (..))

main :: IO ()
main = do
    let alice = userRef "alice"
        bob = userRef "bob"
        tupleStore =
            runTupleStoreInMemory
                [ viewerTuple "doc1" alice
                , secretReaderTuple "s1" alice
                ]
        env = mkEnv runConsistencyStoreInMemory tupleStore
        failingEnv = mkEnv runConsistencyStoreFailing tupleStore
    assertEqual "allowed route returns success" Nothing =<< httpCodeOf (viewDocument env (SubjectId alice) "doc1")
    assertEqual "denied route returns 403" (Just 403) =<< httpCodeOf (viewDocument env (SubjectId bob) "doc1")
    assertEqual "conditional route returns 403" (Just 403) =<< httpCodeOf (viewSecret env (SubjectId alice) "s1")
    assertEqual "store error route returns 503" (Just 503) =<< httpCodeOf (viewDocument failingEnv (SubjectId alice) "doc1")
    assertEqual "allowed resolver returns object" (Right (DocumentView "doc1")) =<< resolveDocument env (SubjectId alice) "doc1"
    assertEqual "denied resolver fails closed" (Left ResolverForbidden) =<< resolveDocument env (SubjectId bob) "doc1"
    assertEqual "conditional resolver fails closed" (Left ResolverForbidden) =<< resolveSecret env (SubjectId alice) "s1"
    assertEqual "engine error resolver fails closed" (Left ResolverForbidden) =<< resolveDocument failingEnv (SubjectId alice) "doc1"

httpCodeOf :: Handler a -> IO (Maybe Int)
httpCodeOf handler =
    either (Just . errHTTPCode) (const Nothing) <$> runHandler handler

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
