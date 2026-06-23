module Main (main) where

import Data.List (sort)

import En.Check (CheckDecision (..), check)
import En.Conformance.Kikan
import En.Lookup (LookupLimit (..), LookupObject (..), LookupPage (..), LookupRequest (..), LookupState (..))
import En.Lookup qualified as Lookup
import En.Revision (Consistency (..))
import En.Schema (ObjectType (..), RelationName (..))
import En.Tuple (ObjectRef, Subject (..))

main :: IO ()
main = do
    let tupleStore = inMemoryTupleStore agencyTuples
    assertEqual "guest can view a shared item" (Right Allowed) =<< check consistencyStore tupleStore kikanGraph MinimizeLatency requestContext (SubjectId agencyUser) view sharedItem
    assertEqual "guest cannot view an internal item" (Right Denied) =<< check consistencyStore tupleStore kikanGraph MinimizeLatency requestContext (SubjectId agencyUser) view internalItem
    assertEqual "guest cannot act on the shared space" (Right Denied) =<< check consistencyStore tupleStore kikanGraph MinimizeLatency requestContext (SubjectId agencyUser) act guestSpace
    assertEqual "non-guest cannot view the project" (Right Denied) =<< check consistencyStore tupleStore kikanGraph MinimizeLatency requestContext (SubjectId bob) view sharedItem
    assertEqual
        "guest view reaches exactly the shared subset"
        (Right (lookupPage (allowed <$> sort [guestSpace, sharedItem]) LookupExhausted))
        =<< Lookup.lookup consistencyStore tupleStore kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) view (ObjectType "space") (LookupLimit 10))
    assertEqual
        "guest act reaches nothing"
        (Right (lookupPage [] LookupExhausted))
        =<< Lookup.lookup consistencyStore tupleStore kikanGraph MinimizeLatency (lookupRequest (SubjectId agencyUser) act (ObjectType "space") (LookupLimit 10))
  where
    view = RelationName "view"
    act = RelationName "act"

-- This is the bounded label-set a consumer applies as a predicate over its own
-- store; lookup is not enumerating high-cardinality application rows.
lookupRequest :: Subject -> RelationName -> ObjectType -> LookupLimit -> LookupRequest
lookupRequest subject permission objectType limit =
    LookupRequest{subject, permission, objectType, context = requestContext, limit, cursor = Nothing}

lookupPage :: [LookupObject] -> LookupState -> LookupPage
lookupPage objects state =
    LookupPage{objects, state}

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
