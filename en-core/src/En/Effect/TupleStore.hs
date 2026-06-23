-- | The tuple-store effect: the storage interface the engine evaluates against.
--
-- Expressed as a record of functions so a consumer or test can supply an in-memory
-- or PostgreSQL implementation. (Integration with a concrete effect system follows
-- shomei's @Shomei.Effect.*@ convention; refined as the engine lands.)
module En.Effect.TupleStore
  ( TupleStore (..)
  , UsersetQuery (..)
  ) where

import En.Revision (ConsistencyToken, Revision)
import En.Schema (ObjectType, RelationName)
import En.Tuple (ObjectRef, Subject, Tuple)

-- | The reverse-lookup query the engine issues against storage: "objects of
-- @queryType@ on @queryRelation@ whose subject is one of @querySubjects@."
-- This single primitive — Zanzibar's @ReadStartingWithUser@ — backs both
-- 'En.Check.check' and 'En.Lookup.lookup'.
data UsersetQuery = UsersetQuery
  { queryType     :: ObjectType
  , queryRelation :: RelationName
  , querySubjects :: [Subject]
  }

-- | The store effect. Reads take a 'Revision' (the resolved consistency snapshot);
-- writes return a 'ConsistencyToken' for read-your-writes.
data TupleStore m = TupleStore
  { readStartingWithUser :: Revision -> UsersetQuery -> m [ObjectRef]
  , writeTuples          :: [Tuple] -> m ConsistencyToken
  , deleteTuples         :: [Tuple] -> m ConsistencyToken
  , headRevision         :: m Revision
  , optimizedRevision    :: m Revision
  }
