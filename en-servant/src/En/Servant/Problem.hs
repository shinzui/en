-- | RFC 9457 problem details and en's stable error catalog.
--
-- The catalog owns the status, title, machine code, and retryability of each error
-- kind. Call sites supply only request-specific prose. This keeps the JSON body,
-- thrown Servant errors, WAI middleware responses, and generated documentation on
-- one vocabulary.
module En.Servant.Problem
  ( ProblemDetails (..),
    problemJsonOptions,
    ProblemJSON,
    ProblemSpec (..),
    problemCatalog,
    problem,
    problemError,
    problemResponse,
    specUnknownRelation,
    specSchemaViolation,
    specMissingCaveatContext,
    specMalformedConsistencyToken,
    specConsistencyTokenExpired,
    specInvalidConsistencyToken,
    specInvalidCursor,
    specResolutionLimitExceeded,
    specCycleDetected,
    specWritePreconditionFailed,
    specStoreError,
    specInvalidRequest,
    specBatchTooLarge,
    specMalformedRequestBody,
    specNotFound,
    specPermissionDenied,
    specDecisionNotAllowed,
    specGrantNotMintable,
    specUnauthenticated,
    specRateLimited,
    specMethodNotAllowed,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    Options (fieldLabelModifier),
    ToJSON (toJSON),
    defaultOptions,
    eitherDecode,
    encode,
    genericParseJSON,
    genericToJSON,
  )
