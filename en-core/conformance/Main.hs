{-# LANGUAGE DataKinds #-}

module Main (main) where

import Data.List (sort)
import Effectful (Eff, runPureEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Conformance.Kikan
import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Lookup (LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.Revision (Consistency (..), ConsistencyToken, DatastoreId (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef, Subject (..))

main :: IO ()
main = do
    assertEqual "guest can view a shared item" (Right Allowed) (checkDecision (SubjectId agencyUser) view sharedItem)
    assertEqual "guest cannot view an internal item" (Right Denied) (checkDecision (SubjectId agencyUser) view internalItem)
    assertEqual "guest cannot act on the shared space" (Right Denied) (checkDecision (SubjectId agencyUser) act guestSpace)
    assertEqual "non-guest cannot view the project" (Right Denied) (checkDecision (SubjectId bob) view sharedItem)
    assertEqual "a check reports the snapshot it was decided at" (Right conformanceToken) (fmap (.checkedAt) (runEngine (check kikanGraph MinimizeLatency requestContext (SubjectId agencyUser) view sharedItem)))
    assertEqual
        "guest view reaches exactly the shared subset"
        (Right (lookupPage (allowed <$> sort [guestSpace, sharedItem]) LookupExhausted))
        (runEngine (Lookup.lookup kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) view (ObjectType "space") (LookupLimit 10))))
    assertEqual
        "guest act reaches nothing"
        (Right (lookupPage [] LookupExhausted))
        (runEngine (Lookup.lookup kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) act (ObjectType "space") (LookupLimit 10))))
  where
    view = RelationName "view"
    act = RelationName "act"
    checkDecision subject permission object =
        fmap (.decision) (runEngine (check kikanGraph MinimizeLatency requestContext subject permission object))

runEngine :: Eff '[ConsistencyStore, TupleStore, Error EnError] a -> Either EnError a
runEngine =
    runPureEff . runErrorNoCallStack . runTupleStoreInMemory agencyTuples . runConsistencyStoreInMemory

{- | The token 'runConsistencyStoreInMemory' mints for the one revision it ever
resolves to. Every read under this suite reports it as its @checkedAt@.
-}
conformanceToken :: ConsistencyToken
conformanceToken =
    inMemoryToken (DatastoreId "test") testRevision

-- This is the bounded label-set a consumer applies as a predicate over its own
-- store; lookup is not enumerating high-cardinality application rows.
lookupRequest :: Subject -> RelationName -> ObjectType -> LookupLimit -> LookupRequest
lookupRequest subject permission objectType limit =
    LookupRequest{subject, permission, objectType, context = requestContext, limit, cursor = Nothing}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
    LookupPage{objects, state, checkedAt = conformanceToken}

allowed :: ObjectRef -> LookupObject
allowed object =
    LookupObject{object, decision = Allowed}

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
