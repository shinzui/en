{-# LANGUAGE TypeOperators #-}
-- The 'ToSchema' instances below are orphans: the wire types live in "En.Servant.API"
-- and the class in @openapi-hs@. They are deliberately here so that describing the API
-- stays separable from serving it, and so "En.Servant.API" does not import the OpenAPI
-- machinery. Both the types and these instances ship in this package, so no other
-- package can define a competing instance without depending on en-servant first.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | A machine-readable description of the en HTTP API, served at @GET \/v1\/openapi.json@.

Every 'ToSchema' instance here is written by hand, mirroring the hand-written aeson
instances in "En.Servant.API". Generic derivation would resurrect exactly the
constructor-tagged shapes those instances exist to remove, so the document would
describe an API en does not serve. The golden tests in @en-servant/test/Main.hs@ pin the
JSON; these instances describe the same grammar, and a mismatch between them is a bug in
this module.

The error responses (400, 412, 422, 503) are not declared here: they are response
alternatives of each operation's 'Servant.API.MultiVerb.MultiVerb' in "En.Servant.API",
so @servant-openapi-hs@ emits them per operation from the API type itself.
-}
module En.Servant.OpenApi (
    ServedAPI,
    servedProxy,
    enOpenApi,
    appWithOpenApi,
) where

import Control.Lens ((%~), (&), (.~), (?~), _Just)
import Data.Aeson qualified as Aeson
import Data.Char (toUpper)
import Data.HashMap.Strict.InsOrd qualified as InsOrdHashMap
import Data.OpenApi (
    AdditionalProperties (..),
    Definitions,
    NamedSchema (..),
    OpenApi,
    OpenApiItems (..),
    OpenApiType (..),
    OpenApiTypeValue (..),
    Referenced (..),
    Schema,
    ToSchema (..),
    additionalProperties,
    declareSchemaRef,
    description,
    enum_,
    get,
    info,
    items,
    oneOf,
    operationId,
    paths,
    post,
    properties,
    required,
    title,
    type_,
    version,
 )
import Data.OpenApi.Declare (Declare)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Effectful (IOE)
import Effectful qualified
import Effectful.Error.Static (Error)
import Servant (
    Application,
    Context (..),
    Get,
    JSON,
    serveWithContext,
    type (:<|>) (..),
    type (:>),
 )
import Servant.OpenApi (toOpenApi)

import En.Effect.ConsistencyStore (ConsistencyStore)
import En.Effect.TupleStore (TupleStore)
import En.Error (EnError)
import En.Servant.API (
    BatchCheckPairWire,
    BatchCheckRequestWire,
    BatchCheckResponseWire,
    CaveatContextWire,
    CaveatObligationWire,
    CaveatPayloadWire,
    CaveatValueWire,
    ChangeKindWire,
    CheckDecisionWire,
    CheckRequestWire,
    CheckResponseWire,
    ConsistencyWire,
    DeleteRelationshipsRequestWire,
    DeleteRelationshipsResponseWire,
    DeleteTuplesRequestWire,
    EnAPI,
    Env,
    ExpandNodeWire,
    ExpandRequestWire,
    ExpandStateWire,
    ExpandTreeWire,
    LookupObjectWire,
    LookupPageWire,
    LookupRequestWire,
    LookupStateWire,
    LookupSubjectWire,
    LookupSubjectsPageWire,
    LookupSubjectsRequestWire,
    LookupSubjectsStateWire,
    MintGrantRequestWire,
    MintGrantResponseWire,
    ObjectRefWire,
    PreconditionWire,
    ReadRelationshipsRequestWire,
    ReadRelationshipsResponseWire,
    RelationshipFilterWire,
    RelationshipsStateWire,
    SchemaInfoWire,
    SubjectRelationFilterWire,
    SubjectWire,
    TupleCaveatWire,
    TupleChangeWire,
    TupleFilterWire,
    TupleWire,
    WatchRequestWire,
    WatchResponseWire,
    WriteTuplesRequestWire,
    WriteTuplesResponseWire,
    apiProxy,
    envelopeFormatters,
    server,
 )
import En.Servant.Seam (ErrorEnvelopeWire)

{- | What @en-server@ actually serves: the client-facing API plus its own description.

The description route is deliberately outside 'EnAPI' so that @en-client@, which is
derived from 'EnAPI', is unaffected by it.
-}
type ServedAPI =
    EnAPI :<|> "v1" :> "openapi.json" :> Get '[JSON] OpenApi

