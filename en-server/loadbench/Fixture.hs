-- | The benchmark's data set, credentials and server configurations.
--
-- The graph is small enough to seed in seconds and shaped so that every workload has a
-- known answer:
--
-- * 10,000 spaces @s0@..@s9999@; space @sI@ has user @u(I mod 1000)@ as a direct viewer,
--   and the first 5,000 also have the inner group @g(I mod 50)#member@ as a viewer.
-- * 1,000 users @u0@..@u999@; user @uJ@ is a member of the inner group @g(J mod 50)@.
-- * 100 groups. Inner group @gK@ (K < 50) is a member of outer group @g(50+K)@.
-- * 1,000 folders @f0@..@f999@; folder @fI@ has the outer group @g(50 + I mod 50)#member@
--   as its only viewer.
--
-- So user @uJ@ views 10 spaces directly and 100 through one group (five of them both
-- ways), and a lookup for any user returns 105 spaces; and every folder check resolves
-- through two levels of group membership.
--
-- Nested membership lives on folders, not spaces, because @lookup@ does not follow a
-- self-recursive userset (@group#member@ inside @group.member@) past its first level,
-- while @check@ does: a space granted to an outer group would be allowed by @check@ but
-- missing from @lookup@. Keeping the lookup's answer to one level of groups makes this
-- benchmark's expected count independent of that engine behaviour. See Surprises &
-- Discoveries in docs/plans/72-build-an-en-server-load-benchmark-and-record-the-single-tenant-baseline.md.
module Fixture
  ( userCount,
    lookupExpectedCount,
    writeSeedFile,
    seedTupleCount,
    ServerProfile (..),
    profileName,
    serverEnvironment,
    Credential (..),
    credentialSecret,
    victimCredential,
    aggressorCredential,
    schemaFixturePath,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as Char8
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import System.IO (IOMode (WriteMode), withBinaryFile)

userCount :: Int
userCount = 1000

spaceCount :: Int
spaceCount = 10000

-- | Inner groups; there are as many outer groups.
innerGroupCount :: Int
innerGroupCount = 50

-- | Spaces that also grant @view@ through an inner group.
groupGrantedSpaces :: Int
groupGrantedSpaces = 5000

-- | Spaces a lookup returns for any user: 10 direct, 100 via a group, 5 counted twice.
lookupExpectedCount :: Int
lookupExpectedCount = 105

seedTupleCount :: Int
seedTupleCount = spaceCount + groupGrantedSpaces + userCount + innerGroupCount + folderCount

folderCount :: Int
folderCount = 1000

-- | The schema every benchmark server serves, relative to the repository root.
schemaFixturePath :: FilePath
schemaFixturePath = "en-server/loadbench/fixtures/bench.en"

-- | Write the seed graph as newline-delimited JSON in the wire form @en-server import@ reads.
writeSeedFile :: FilePath -> IO ()
writeSeedFile path =
  withBinaryFile path WriteMode \handle ->
    Builder.hPutBuilder handle (foldMap line tuples)
  where
    line (object, relation, subject) =
      "{\"object\":"
        <> object
        <> ",\"relation\":\""
        <> relation
        <> "\",\"subject\":"
        <> subject
        <> ",\"caveat\":null}\n"
    ref objectType objectId =
      "{\"objectType\":\"" <> objectType <> "\",\"objectId\":\"" <> objectId <> "\"}"
    subjectId objectType objectId =
      "{\"kind\":\"id\",\"objectType\":\"" <> objectType <> "\",\"objectId\":\"" <> objectId <> "\"}"
    subjectSet objectType objectId relation =
      "{\"kind\":\"set\",\"objectType\":\""
        <> objectType
        <> "\",\"objectId\":\""
        <> objectId
        <> "\",\"relation\":\""
        <> relation
        <> "\"}"
    named prefix n = Builder.string7 prefix <> Builder.intDec n
    tuples =
      [ (ref "space" (named "s" i), "viewer", subjectId "user" (named "u" (i `mod` userCount)))
      | i <- [0 .. spaceCount - 1]
      ]
        <> [ (ref "space" (named "s" i), "viewer", subjectSet "group" (named "g" (i `mod` innerGroupCount)) "member")
           | i <- [0 .. groupGrantedSpaces - 1]
           ]
        <> [ (ref "folder" (named "f" i), "viewer", subjectSet "group" (named "g" (innerGroupCount + i `mod` innerGroupCount)) "member")
           | i <- [0 .. folderCount - 1]
           ]
        <> [ (ref "group" (named "g" (j `mod` innerGroupCount)), "member", subjectId "user" (named "u" j))
           | j <- [0 .. userCount - 1]
           ]
        <> [ (ref "group" (named "g" (innerGroupCount + k)), "member", subjectSet "group" (named "g" k) "member")
           | k <- [0 .. innerGroupCount - 1]
           ]

-- | How a benchmark server is configured beyond its database.
data ServerProfile
  = -- | Defaults, with background maintenance off.
    PlainProfile
  | -- | As 'PlainProfile' with the decision and tuple-read caches enabled.
    CachedProfile
  deriving stock (Eq, Ord, Show)

profileName :: ServerProfile -> Text
profileName = \case
  PlainProfile -> "plain"
  CachedProfile -> "cached"

-- | Which configured key a request presents.
data Credential
  = -- | The single read-write key, first in the server's key list.
    PrimaryKey
  | -- | The 64th read-only key: the last entry @authenticate@ scans.
    LastReadOnlyKey
  | -- | A named read-only key, for callers that must be distinct identities.
    ReadOnlyKey Int
  deriving stock (Eq, Show)

readOnlyKeyCount :: Int
readOnlyKeyCount = 64

victimCredential :: Credential
victimCredential = ReadOnlyKey 1

aggressorCredential :: Credential
aggressorCredential = PrimaryKey

credentialSecret :: Credential -> ByteString
credentialSecret = \case
  PrimaryKey -> "bench-primary-secret-0001"
  LastReadOnlyKey -> readOnlySecret readOnlyKeyCount
  ReadOnlyKey n -> readOnlySecret n

readOnlySecret :: Int -> ByteString
readOnlySecret n = Char8.pack ("bench-reader-secret-" <> pad n)
  where
    pad k = let s = show k in replicate (4 - length s) '0' <> s

-- | The variables a benchmark server is started with, apart from @EN_PORT@ and the
-- inherited base environment.
--
-- Background maintenance is off so a pass cannot land inside a measurement. Every
-- profile carries all 64 read-only keys; the primary key is first, so only
-- @check-last-key@ pays for the length of the list.
serverEnvironment :: ServerProfile -> Text -> FilePath -> [(String, String)]
serverEnvironment profile databaseUrl schemaPath =
  [ ("EN_DATABASE_URL", Text.unpack databaseUrl),
    ("EN_SCHEMA_PATH", schemaPath),
    ("EN_MAINTENANCE_INTERVAL_SECONDS", "0"),
    ("EN_API_KEYS_READ_WRITE", "bench:" <> Char8.unpack (credentialSecret PrimaryKey)),
    ( "EN_API_KEYS_READ_ONLY",
      intercalate
        ","
        [ "reader-" <> show n <> ":" <> Char8.unpack (readOnlySecret n)
        | n <- [1 .. readOnlyKeyCount]
        ]
    )
  ]
    <> case profile of
      PlainProfile -> []
      CachedProfile ->
        [ ("EN_DECISION_CACHE_MAX_ENTRIES", "10000"),
          ("EN_TUPLE_READ_CACHE_MAX_ENTRIES", "10000")
        ]
