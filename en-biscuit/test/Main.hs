{-# LANGUAGE QuasiQuotes #-}

{- | Smoke test proving the @biscuit-haskell@ dependency is wired correctly:
generate a key pair, mint a Biscuit carrying a right, serialize and re-parse
it against the public key, then authorize it with an @allow@ policy. This is
a wiring check, not the real grant vocabulary — that arrives in later plans.
-}
module Main (main) where

import Control.Monad (when)
import Data.ByteString qualified as BS
import System.Exit (exitFailure)

import Auth.Biscuit (
    addBlock,
    authorizeBiscuit,
    authorizer,
    block,
    mkBiscuit,
    newSecret,
    parseB64,
    serializeB64,
    toPublic,
 )

main :: IO ()
main = do
    -- 1. Generate a fresh key pair using the library APIs.
    secret <- newSecret
    let public = toPublic secret

    -- 2. Mint a Biscuit whose authority block grants a right, then attenuate it
    --    with an extra block (proves both mkBiscuit and addBlock are usable).
    let authority = [block|right("file1", "read");|]
    biscuit <- mkBiscuit secret authority
    attenuated <- addBlock [block|check if right("file1", $op), $op.length() > 0;|] biscuit

    -- 3. Serialize to base64 and parse it back against the public key.
    let serialized = serializeB64 attenuated
    parsed <- either (fail . show) pure (parseB64 public serialized)

    -- 4. Authorize with an allow policy matching the granted right.
    let policy = [authorizer|allow if right("file1", "read");|]
    result <- authorizeBiscuit parsed policy

    case result of
        Left err -> do
            putStrLn ("en-biscuit smoke test FAILED: authorization rejected: " <> show err)
            exitFailure
        Right _ -> pure ()

    when (BS.null serialized) $ do
        putStrLn "en-biscuit smoke test FAILED: empty serialization"
        exitFailure

    putStrLn "en-biscuit smoke test PASS"
