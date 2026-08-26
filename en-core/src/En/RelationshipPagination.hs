-- | Transport-neutral cursor rules for the relationship listing.
--
-- The cursor keys are the pinned consistency token followed by the internal,
-- monotonically increasing tuple-row key. The token is constant within one walk;
-- the row key supplies the total order.
module En.RelationshipPagination
  ( relationshipSortFingerprint,
    relationshipCursorToken,
    relationshipPageFromRows,
  )
where

import Data.Int (Int64)
import Data.List (sortOn)
import Data.Maybe (isJust, listToMaybe)
import Data.Word (Word32)
import En.Effect.TupleStore (TupleRow (..))
import En.Revision (ConsistencyToken (..))
import Relay.Pagination
  ( Connection (..),
    Cursor,
    CursorError (..),
    CursorPayload (..),
    Direction (..),
    Edge (..),
    KeyValue (..),
    PageInfo (..),
    PageRequest (..),
    cursorVersion,
    decodeCursor,
    encodeCursor,
  )

-- | FNV-1a fingerprint of @snapshot_token ASC text, id ASC int8@ under the
-- relay-pagination 0.1 cursor format. The PostgreSQL SortSpec is tested against
-- this value so the transport-neutral in-memory store mints identical cursors.
relationshipSortFingerprint :: Word32
relationshipSortFingerprint = 2670880983

-- | Recover the consistency token that a continuation cursor pins.
relationshipCursorToken :: Cursor -> Either CursorError ConsistencyToken
relationshipCursorToken cursor = fst <$> decodeRelationshipCursor cursor

-- | Page already-filtered rows in the same way as the PostgreSQL keyset engine.
relationshipPageFromRows ::
  ConsistencyToken ->
  PageRequest ->
  [TupleRow] ->
  Either CursorError (Connection TupleRow)
relationshipPageFromRows token request rows = do
  anchor <- traverse decodeRelationshipCursor request.cursor
  case anchor of
    Just (cursorToken, _)
      | cursorToken /= token ->
          Left (BadJson "relationship cursor snapshot does not match resolved consistency token")
    _ -> pure ()
  let canonicalRows = sortOn (.pageKey) rows
      anchorKey = snd <$> anchor
      candidates =
        case request.direction of
          Forward -> maybe canonicalRows (\key -> filter ((> key) . (.pageKey)) canonicalRows) anchorKey
          Backward ->
            reverse (maybe canonicalRows (\key -> filter ((< key) . (.pageKey)) canonicalRows) anchorKey)
      fetched = take (request.pageSize + 1) candidates
  pure (connectionFromRows token request fetched)

decodeRelationshipCursor :: Cursor -> Either CursorError (ConsistencyToken, Int64)
decodeRelationshipCursor cursor = do
  payload <- decodeCursor relationshipSortFingerprint cursor
  case payload.keys of
    [tokenValue, keyValue] -> do
      token <-
        case tokenValue of
          KvText value -> Right value
          other -> Left KeyTypeMismatch {expectedTag = "text", actualValue = other}
      key <-
        case keyValue of
          KvInt value -> Right value
          other -> Left KeyTypeMismatch {expectedTag = "int8", actualValue = other}
      Right (ConsistencyToken token, key)
    values ->
      Left KeyCountMismatch {expectedCount = 2, actualCount = length values}

connectionFromRows :: ConsistencyToken -> PageRequest -> [TupleRow] -> Connection TupleRow
connectionFromRows token request rows =
  Connection {edges, pageInfo}
  where
    probe = length rows > request.pageSize
    kept = take request.pageSize rows
    canonical =
      case request.direction of
        Forward -> kept
        Backward -> reverse kept
    edges = [Edge {node = row, cursor = mintRelationshipCursor token row} | row <- canonical]
    cursors = (.cursor) <$> edges
    (nextPage, previousPage) =
      case request.direction of
        Forward -> (probe, isJust request.cursor)
        Backward -> (isJust request.cursor, probe)
    pageInfo =
      PageInfo
        { hasNextPage = nextPage,
          hasPreviousPage = previousPage,
          startCursor = listToMaybe cursors,
          endCursor = listToMaybe (reverse cursors)
        }

mintRelationshipCursor :: ConsistencyToken -> TupleRow -> Cursor
mintRelationshipCursor (ConsistencyToken token) row =
  encodeCursor
    CursorPayload
      { version = cursorVersion,
        fingerprint = relationshipSortFingerprint,
        keys = [KvText token, KvInt row.pageKey]
      }
