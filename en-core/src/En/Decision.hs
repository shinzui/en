-- | The three-valued authorization decision and its combinators.
module En.Decision (
    CheckDecision (..),
    CaveatObligation (..),
    unionDecisions,
    intersectionDecisions,
    exclusionDecision,
    exclusionDecisions,
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

{- | Negate a subtrahend's decision, /assuming the base was 'Allowed'/.

This is the base-'Allowed' column of 'exclusionDecisions'. Evaluators should call
that instead: a conditional base must still consult its subtrahend.
-}
exclusionDecision :: CheckDecision -> CheckDecision
exclusionDecision =
    \case
        Allowed -> Denied
        Denied -> Allowed
        Conditional obligations -> Conditional obligations

{- | Combine a base decision with its subtrahend: @base@ minus @subtrahend@.

The subtrahend matters whenever the base is not 'Denied'. In particular an
unconditionally 'Allowed' subtrahend forces 'Denied' even over a 'Conditional'
base: telling a provably-excluded subject "supply more context and you may pass"
is a false conditional.

Subtract-side obligations pass through /un-negated/. 'CaveatObligation' names a
caveat and the context keys it still needs; it cannot express "this caveat must
evaluate false". 'Conditional' therefore keeps its plain meaning -- supply the
missing context and re-evaluate -- which stays true and safe, because the
re-evaluation runs this same function with a settled subtrahend and lands on
'Allowed' or 'Denied' correctly.
-}
exclusionDecisions :: CheckDecision -> CheckDecision -> CheckDecision
exclusionDecisions base subtrahend =
    case (base, subtrahend) of
        (Denied, _) -> Denied
        (_, Allowed) -> Denied
        (Allowed, Denied) -> Allowed
        (Allowed, Conditional obligations) -> Conditional obligations
        (Conditional obligations, Denied) -> Conditional obligations
        (Conditional baseObligations, Conditional subtractObligations) ->
            Conditional (dedupeObligations (baseObligations <> subtractObligations))

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