servedProxy :: Proxy ServedAPI
servedProxy = Proxy

-- | The OpenAPI 3.1 document describing 'EnAPI'.
enOpenApi :: OpenApi
enOpenApi =
    toOpenApi apiProxy
        & info . title .~ "en authorization API"
        & info . version .~ "v1"
        & info . description ?~ "Relationship-based authorization: check, lookup, expand, and write."
        & withOperationIds

{- | Assign a stable @operationId@ to every operation, derived deterministically from its
method and path, so a code generator consuming the checked-in @docs/api/openapi.json@ emits
deterministic method names that do not churn when the document is regenerated. (en's own
Haskell client is servant's @genericClient@, whose names come from the 'EnApi' record fields,
so this matters only for a non-Haskell client generated from the artifact.)

en's operations are all @POST@ but @GET \/v1\/schema@, so in practice only the @post@ arm and
the one @get@ arm fire; a @get@ arm is kept for parity. An id is set only where one is not
already present, so a hand-assigned id would win.
-}
withOperationIds :: OpenApi -> OpenApi
withOperationIds =
    paths %~ InsOrdHashMap.mapWithKey setForPath
  where
    setForPath path item =
        item
            & post . _Just . operationId %~ orSet ("create" <> key)
            & get . _Just . operationId %~ orSet ("get" <> key)
      where
        key = camel path
    orSet identifier = Just . maybe identifier id

{- | Turn a path into a PascalCase identifier fragment: @\/v1\/relationships\/delete@ becomes
@V1RelationshipsDelete@. Splits on @\/@ and @-@ and capitalizes each segment, so distinct
paths always yield distinct fragments.
-}
camel :: FilePath -> Text
camel =
    Text.concat . map capitalize . filter (not . Text.null) . Text.split isSep . Text.pack
  where
    isSep c = c == '/' || c == '-'
    capitalize segment = case Text.uncons segment of
        Just (c, rest) -> Text.cons (toUpper c) rest
        Nothing -> segment

appWithOpenApi ::
    ( ConsistencyStore Effectful.:> es
    , TupleStore Effectful.:> es
    , Error EnError Effectful.:> es
    , IOE Effectful.:> es
    ) =>
    Env es ->
    Application
appWithOpenApi env =
    serveWithContext servedProxy (envelopeFormatters :. EmptyContext) (server env :<|> pure enOpenApi)

-- * Schema-construction helpers

-- | An object schema with the given properties, all of them required.
objectSchema :: [(Text, Referenced Schema)] -> Schema
objectSchema props =
    mempty
        & type_ ?~ OpenApiTypeSingle OpenApiObject
        & properties .~ InsOrdHashMap.fromList props
        & required .~ map fst props

{- | An object schema with required properties followed by optional ones.

Distinct from 'objectSchema' because an omitted field and a @null@ field are not
the same thing for the precondition types: omitting @subjectRelation@ means "any
relation", and omitting @preconditions@ means "none".
-}
partialObjectSchema :: [(Text, Referenced Schema)] -> [(Text, Referenced Schema)] -> Schema
partialObjectSchema requiredProps optionalProps =
    mempty
        & type_ ?~ OpenApiTypeSingle OpenApiObject
        & properties .~ InsOrdHashMap.fromList (requiredProps <> optionalProps)
        & required .~ map fst requiredProps

-- | A string schema admitting exactly one value: a sum type's discriminator.
literal :: Text -> Referenced Schema
literal value =
    Inline
        ( mempty
            & type_ ?~ OpenApiTypeSingle OpenApiString
            & enum_ ?~ [Aeson.String value]
        )

-- | @null@ is a type in OpenAPI 3.1, so an optional field is a @oneOf@ with it.
nullable :: Referenced Schema -> Referenced Schema
nullable ref =
    Inline (mempty & oneOf ?~ [ref, Inline (mempty & type_ ?~ OpenApiTypeSingle OpenApiNull)])

primitive :: OpenApiType -> Referenced Schema
primitive t = Inline (mempty & type_ ?~ OpenApiTypeSingle t)

textRef :: Referenced Schema
textRef = primitive OpenApiString

arrayOf :: Referenced Schema -> Referenced Schema
arrayOf element =
    Inline
        ( mempty
            & type_ ?~ OpenApiTypeSingle OpenApiArray
            & items ?~ OpenApiItemsObject element
        )

