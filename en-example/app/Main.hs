module Main (main) where

import En.Example.Host (app, mkEnv, runConsistencyStoreInMemory, runTupleStoreInMemory, userRef, viewerTuple)
import En.Tuple (Subject (..))
import Network.Wai.Handler.Warp qualified as Warp

main :: IO ()
main = do
  let alice = userRef "alice"
      env = mkEnv runConsistencyStoreInMemory (runTupleStoreInMemory [viewerTuple "doc1" alice])
      port = 8080
  putStrLn ("en-example listening on :" <> show port)
  putStrLn "Demo subject is fixed to alice; /documents/doc1 is allowed, other documents are denied."
  Warp.run port (app env (SubjectId alice))
