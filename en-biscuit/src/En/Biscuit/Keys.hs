{- |
Module      : En.Biscuit.Keys
Description : Issuer key identity, keysets, and key-material text codecs.

Biscuit tokens carry an optional integer /root key id/ in their protobuf
envelope (see 'Auth.Biscuit.mkBiscuitWith'); a verifier recovers it /before/
signature verification and uses it to pick which trusted public key to check the
signature against. That indirection is what makes issuer-key rotation a config
rollout rather than a synchronized fleet redeploy: mint new tokens under a new
key id while verifiers, configured with a keyset holding both the old and the
new public key, keep accepting in-flight tokens until they expire.

This module owns the en-side vocabulary for that mechanism:

  * 'IssuerKeyId' — the typed key identifier stamped into minted tokens
    ("En.Biscuit.Mint") and used to address a verifier's trusted keys.
  * 'IssuerKeySet' — the map from key id to trusted public key a verifier
    consults ("En.Biscuit.Verify"), plus an optional legacy key for tokens
    minted before key ids existed.
  * text codecs ('parseSigningKeyText', 'parseIssuerKeySetText',
    'renderIssuerKeySetText') for loading key material from single-line
    configuration (consumed by the HTTP minting server, EP-57).

The key id lives in the token envelope, not in the @en_*@ Datalog fact
vocabulary ("En.Biscuit.Grant"), so the wire fact vocabulary is untouched by
key rotation. A verifier written in any language reads the envelope field.
-}
module En.Biscuit.Keys (
    -- * Key identity
    IssuerKeyId (..),

    -- * Keysets
    IssuerKeySet (..),
    singleKey,
    selectIssuerKey,

    -- * Key-material text codecs
    parseSigningKeyText,
    parseIssuerKeySetText,
    renderIssuerKeySetText,
) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Text.Read (readMaybe)

import Auth.Biscuit (
    PublicKey,
    SecretKey,
    parsePublicKeyHex,
    parseSecretKeyHex,
    serializePublicKeyHex,
 )

{- | The integer identifier stamped into a minted token's Biscuit envelope and
used to address a verifier's trusted public keys. Key ids are non-negative
integers assigned by the operator; each new signing key gets a fresh id.
-}
newtype IssuerKeyId = IssuerKeyId Int
    deriving stock (Eq, Ord, Show)

{- | The set of issuer keys a verifier trusts, addressed by the token's root key
id. Must be non-empty (an empty set has no total 'selectIssuerKey'); the smart
constructors and parsers enforce that.
-}
data IssuerKeySet = IssuerKeySet
    { keysById :: Map IssuerKeyId PublicKey
    -- ^ Trusted issuer keys, addressed by the token's root key id.
    , legacyKey :: Maybe PublicKey
    {- ^ Key for tokens that carry no root key id (minted before EP-55 added
    key ids). 'Nothing' means such tokens are rejected.
    -}
    }
    deriving stock (Eq, Show)

-- | A keyset trusting exactly one key id and no legacy key.
singleKey :: IssuerKeyId -> PublicKey -> IssuerKeySet
singleKey keyId public =
    IssuerKeySet{keysById = Map.singleton keyId public, legacyKey = Nothing}

{- | Select the verification key for a token's root key id, as
'Auth.Biscuit.ParserConfig.getPublicKey' requires — a /total/ pure function.

A present id names its key; an absent id (a legacy token) selects 'legacyKey'.
An unknown id, or an absent legacy key, falls back to a deterministic member of
the keyset (the highest key id) so selection is always defined; the signature
check then fails closed with @InvalidSignatures@, because the fallback key did
not sign the token. A holder who rewrites a token's root key id therefore cannot
steer the verifier onto a key that would accept a forged signature — it can only
route to a key that rejects it.

A well-formed 'IssuerKeySet' is non-empty, so 'Map.findMax' below is total; the
constructors guarantee it.
-}
selectIssuerKey :: IssuerKeySet -> Maybe Int -> PublicKey
selectIssuerKey keySet mRootKeyId =
    case mRootKeyId of
        Nothing -> fromMaybe fallback keySet.legacyKey
        Just rootKeyId ->
            fromMaybe fallback (Map.lookup (IssuerKeyId rootKeyId) keySet.keysById)
  where
    -- The highest-id trusted key: deterministic and independent of the token,
    -- so an attacker cannot choose it. Falls back to the legacy key only if the
    -- id map is somehow empty, which the constructors forbid.
    fallback = case Map.lookupMax keySet.keysById of
        Just (_, public) -> public
        Nothing -> case keySet.legacyKey of
            Just public -> public
            Nothing -> error "En.Biscuit.Keys.selectIssuerKey: empty IssuerKeySet"