-- | A sum type: @oneOf@ over its variants.
sumSchema :: Text -> [Schema] -> NamedSchema
sumSchema name alternatives =
    NamedSchema (Just name) (mempty & oneOf ?~ map Inline alternatives)

-- * Instances

instance ToSchema ObjectRefWire where
    declareNamedSchema _ =
        pure (NamedSchema (Just "ObjectRefWire") (objectSchema [("objectType", textRef), ("objectId", textRef)]))

instance ToSchema SubjectWire where
    declareNamedSchema _ =
        pure $
            sumSchema
                "SubjectWire"
                [ objectSchema [("kind", literal "id"), ("objectType", textRef), ("objectId", textRef)]
                , objectSchema
                    [ ("kind", literal "set")
                    , ("objectType", textRef)
                    , ("objectId", textRef)
                    , ("relation", textRef)
                    ]
                , objectSchema [("kind", literal "wildcard"), ("objectType", textRef)]
                ]

instance ToSchema CaveatValueWire where
    declareNamedSchema _ = do
        timestamp <- declareSchemaRef (Proxy @UTCTime)
        pure $
            sumSchema
                "CaveatValueWire"
                [ objectSchema [("type", literal "text"), ("value", textRef)]
                , objectSchema [("type", literal "bool"), ("value", primitive OpenApiBoolean)]
                , objectSchema [("type", literal "integer"), ("value", primitive OpenApiInteger)]
                , objectSchema [("type", literal "timestamp"), ("value", timestamp)]
                , objectSchema [("type", literal "enum"), ("value", textRef)]
                ]

instance ToSchema CaveatPayloadWire where
    declareNamedSchema _ = do
        values <- caveatValueMap
        pure (NamedSchema (Just "CaveatPayloadWire") (objectSchema [("values", values)]))

instance ToSchema CaveatContextWire where
    declareNamedSchema _ = do
        values <- caveatValueMap
        pure (NamedSchema (Just "CaveatContextWire") (objectSchema [("values", values)]))

-- | @{"values": {"<name>": <CaveatValueWire>}}@ — an open map, hence additionalProperties.
caveatValueMap :: Declare (Definitions Schema) (Referenced Schema)
caveatValueMap = do
    value <- declareSchemaRef (Proxy @CaveatValueWire)
    pure $
        Inline
            ( mempty
                & type_ ?~ OpenApiTypeSingle OpenApiObject
                & additionalProperties ?~ AdditionalPropertiesSchema value
            )

instance ToSchema TupleCaveatWire where
    declareNamedSchema _ = do
        payload <- declareSchemaRef (Proxy @CaveatPayloadWire)
        pure (NamedSchema (Just "TupleCaveatWire") (objectSchema [("name", textRef), ("payload", payload)]))

instance ToSchema TupleWire where
    declareNamedSchema _ = do
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        subject <- declareSchemaRef (Proxy @SubjectWire)
        caveat <- declareSchemaRef (Proxy @TupleCaveatWire)
        pure $
            NamedSchema (Just "TupleWire") $
                objectSchema
                    [ ("object", object)
                    , ("relation", textRef)
                    , ("subject", subject)
                    , ("caveat", nullable caveat)
                    ]

instance ToSchema ConsistencyWire where
    declareNamedSchema _ =
        pure $
            sumSchema
                "ConsistencyWire"
                [ objectSchema [("mode", literal "minimizeLatency")]
                , objectSchema [("mode", literal "fullyConsistent")]
                , objectSchema [("mode", literal "atLeastAsFresh"), ("token", textRef)]
                , objectSchema [("mode", literal "atExactSnapshot"), ("token", textRef)]
                ]

