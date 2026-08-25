{-# LANGUAGE NoFieldSelectors #-}

-- | Static evaluation bounds shared by check, lookup, and expand.
--
-- A /budget/ is a static bound the engine carries for its whole life. A
-- /deadline/ ("En.Lookup") is a live clock poll. They are different things and are
-- threaded separately: raising the depth budget does not buy a slow lookup more
-- time, and a generous deadline does not let a traversal recurse deeper.
--
-- Until this record existed, all three numbers were private constants duplicated in
-- each of the three engine modules, so an operator with a deeply nested schema, or
-- an embedded deployment with a memory ceiling, could only change them by editing
-- library source. They are engine configuration, not per-request wire fields: a
-- client that could raise 'maxDepth' remotely holds an amplification lever.
module En.Budget
  ( EvaluationBudget (..),
    defaultEvaluationBudget,
  )
where

data EvaluationBudget = EvaluationBudget
  { -- | Recursion depth bound; exceeding it fails with @ResolutionLimitExceeded@.
    maxDepth :: !Int,
    -- | Storage read batch size. A batch size, /not/ a result ceiling: the
    --     engines drain pages until the store reports exhaustion, so a relation wider
    --     than one page is a large group rather than a resolution failure. Changing
    --     this trades store round trips against peak memory and cannot change an answer.
    pageLimit :: !Int,
    -- | Bound on returned result sets (lookup objects, expand nodes) per page.
    resultCap :: !Int
  }
  deriving stock (Eq, Show)

defaultEvaluationBudget :: EvaluationBudget
defaultEvaluationBudget =
  EvaluationBudget {maxDepth = 25, pageLimit = 1000, resultCap = 1000}