import En.Prelude (Generic, Text)
import Network.HTTP.Media ((//))
import Network.HTTP.Types (Header, mkStatus)
import Network.Wai (Response, responseLBS)
import Servant
  ( Accept (contentType),
    MimeRender (mimeRender),
    MimeUnrender (mimeUnrender),
    ServerError (..),
  )

-- | The problem-document body served under @application/problem+json@.
data ProblemDetails = ProblemDetails
  { problemType :: !Text,
    title :: !Text,
    status :: !Int,
    detail :: !Text,
    code :: !Text,
    retryable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | One field mapping shared by the JSON codec and the OpenAPI schema.
problemJsonOptions :: Options
problemJsonOptions =
  defaultOptions
    { fieldLabelModifier = \case
        "problemType" -> "type"
        other -> other
    }

instance ToJSON ProblemDetails where
  toJSON = genericToJSON problemJsonOptions

instance FromJSON ProblemDetails where
  parseJSON = genericParseJSON problemJsonOptions

-- | The @application/problem+json@ media type from RFC 9457.
data ProblemJSON

instance Accept ProblemJSON where
  contentType _ = "application" // "problem+json"

instance (ToJSON a) => MimeRender ProblemJSON a where
  mimeRender _ = encode

instance (FromJSON a) => MimeUnrender ProblemJSON a where
  mimeUnrender _ = eitherDecode

-- | One stable error kind. Request-specific text belongs in 'ProblemDetails.detail'.
data ProblemSpec = ProblemSpec
  { code :: !Text,
    status :: !Int,
    title :: !Text,
    retryable :: !Bool
  }
  deriving stock (Eq, Show)

-- | Build a wire document from a stable specification and request-specific detail.
problem :: ProblemSpec -> Text -> ProblemDetails
problem spec = problemAtStatus spec.status spec

-- | Render a problem as a thrown Servant error.
--
-- The body status comes from the base 'ServerError', so the HTTP status line and the
-- copied @status@ member cannot disagree.
problemError :: ServerError -> ProblemDetails -> ServerError
problemError base details =
  base
    { errBody = encode (detailsAtStatus base.errHTTPCode details),
      errHeaders = problemHeaders base.errHTTPCode <> withoutContentType base.errHeaders
    }

detailsAtStatus :: Int -> ProblemDetails -> ProblemDetails
detailsAtStatus responseStatus ProblemDetails {problemType = originalType, title = originalTitle, status = _, detail = originalDetail, code = originalCode, retryable = originalRetryable} =
  ProblemDetails
    { problemType = originalType,
      title = originalTitle,
      status = responseStatus,
      detail = originalDetail,
      code = originalCode,
      retryable = originalRetryable
    }

-- | Render a problem directly as a WAI response for middleware outside Servant.
problemResponse :: ProblemSpec -> Text -> Response
problemResponse spec requestDetail =
  responseLBS
    (mkStatus spec.status "")
    (problemHeaders spec.status)
    (encode (problem spec requestDetail))

problemAtStatus :: Int -> ProblemSpec -> Text -> ProblemDetails
problemAtStatus responseStatus spec requestDetail =
  ProblemDetails
    { problemType = "about:blank",
      title = spec.title,
      status = responseStatus,
      detail = requestDetail,
      code = spec.code,
      retryable = spec.retryable
    }

problemHeaders :: Int -> [Header]
problemHeaders responseStatus =
  ("Content-Type", "application/problem+json") : case responseStatus of
    401 -> [("WWW-Authenticate", "Bearer")]
    429 -> [("Retry-After", "1")]
    _ -> []

withoutContentType :: [Header] -> [Header]
withoutContentType = filter ((/= "Content-Type") . fst)

specUnknownRelation, specSchemaViolation, specMissingCaveatContext :: ProblemSpec
specMalformedConsistencyToken, specConsistencyTokenExpired, specInvalidConsistencyToken :: ProblemSpec
specInvalidCursor, specResolutionLimitExceeded, specCycleDetected :: ProblemSpec
specWritePreconditionFailed, specStoreError, specInvalidRequest :: ProblemSpec
specBatchTooLarge, specMalformedRequestBody, specNotFound :: ProblemSpec
specPermissionDenied, specDecisionNotAllowed, specGrantNotMintable :: ProblemSpec
specUnauthenticated, specRateLimited, specMethodNotAllowed :: ProblemSpec
specUnknownRelation = fixed "unknown_relation" 400 "Unknown relation"
specSchemaViolation = fixed "schema_violation" 400 "Schema violation"
specMissingCaveatContext = fixed "missing_caveat_context" 400 "Missing caveat context"

specMalformedConsistencyToken = fixed "malformed_consistency_token" 400 "Malformed consistency token"

specConsistencyTokenExpired = fixed "consistency_token_expired" 400 "Consistency token expired"

specInvalidConsistencyToken = fixed "invalid_consistency_token" 400 "Invalid consistency token"

specInvalidCursor = fixed "invalid_cursor" 400 "Invalid cursor"

specResolutionLimitExceeded = fixed "resolution_limit_exceeded" 422 "Resolution limit exceeded"

specCycleDetected = fixed "cycle_detected" 422 "Cycle detected"

specWritePreconditionFailed = fixed "write_precondition_failed" 412 "Write precondition failed"

specStoreError = retryable "store_error" 503 "Store unavailable"

specInvalidRequest = fixed "invalid_request" 400 "Invalid request"

specBatchTooLarge = fixed "batch_too_large" 400 "Batch too large"

specMalformedRequestBody = fixed "malformed_request_body" 400 "Bad request"

specNotFound = fixed "not_found" 404 "Not found"

specPermissionDenied = fixed "permission_denied" 403 "Permission denied"

specDecisionNotAllowed = fixed "decision_not_allowed" 403 "Decision not allowed"

specGrantNotMintable = fixed "grant_not_mintable" 400 "Grant not mintable"

specUnauthenticated = fixed "unauthenticated" 401 "Unauthenticated"

specRateLimited = retryable "rate_limited" 429 "Rate limited"

specMethodNotAllowed = fixed "method_not_allowed" 405 "Method not allowed"

fixed :: Text -> Int -> Text -> ProblemSpec
fixed specCode specStatus specTitle =
  ProblemSpec {code = specCode, status = specStatus, title = specTitle, retryable = False}

retryable :: Text -> Int -> Text -> ProblemSpec
retryable specCode specStatus specTitle =
  ProblemSpec {code = specCode, status = specStatus, title = specTitle, retryable = True}

-- | Every problem kind en can currently emit.
problemCatalog :: [ProblemSpec]
problemCatalog =
  [ specUnknownRelation,
    specSchemaViolation,
    specMissingCaveatContext,
    specMalformedConsistencyToken,
    specConsistencyTokenExpired,
    specInvalidConsistencyToken,
    specInvalidCursor,
    specResolutionLimitExceeded,
    specCycleDetected,
    specWritePreconditionFailed,
    specStoreError,
    specInvalidRequest,
    specBatchTooLarge,
    specMalformedRequestBody,
    specNotFound,
    specPermissionDenied,
    specDecisionNotAllowed,
    specGrantNotMintable,
    specUnauthenticated,
    specRateLimited,
    specMethodNotAllowed
  ]
