module Main (
    main,
) where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)

import En.Check (CaveatObligation (..), CheckDecision (..))
import En.Effect.TupleStore (
    PageState (..),
    StoreCursor (..),
    TuplePage (..),
    TupleRow (..),
    TupleRowId (..),
    UsersetQuery (..),
 )
import En.Expand (ExpandLimit (..), ExpandRequest (..), ExpandState (..), ExpandTree (..))
import En.Lookup (
    LookupCursor (..),
    LookupLimit (..),
    LookupPage (..),
    LookupRequest (..),
    LookupState (..),
 )
import En.Revision (Revision (..))
import En.Schema (
    CaveatDefinition (..),
    CaveatName (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    ObjectType (..),
    RelationName (..),
 )
import En.Tuple (
    CaveatContext (..),
    CaveatPayload (..),
    CaveatValue (..),
    ObjectRef (..),
    Subject (..),
    Tuple (..),
    TupleCaveat (..),
 )

main :: IO ()
main = do
    let _ = sampleTuple
        _ = sampleUsersetQuery
        _ = sampleTuplePage
        _ = sampleDecision
        _ = sampleLookupRequest
        _ = sampleLookupPage
        _ = sampleExpandRequest
        _ = sampleExpandTree
        _ = sampleCaveatDefinition
    pure ()

sampleTuple :: Tuple
sampleTuple =
    Tuple
        { object = intention
        , relation = RelationName "delegate"
        , subject = SubjectId user
        , caveat = Just autonomyCaveat
        }

sampleUsersetQuery :: UsersetQuery
sampleUsersetQuery =
    UsersetQuery
        { queryType = ObjectType "intention"
        , queryRelation = RelationName "delegate"
        , querySubjects = [SubjectId user]
        , queryLimit = 100
        , queryCursor = Just (StoreCursor "after-row-10")
        }

sampleTuplePage :: TuplePage
sampleTuplePage =
    TuplePage
        { rows =
            [ TupleRow
                { rowId = TupleRowId "tuple-1"
                , tuple = sampleTuple
                , createdAt = Revision "snapshot-created"
                , deletedAt = Nothing
                }
            ]
        , state = HasMore (StoreCursor "after-row-1")
        }

sampleDecision :: CheckDecision
sampleDecision =
    Conditional
        [ CaveatObligation
            { caveat = CaveatName "within_autonomy"
            , missingContext = ["requested_autonomy"]
            }
        ]

sampleLookupRequest :: LookupRequest
sampleLookupRequest =
    LookupRequest
        { subject = SubjectId user
        , permission = RelationName "view"
        , objectType = ObjectType "space"
        , context = requestContext
        , limit = LookupLimit 50
        , cursor = Nothing
        }

sampleLookupPage :: LookupPage
sampleLookupPage =
    LookupPage
        { objects = [space]
        , state = LookupTruncated (LookupCursor "cursor")
        }

sampleExpandRequest :: ExpandRequest
sampleExpandRequest =
    ExpandRequest
        { object = space
        , permission = RelationName "view"
        , context = requestContext
        , limit = ExpandLimit 25
        , cursor = Nothing
        }

sampleExpandTree :: ExpandTree
sampleExpandTree =
    ExpandTree
        { root = space
        , permission = RelationName "view"
        , children = []
        , state = ExpandExhausted
        }

sampleCaveatDefinition :: CaveatDefinition
sampleCaveatDefinition =
    CaveatDefinition
        { name = CaveatName "within_autonomy"
        , parameters =
            Map.fromList
                [ (CaveatParameterName "requested_autonomy", ParameterEnum ["read", "act"])
                , (CaveatParameterName "until", ParameterTimestamp)
                ]
        }

autonomyCaveat :: TupleCaveat
autonomyCaveat =
    TupleCaveat
        { name = CaveatName "within_autonomy"
        , payload =
            CaveatPayload
                ( Map.fromList
                    [ ("autonomy", ValueEnum "act")
                    , ("until", ValueTimestamp expiry)
                    ]
                )
        }

requestContext :: CaveatContext
requestContext =
    CaveatContext
        ( Map.fromList
            [ ("requested_autonomy", ValueEnum "act")
            , ("current_time", ValueTimestamp currentTime)
            ]
        )

user :: ObjectRef
user =
    ObjectRef
        { objectType = ObjectType "user"
        , objectId = "alice"
        }

space :: ObjectRef
space =
    ObjectRef
        { objectType = ObjectType "space"
        , objectId = "project-x"
        }

intention :: ObjectRef
intention =
    ObjectRef
        { objectType = ObjectType "intention"
        , objectId = "42"
        }

currentTime :: UTCTime
currentTime =
    parseUtc "2026-06-23T00:00:00Z"

expiry :: UTCTime
expiry =
    parseUtc "2026-07-01T00:00:00Z"

parseUtc :: String -> UTCTime
parseUtc =
    parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
