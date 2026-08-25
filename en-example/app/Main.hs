module Main (main) where

import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import En.Effect.TupleStore (writeTuples)
import En.Error (EnError)
import En.Example.Host
  ( app,
    mkEnv,
    newInMemoryWorld,
    runConsistencyStoreInMemory,
    runInMemoryStores,
    runTupleStoreInMemory,
    userRef,
    viewerTuple,
  )
import En.Tuple (Subject (..))
import Network.Wai.Handler.Warp qualified as Warp

main :: IO ()
main = do
  world <- newInMemoryWorld
  let alice = userRef "alice"
  seeded <-
    runEff
      ( runErrorNoCallStack @EnError
          (runInMemoryStores world (writeTuples [viewerTuple "doc1" alice]))
      )
  _ <- either (fail . show) pure seeded
  let env =
        mkEnv
          (runConsistencyStoreInMemory world)
          (runTupleStoreInMemory world)
      port = 8080
  putStrLn ("en-example listening on :" <> show port)
  putStrLn "Demo subject is fixed to alice; /documents/doc1 is allowed, other documents are denied."
  Warp.run port (app env (SubjectId alice))