instance ToSchema CheckRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        subject <- declareSchemaRef (Proxy @SubjectWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        pure $
            NamedSchema (Just "CheckRequestWire") $
                objectSchema
                    [ ("consistency", consistency)
                    , ("context", context)
                    , ("subject", subject)
                    , ("permission", textRef)
                    , ("object", object)
                    ]

instance ToSchema CaveatObligationWire where
    declareNamedSchema _ =
        pure $
            NamedSchema (Just "CaveatObligationWire") $
                objectSchema [("caveat", textRef), ("missingContext", arrayOf textRef)]

instance ToSchema CheckDecisionWire where
    declareNamedSchema _ = do
        obligation <- declareSchemaRef (Proxy @CaveatObligationWire)
        pure $
            sumSchema
                "CheckDecisionWire"
                [ objectSchema [("result", literal "allowed")]
                , objectSchema [("result", literal "denied")]
                , objectSchema [("result", literal "conditional"), ("obligations", arrayOf obligation)]
                ]

instance ToSchema CheckResponseWire where
    declareNamedSchema _ = do
        decision <- declareSchemaRef (Proxy @CheckDecisionWire)
        pure (NamedSchema (Just "CheckResponseWire") (objectSchema [("decision", decision), ("checkedAt", textRef)]))

instance ToSchema MintGrantRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        subject <- declareSchemaRef (Proxy @SubjectWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        pure $
            NamedSchema (Just "MintGrantRequestWire") $
                partialObjectSchema
                    [ ("consistency", consistency)
                    , ("context", context)
                    , ("subject", subject)
                    , ("permission", textRef)
                    , ("object", object)
                    , ("audience", textRef)
                    ]
                    [ ("ttlSeconds", primitive OpenApiInteger)
                    , ("requestId", textRef)
                    ]
                    & description
                        ?~ "Mints a Biscuit decision token if the server's own check for this \
                           \subject/permission/object is Allowed. subject must be a concrete \"id\" \
                           \subject. ttlSeconds, if given, must be positive and no greater than the \
                           \server maximum (else 400). Returns 403 when the decision is not Allowed, \
                           \and 404 when grant minting is not configured."

instance ToSchema MintGrantResponseWire where
    declareNamedSchema _ = do
        timestamp <- declareSchemaRef (Proxy @UTCTime)
        pure $
            NamedSchema (Just "MintGrantResponseWire") $
                objectSchema
                    [ ("token", textRef)
                    , ("expiresAt", timestamp)
                    , ("revocationIds", arrayOf textRef)
                    , ("checkedAt", textRef)
                    ]
                    & description
                        ?~ "token is the URL-safe base64 Biscuit to forward downstream in the \
                           \X-En-Biscuit header. revocationIds are the token's built-in block \
                           \revocation ids, hex-encoded. checkedAt is the consistency token the \
                           \mint's check evaluated at, also signed into the grant."

instance ToSchema BatchCheckPairWire where
    declareNamedSchema _ = do
        subject <- declareSchemaRef (Proxy @SubjectWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        pure $
            NamedSchema (Just "BatchCheckPairWire") $
                objectSchema [("subject", subject), ("permission", textRef), ("object", object)]

instance ToSchema BatchCheckRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        pair <- declareSchemaRef (Proxy @BatchCheckPairWire)
        pure $
            NamedSchema (Just "BatchCheckRequestWire") $
                objectSchema [("consistency", consistency), ("context", context), ("pairs", arrayOf pair)]

instance ToSchema BatchCheckResponseWire where
    declareNamedSchema _ = do
        decision <- declareSchemaRef (Proxy @CheckDecisionWire)
        pure (NamedSchema (Just "BatchCheckResponseWire") (objectSchema [("decisions", arrayOf decision), ("checkedAt", textRef)]))

instance ToSchema LookupRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        subject <- declareSchemaRef (Proxy @SubjectWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        pure $
            NamedSchema (Just "LookupRequestWire") $
                objectSchema
                    [ ("consistency", consistency)
                    , ("subject", subject)
                    , ("permission", textRef)
                    , ("objectType", textRef)
                    , ("context", context)
                    , ("limit", primitive OpenApiInteger)
                    , ("cursor", nullable textRef)
                    , ("deadlineMillis", nullable (primitive OpenApiInteger))
                    ]

instance ToSchema LookupObjectWire where
    declareNamedSchema _ = do
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        decision <- declareSchemaRef (Proxy @CheckDecisionWire)
        pure (NamedSchema (Just "LookupObjectWire") (objectSchema [("object", object), ("decision", decision)]))

instance ToSchema LookupStateWire where
    declareNamedSchema _ = pure (sumSchema "LookupStateWire" pageStateVariants)

instance ToSchema LookupPageWire where
    declareNamedSchema _ = do
        object <- declareSchemaRef (Proxy @LookupObjectWire)
        state <- declareSchemaRef (Proxy @LookupStateWire)
        pure (NamedSchema (Just "LookupPageWire") (objectSchema [("objects", arrayOf object), ("state", state), ("checkedAt", textRef)]))

instance ToSchema LookupSubjectsRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        pure $
            NamedSchema (Just "LookupSubjectsRequestWire") $
                objectSchema
                    [ ("consistency", consistency)
                    , ("object", object)
                    , ("permission", textRef)
                    , ("subjectType", textRef)
                    , ("context", context)
                    , ("limit", primitive OpenApiInteger)
                    , ("cursor", nullable textRef)
                    , ("deadlineMillis", nullable (primitive OpenApiInteger))
                    ]

instance ToSchema LookupSubjectWire where
    declareNamedSchema _ = do
        subject <- declareSchemaRef (Proxy @SubjectWire)
        decision <- declareSchemaRef (Proxy @CheckDecisionWire)
        pure (NamedSchema (Just "LookupSubjectWire") (objectSchema [("subject", subject), ("decision", decision)]))

instance ToSchema LookupSubjectsStateWire where
    declareNamedSchema _ = pure (sumSchema "LookupSubjectsStateWire" pageStateVariants)

instance ToSchema LookupSubjectsPageWire where
    declareNamedSchema _ = do
        subject <- declareSchemaRef (Proxy @LookupSubjectWire)
        state <- declareSchemaRef (Proxy @LookupSubjectsStateWire)
        pure $
            NamedSchema (Just "LookupSubjectsPageWire") $
                objectSchema [("subjects", arrayOf subject), ("state", state), ("checkedAt", textRef)]

instance ToSchema ExpandRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        context <- declareSchemaRef (Proxy @CaveatContextWire)
        pure $
            NamedSchema (Just "ExpandRequestWire") $
                objectSchema
                    [ ("consistency", consistency)
                    , ("object", object)
                    , ("permission", textRef)
                    , ("context", context)
                    , ("limit", primitive OpenApiInteger)
                    , ("cursor", nullable textRef)
                    ]

instance ToSchema ExpandNodeWire where
    declareNamedSchema _ = do
        subject <- declareSchemaRef (Proxy @SubjectWire)
        object <- declareSchemaRef (Proxy @ObjectRefWire)
        -- Self-referential. 'declareSchemaRef' registers the name before recursing (its
        -- Declare monad is lazy in the declarations), so this terminates and emits a
        -- component reference rather than an infinitely inlined schema.
        children <- arrayOf <$> declareSchemaRef (Proxy @ExpandNodeWire)
        pure $
            sumSchema
                "ExpandNodeWire"
                [ objectSchema [("kind", literal "subject"), ("subject", subject)]
                , objectSchema
                    [ ("kind", literal "userset")
                    , ("object", object)
                    , ("relation", textRef)
                    , ("children", children)
                    ]
                , objectSchema [("kind", literal "caveated"), ("caveat", textRef), ("children", children)]
                , objectSchema [("kind", literal "union"), ("children", children)]
                , objectSchema [("kind", literal "intersection"), ("children", children)]
                , objectSchema
                    [ ("kind", literal "exclusion")
                    , ("granted", children)
                    , ("subtracted", children)
                    ]
                ]

instance ToSchema ExpandStateWire where
    declareNamedSchema _ = pure (sumSchema "ExpandStateWire" pageStateVariants)

instance ToSchema ExpandTreeWire where
    declareNamedSchema _ = do
        root <- declareSchemaRef (Proxy @ObjectRefWire)
        node <- declareSchemaRef (Proxy @ExpandNodeWire)
        state <- declareSchemaRef (Proxy @ExpandStateWire)
        pure $
            NamedSchema (Just "ExpandTreeWire") $
                objectSchema
                    [ ("root", root)
                    , ("permission", textRef)
                    , ("children", arrayOf node)
                    , ("state", state)
                    , ("checkedAt", textRef)
                    ]

instance ToSchema SubjectRelationFilterWire where
    declareNamedSchema _ =
        pure $
            sumSchema
                "SubjectRelationFilterWire"
                [ objectSchema [("match", literal "any")]
                , objectSchema [("match", literal "none")]
                , objectSchema [("match", literal "exact"), ("relation", textRef)]
                ]

instance ToSchema TupleFilterWire where
    declareNamedSchema _ = do
        subjectRelation <- declareSchemaRef (Proxy @SubjectRelationFilterWire)
        pure $
            NamedSchema (Just "TupleFilterWire") $
                partialObjectSchema
                    [("objectType", textRef)]
                    [ ("objectId", textRef)
                    , ("relation", textRef)
                    , ("subjectType", textRef)
                    , ("subjectId", textRef)
                    , ("subjectRelation", subjectRelation)
                    ]

{- | Every field is optional, so the schema requires none. The anchoring grammar — at
least one of @objectType@ or @subjectType@, and the two dependency rules — is a
constraint OpenAPI cannot express, so it lives in the description instead of in
@required@, and is enforced by 'En.Servant.API.relationshipFilterFromWire'.
-}
instance ToSchema RelationshipFilterWire where
    declareNamedSchema _ = do
        subjectRelation <- declareSchemaRef (Proxy @SubjectRelationFilterWire)
        pure $
            NamedSchema (Just "RelationshipFilterWire") $
                partialObjectSchema
                    []
                    [ ("objectType", textRef)
                    , ("objectId", textRef)
                    , ("relation", textRef)
                    , ("subjectType", textRef)
                    , ("subjectId", textRef)
                    , ("subjectRelation", subjectRelation)
                    , ("caveatName", textRef)
                    ]
                    & description
                        ?~ "Must constrain objectType or subjectType. objectId requires objectType; \
                           \subjectId and a subjectRelation other than \"any\" require subjectType. \
                           \A filter anchored on neither end would scan the whole store and is rejected \
                           \with 400."

instance ToSchema ReadRelationshipsRequestWire where
    declareNamedSchema _ = do
        consistency <- declareSchemaRef (Proxy @ConsistencyWire)
        relationshipFilter <- declareSchemaRef (Proxy @RelationshipFilterWire)
        pure $
            NamedSchema (Just "ReadRelationshipsRequestWire") $
                objectSchema
                    [ ("consistency", consistency)
                    , ("filter", relationshipFilter)
                    , ("limit", primitive OpenApiInteger)
                    , ("cursor", nullable textRef)
                    ]

instance ToSchema RelationshipsStateWire where
    declareNamedSchema _ =
        pure $
            sumSchema
                "RelationshipsStateWire"
                [ objectSchema [("status", literal "exhausted")]
                , objectSchema [("status", literal "hasMore"), ("cursor", textRef)]
                ]

instance ToSchema ReadRelationshipsResponseWire where
    declareNamedSchema _ = do
        tuple <- declareSchemaRef (Proxy @TupleWire)
        state <- declareSchemaRef (Proxy @RelationshipsStateWire)
        pure $
            NamedSchema (Just "ReadRelationshipsResponseWire") $
                objectSchema [("relationships", arrayOf tuple), ("state", state), ("checkedAt", textRef)]

instance ToSchema DeleteRelationshipsRequestWire where
    declareNamedSchema _ = do
        relationshipFilter <- declareSchemaRef (Proxy @RelationshipFilterWire)
        pure $
            NamedSchema (Just "DeleteRelationshipsRequestWire") $
                objectSchema [("filter", relationshipFilter), ("dryRun", primitive OpenApiBoolean)]
                    & description
                        ?~ "dryRun has no default. A dry run reports how many relationships the filter \
                           \matches and deletes nothing; dryRun=false retires every match and returns a \
                           \consistency token that sees the revocation."

instance ToSchema DeleteRelationshipsResponseWire where
    declareNamedSchema _ =
        pure $
            NamedSchema (Just "DeleteRelationshipsResponseWire") $
                partialObjectSchema
                    [("dryRun", primitive OpenApiBoolean), ("count", primitive OpenApiInteger)]
                    [("token", nullable textRef)]

{- | Every field is optional but @limit@. The "exactly one start position" rule — @cursor@ or
@startToken@ or neither, never both — is a constraint OpenAPI cannot express, so it lives in
the description and is enforced by 'En.Servant.API.watchStartFromWire'.
-}
instance ToSchema WatchRequestWire where
    declareNamedSchema _ = do
        relationshipFilter <- declareSchemaRef (Proxy @RelationshipFilterWire)
        pure $
            NamedSchema (Just "WatchRequestWire") $
                partialObjectSchema
                    [("limit", primitive OpenApiInteger)]
                    [ ("cursor", nullable textRef)
                    , ("startToken", nullable textRef)
                    , ("filter", nullable relationshipFilter)
                    ]
                    & description
                        ?~ "Supply cursor to resume a subscription, startToken to start from the \
                           \snapshot a consistency token pins, or neither to start from now. \
                           \Supplying both is rejected with 400. There is no consistency field: a \
                           \poll's window is fixed by its start position and the store's head."

instance ToSchema ChangeKindWire where
    declareNamedSchema _ =
        pure $
            NamedSchema (Just "ChangeKindWire") $
                mempty
                    & type_ ?~ OpenApiTypeSingle OpenApiString
                    & enum_ ?~ [Aeson.String "touch", Aeson.String "delete"]

instance ToSchema TupleChangeWire where
    declareNamedSchema _ = do
        kind <- declareSchemaRef (Proxy @ChangeKindWire)
        tuple <- declareSchemaRef (Proxy @TupleWire)
        pure (NamedSchema (Just "TupleChangeWire") (objectSchema [("kind", kind), ("tuple", tuple)]))

instance ToSchema WatchResponseWire where
    declareNamedSchema _ = do
        change <- declareSchemaRef (Proxy @TupleChangeWire)
        pure $
            NamedSchema (Just "WatchResponseWire") $
                objectSchema [("changes", arrayOf change), ("cursor", textRef), ("checkedAt", textRef)]
                    & description
                        ?~ "changes carries no order: it is the set difference of the live tuple set \
                           \across the batch's window. cursor is always present, including on an empty \
                           \batch, and is the only thing to send back. An empty changes array does not \
                           \mean the feed is caught up; a caught-up feed returns a cursor equal to the \
                           \one it was given."

instance ToSchema SchemaInfoWire where
    declareNamedSchema _ = do
        timestamp <- declareSchemaRef (Proxy @UTCTime)
        pure $
            NamedSchema (Just "SchemaInfoWire") $
                objectSchema
                    [("source", textRef), ("hash", textRef), ("origin", textRef), ("loadedAt", timestamp)]
                    & description
                        ?~ "source is the verbatim schema text the server loaded, not a rendering of \
                           \the compiled model. origin is the file it came from, or builtin-demo. hash \
                           \is the fingerprint every consistency token is stamped with: when it changes, \
                           \every token minted under the old one is refused. There is no checkedAt — this \
                           \reads no tuples."

instance ToSchema PreconditionWire where
    declareNamedSchema _ = do
        tupleFilter <- declareSchemaRef (Proxy @TupleFilterWire)
        pure $
            sumSchema
                "PreconditionWire"
                [ objectSchema [("kind", literal "mustExist"), ("filter", tupleFilter)]
                , objectSchema [("kind", literal "mustNotExist"), ("filter", tupleFilter)]
                ]

instance ToSchema WriteTuplesRequestWire where
    declareNamedSchema _ = do
        tuple <- declareSchemaRef (Proxy @TupleWire)
        precondition <- declareSchemaRef (Proxy @PreconditionWire)
        pure $
            NamedSchema (Just "WriteTuplesRequestWire") $
                partialObjectSchema
                    [("tuples", arrayOf tuple)]
                    [("deletes", arrayOf tuple), ("preconditions", arrayOf precondition)]

instance ToSchema DeleteTuplesRequestWire where
    declareNamedSchema _ = do
        tuple <- declareSchemaRef (Proxy @TupleWire)
        precondition <- declareSchemaRef (Proxy @PreconditionWire)
        pure $
            NamedSchema (Just "DeleteTuplesRequestWire") $
                partialObjectSchema
                    [("tuples", arrayOf tuple)]
                    [("preconditions", arrayOf precondition)]

instance ToSchema WriteTuplesResponseWire where
    declareNamedSchema _ =
        pure (NamedSchema (Just "WriteTuplesResponseWire") (objectSchema [("token", textRef)]))

instance ToSchema ErrorEnvelopeWire where
    declareNamedSchema _ =
        pure $
            NamedSchema (Just "ErrorEnvelopeWire") $
                objectSchema
                    [ ("code", textRef)
                    , ("message", textRef)
                    , ("retryable", primitive OpenApiBoolean)
                    ]

-- | Lookup, lookup-subjects, and expand share one page-state grammar.
pageStateVariants :: [Schema]
pageStateVariants =
    [ objectSchema [("status", literal "exhausted")]
    , objectSchema [("status", literal "hasMore"), ("cursor", textRef)]
    , objectSchema [("status", literal "truncated"), ("cursor", textRef)]
    ]
