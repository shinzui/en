-- | Generic, schema-driven caveat evaluation.
module En.Caveat (
    evaluateCaveat,
) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)

import En.Caveat.Value (CaveatContext (..), CaveatPayload (..), CaveatValue (..))
import En.Decision (CaveatObligation (..), CheckDecision (..))
import En.Decision qualified as Decision
import En.Schema (
    CaveatCompare (..),
    CaveatDefinition (..),
    CaveatOperand (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    CaveatPredicate (..),
    CaveatSource (..),
 )

evaluateCaveat :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CheckDecision
evaluateCaveat definition payload context =
    evalPredicate definition payload context definition.predicate

evalPredicate :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CaveatPredicate -> CheckDecision
evalPredicate definition payload context =
    \case
        PredTrue -> Allowed
        PredCompare comparator left right ->
            evalCompare definition payload context comparator left right
        PredAnd predicates ->
            Decision.intersection (evalPredicate definition payload context <$> predicates)
        PredOr predicates ->
            Decision.union (evalPredicate definition payload context <$> predicates)
        PredNot predicate ->
            case evalPredicate definition payload context predicate of
                Allowed -> Denied
                Denied -> Allowed
                Conditional obligations -> Conditional obligations
        PredMember operand values ->
            case resolveOperand definition payload context operand of
                OperandReady value ->
                    if value `elem` values then Allowed else Denied
                OperandMissingContext names ->
                    missingDecision definition names
                OperandDenied ->
                    Denied

evalCompare :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CaveatCompare -> CaveatOperand -> CaveatOperand -> CheckDecision
evalCompare definition payload context comparator left right =
    case (resolveOperand definition payload context left, resolveOperand definition payload context right) of
        (OperandReady leftValue, OperandReady rightValue) ->
            if compareValues definition left right comparator leftValue rightValue
                then Allowed
                else Denied
        (leftResult, rightResult) ->
            case missingContexts [leftResult, rightResult] of
                [] -> Denied
                missing -> missingDecision definition missing

data OperandResult
    = OperandReady !CaveatValue
    | OperandMissingContext ![Text]
    | OperandDenied

resolveOperand :: CaveatDefinition -> CaveatPayload -> CaveatContext -> CaveatOperand -> OperandResult
resolveOperand _ _ _ (OperandLiteral value) =
    OperandReady value
resolveOperand _ (CaveatPayload payload) (CaveatContext context) (OperandParam source parameterName) =
    case source of
        FromContext ->
            case Map.lookup key context of
                Just value -> OperandReady value
                Nothing -> OperandMissingContext [key]
        FromPayload ->
            case Map.lookup key payload of
                Just value -> OperandReady value
                Nothing -> OperandDenied
  where
    CaveatParameterName key = parameterName

missingContexts :: [OperandResult] -> [Text]
missingContexts =
    concatMap
        ( \case
            OperandMissingContext names -> names
            _ -> []
        )

missingDecision :: CaveatDefinition -> [Text] -> CheckDecision
missingDecision definition names =
    Conditional [CaveatObligation{caveat = definition.name, missingContext = dedupe names}]

compareValues :: CaveatDefinition -> CaveatOperand -> CaveatOperand -> CaveatCompare -> CaveatValue -> CaveatValue -> Bool
compareValues definition leftOperand rightOperand comparator leftValue rightValue =
    case enumOrder definition leftOperand rightOperand of
        Just order ->
            case (enumRank order leftValue, enumRank order rightValue) of
                (Just leftRank, Just rightRank) -> applyCompare comparator leftRank rightRank
                _ -> False
        Nothing ->
            case (leftValue, rightValue) of
                (ValueText left, ValueText right) -> applyCompare comparator left right
                (ValueBool left, ValueBool right) -> applyCompare comparator left right
                (ValueInteger left, ValueInteger right) -> applyCompare comparator left right
                (ValueTimestamp left, ValueTimestamp right) -> applyCompare comparator left right
                (ValueEnum left, ValueEnum right) -> applyCompare comparator left right
                _ -> False

enumOrder :: CaveatDefinition -> CaveatOperand -> CaveatOperand -> Maybe [Text]
enumOrder definition left right =
    case firstEnum left of
        Just order -> Just order
        Nothing -> firstEnum right
  where
    firstEnum =
        \case
            OperandParam _ parameterName ->
                case Map.lookup parameterName definition.parameters of
                    Just (ParameterEnum values) -> Just values
                    _ -> Nothing
            OperandLiteral _ -> Nothing

enumRank :: [Text] -> CaveatValue -> Maybe Int
enumRank order =
    \case
        ValueEnum value -> lookup value (zip order [0 ..])
        ValueText value -> lookup value (zip order [0 ..])
        _ -> Nothing

applyCompare :: (Ord a) => CaveatCompare -> a -> a -> Bool
applyCompare =
    \case
        CmpEq -> (==)
        CmpNe -> (/=)
        CmpLt -> (<)
        CmpLe -> (<=)
        CmpGt -> (>)
        CmpGe -> (>=)

dedupe :: (Eq a) => [a] -> [a]
dedupe =
    foldl'
        ( \acc value ->
            if value `elem` acc then acc else acc <> [value]
        )
        []