{- | Parse a single signing-key entry @\"\<key-id\>:\<64 hex chars\>\"@ into its
id and secret key. Whitespace around the entry is trimmed. The id must be a
non-negative integer and the key exactly 64 hex characters (a 32-byte ed25519
secret key, as 'Auth.Biscuit.parseSecretKeyHex' consumes).
-}
parseSigningKeyText :: Text -> Either Text (IssuerKeyId, SecretKey)
parseSigningKeyText raw = do
    (keyId, hexText) <- splitEntry raw
    secret <-
        maybe
            (Left ("not a valid 64-char hex secret key: " <> entryLabel raw))
            Right
            (parseSecretKeyHex (encodeUtf8 hexText))
    pure (keyId, secret)

{- | Parse a comma-separated keyset
@\"1:\<hex\>,2:\<hex\>\"@ into an 'IssuerKeySet'. Each entry is a
@\"\<key-id\>:\<64 hex chars\>\"@ public key; an optional @\"legacy:\<hex\>\"@
entry supplies 'legacyKey'. Whitespace around entries is trimmed. Empty input,
duplicate ids, non-hex material, and wrong-length keys are errors that name the
offending entry.
-}
parseIssuerKeySetText :: Text -> Either Text IssuerKeySet
parseIssuerKeySetText raw = do
    let entries = filter (not . T.null) (map T.strip (T.splitOn "," raw))
    case entries of
        [] -> Left "empty keyset"
        _ -> do
            parsed <- traverse parseKeyEntry entries
            let legacies = [pk | LegacyEntry pk <- parsed]
                keyed = [(kid, pk) | KeyedEntry kid pk <- parsed]
            keysById <- foldEntries keyed
            legacyKey <- case legacies of
                [] -> Right Nothing
                [pk] -> Right (Just pk)
                _ -> Left "duplicate legacy: entry"
            if Map.null keysById
                then Left "keyset has no keyed entries (only legacy:)"
                else Right IssuerKeySet{keysById, legacyKey}

-- | Render an 'IssuerKeySet' back to the 'parseIssuerKeySetText' format.
renderIssuerKeySetText :: IssuerKeySet -> Text
renderIssuerKeySetText keySet =
    T.intercalate "," (keyedEntries <> legacyEntry)
  where
    keyedEntries =
        [ T.pack (show n) <> ":" <> hexOf public
        | (IssuerKeyId n, public) <- sortOn (Down . fst) (Map.toList keySet.keysById)
        ]
    legacyEntry = case keySet.legacyKey of
        Nothing -> []
        Just public -> ["legacy:" <> hexOf public]
    hexOf = decodeUtf8 . serializePublicKeyHex

-- Internal ------------------------------------------------------------------

-- | One parsed keyset entry: either a keyed public key or the legacy key.
data KeySetEntry
    = KeyedEntry IssuerKeyId PublicKey
    | LegacyEntry PublicKey

parseKeyEntry :: Text -> Either Text KeySetEntry
parseKeyEntry raw =
    case T.breakOn ":" (T.strip raw) of
        (idPart, rest)
            | T.null rest -> Left ("entry is not \"<id>:<hex>\": " <> entryLabel raw)
            | T.strip idPart == "legacy" ->
                LegacyEntry <$> parsePublic (T.drop 1 rest) raw
            | otherwise -> do
                keyId <- parseKeyId (T.strip idPart) raw
                public <- parsePublic (T.drop 1 rest) raw
                pure (KeyedEntry keyId public)

-- | Split a @\"\<id\>:\<hex\>\"@ entry into its id and the raw hex text.
splitEntry :: Text -> Either Text (IssuerKeyId, Text)
splitEntry raw =
    case T.breakOn ":" (T.strip raw) of
        (idPart, rest)
            | T.null rest -> Left ("entry is not \"<id>:<hex>\": " <> entryLabel raw)
            | otherwise -> do
                keyId <- parseKeyId (T.strip idPart) raw
                pure (keyId, T.strip (T.drop 1 rest))

parseKeyId :: Text -> Text -> Either Text IssuerKeyId
parseKeyId idText raw =
    case readMaybe (T.unpack idText) of
        Just n | n >= 0 -> Right (IssuerKeyId n)
        _ -> Left ("key id is not a non-negative integer: " <> entryLabel raw)

parsePublic :: Text -> Text -> Either Text PublicKey
parsePublic hexText raw =
    maybe
        (Left ("not a valid 64-char hex public key: " <> entryLabel raw))
        Right
        (parsePublicKeyHex (encodeUtf8 (T.strip hexText)))

-- | Fold keyed entries into a map, rejecting a duplicate id by name.
foldEntries :: [(IssuerKeyId, PublicKey)] -> Either Text (Map IssuerKeyId PublicKey)
foldEntries = go Map.empty
  where
    go acc [] = Right acc
    go acc ((kid@(IssuerKeyId n), pk) : rest)
        | kid `Map.member` acc = Left ("duplicate key id: " <> T.pack (show n))
        | otherwise = go (Map.insert kid pk acc) rest

-- | A short, quote-wrapped label for an entry, for error messages.
entryLabel :: Text -> Text
entryLabel raw = "\"" <> T.strip raw <> "\""
