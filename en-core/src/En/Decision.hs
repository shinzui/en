-- | The three-valued authorization decision and its combinators.
module En.Decision (
    CheckDecision (..),
    CaveatObligation (..),
    ResidualDecision (..),
    rUnion,
    rIntersection,
    rExclusion,
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

import En.Caveat.Value (CaveatPayload)
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

{- | A decision with its caveats left symbolic: the shape of a check answer
before any request context is applied.

The evaluator produces one of these for every subproblem, and
'En.Caveat.applyResidual' turns it into a 'CheckDecision' against a concrete
'En.Tuple.CaveatContext'. Because no context went into building it, the same
residual is a correct answer for /every/ request that asks the same
(datastore, schema, revision, subject, relation, object) question -- which is
what makes it cacheable across requests whose contexts differ.

'RCaveat' names a schema-declared caveat and carries the payload the granting
tuple was written with (a rewrite-level @Caveated@ node carries the empty
payload). The caveat /definition/ is not stored: the cache key pins the schema
hash, so the name resolves to the same definition at re-application time.

The three combinators mirror 'unionDecisions', 'intersectionDecisions', and
'exclusionDecisions' exactly. Keeping them as distinct constructors -- rather
than flattening to a list of outstanding caveats -- is what preserves whether
two residual caveats are joined by AND or by OR. An intersection of a failing
and a passing caveat must deny; the union of the same two must allow. A flat
list cannot tell those apart, and would silently pick one.
-}
data ResidualDecision
    = RAllowed
    | RDenied
    | RCaveat !CaveatName !CaveatPayload
    | RUnion ![ResidualDecision]
    | RIntersection ![ResidualDecision]
    | RExclusion !ResidualDecision !ResidualDecision
    deriving stock (Eq, Show)

{- | Union of residual decisions, collapsing the constant cases.

'RAllowed' -- an /unconditional/ allow -- absorbs a union, exactly as 'Allowed'
absorbs 'unionDecisions'. A caveated allow is an 'RCaveat' and absorbs nothing,
which is precisely what keeps the evaluator's union short-circuit sound once it
can no longer see the request context. 'RDenied' is the identity and drops out.
-}
rUnion :: [ResidualDecision] -> ResidualDecision
rUnion residuals
    | RAllowed `elem` residuals = RAllowed
    | otherwise =
        case filter (/= RDenied) residuals of
            [] -> RDenied
            [single] -> single
            kept -> RUnion kept

{- | Intersection of residual decisions, collapsing the constant cases.

Dual to 'rUnion': 'RDenied' absorbs, 'RAllowed' is the identity and drops out,
and the empty intersection is 'RAllowed'.
-}
rIntersection :: [ResidualDecision] -> ResidualDecision
rIntersection residuals
    | RDenied `elem` residuals = RDenied
    | otherwise =
        case filter (/= RAllowed) residuals of
            [] -> RAllowed
            [single] -> single
            kept -> RIntersection kept

{- | @base@ minus @subtrahend@, collapsing the constant cases of
'exclusionDecisions'.

Nothing can be subtracted from nothing, so an 'RDenied' base stays denied. An
unconditionally allowed subtrahend denies whatever the base was. An 'RDenied'
subtrahend subtracts nothing and leaves the base alone. Everything else stays
symbolic, because whether it allows or denies depends on the request context.
-}
rExclusion :: ResidualDecision -> ResidualDecision -> ResidualDecision
rExclusion RDenied _ = RDenied
rExclusion _ RAllowed = RDenied
rExclusion base RDenied = base
rExclusion base subtrahend = RExclusion base subtrahend

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
