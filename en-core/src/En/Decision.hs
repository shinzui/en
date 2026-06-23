-- | The three-valued authorization decision and its combinators.
module En.Decision (
    CheckDecision (..),
    CaveatObligation (..),
    unionDecisions,
    intersectionDecisions,
    exclusionDecision,
    applyDecisionGate,
    dedupeObligations,
    union,
    intersection,
    exclusion,
    applyGate,
) where

import Data.Text (Text)

import En.Schema (CaveatName)

-- | A caveat that could not be reduced to an unconditional answer.
data CaveatObligation = CaveatObligation
    { caveat :: !CaveatName
    , missingContext :: ![Text]
    }
    deriving stock (Eq, Show)

{- | Three-valued authorization result. 'Conditional' means the graph path exists
but one or more caveats need request context before the caller may treat it as
allowed.
-}
data CheckDecision
    = Allowed
    | Denied
    | Conditional ![CaveatObligation]
    deriving stock (Eq, Show)

unionDecisions :: [CheckDecision] -> CheckDecision
unionDecisions decisions
    | Allowed `elem` decisions = Allowed
    | null obligations = Denied
    | otherwise = Conditional (dedupeObligations obligations)
  where
    obligations =
        concatMap
            ( \case
                Conditional current -> current
                _ -> []
            )
            decisions

intersectionDecisions :: [CheckDecision] -> CheckDecision
intersectionDecisions decisions
    | Denied `elem` decisions = Denied
    | all (== Allowed) decisions = Allowed
    | otherwise = Conditional (dedupeObligations obligations)
  where
    obligations =
        concatMap
            ( \case
                Conditional current -> current
                _ -> []
            )
            decisions

exclusionDecision :: CheckDecision -> CheckDecision
exclusionDecision =
    \case
        Allowed -> Denied
        Denied -> Allowed
        Conditional obligations -> Conditional obligations

applyDecisionGate :: CheckDecision -> CheckDecision -> CheckDecision
applyDecisionGate gate decision =
    intersectionDecisions [gate, decision]

dedupeObligations :: [CaveatObligation] -> [CaveatObligation]
dedupeObligations =
    foldl'
        ( \acc obligation ->
            if obligation `elem` acc then acc else acc <> [obligation]
        )
        []

union :: [CheckDecision] -> CheckDecision
union =
    unionDecisions

intersection :: [CheckDecision] -> CheckDecision
intersection =
    intersectionDecisions

exclusion :: CheckDecision -> CheckDecision
exclusion =
    exclusionDecision

applyGate :: CheckDecision -> CheckDecision -> CheckDecision
applyGate =
    applyDecisionGate
