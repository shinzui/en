-- | The compiled schema: the reachability graph the engine traverses.
module En.Reachability
  ( ReachabilityGraph (..)
  , compile
  ) where

import En.Error (EnError)
import En.Schema (Schema)

-- | The compiled form of a 'Schema': for each subject type/relation, the
-- entrypoints by which it can reach a target object/relation. Boolean reachability
-- (SpiceDB-style); may later be refined with OpenFGA-style edge weights purely as a
-- traversal-ordering optimization. Opaque for now.
data ReachabilityGraph = ReachabilityGraph
  deriving stock (Eq, Show)

-- | Compile a consumer schema into the reachability graph 'En.Check.check' and
-- 'En.Lookup.lookup' traverse. In a fixed-schema design this could be hand-written;
-- en makes it generic over the supplied 'Schema' (the cost of being a toolkit).
compile :: Schema -> Either EnError ReachabilityGraph
compile _ =
  error "TODO(en): Schema -> ReachabilityGraph compiler; see docs/spec/0001-en-overview.md"
