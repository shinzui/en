{- | The @MultiVerb@ response machinery shared by every en operation, and the small
handler plumbing that runs a handler body against the request's schema snapshot.

en is the reference implementation of the @MultiVerb@ convention: an operation's error
statuses are part of its /type/ (the 'EnResponses' list) and a handler returns a plain
sum ('EnResult') rather than throwing. The 'AsUnion' instance is written by hand — not
derived through @GenericAsUnion@ — so a change to the response list breaks the build
loudly; its final clause is the exhaustiveness witness. None of this logic changed in
the vertical-slice split; it only moved here from @En.Servant.API@.
-}
module En.Servant.Response (
    EnResponses,
    EnResult (..),
    faultToResult,
    enHandler,
    engine,
    activeSchema,
    orInvalid,
    traverseOrInvalid,
) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.SOP (I (..), NS (..))
import Data.Text (Text)
import Effectful (Eff)
import GHC.TypeLits (Symbol)
import Servant (Handler)
import Servant.API.MultiVerb (AsUnion (..), Respond)

import En.Servant.Seam (
    ActiveSchema,
    EnFault (..),
    Env (..),
    ErrorEnvelopeWire,
    invalidRequest,
    runEngineEither,
 )

{- | The statuses any en operation can answer with, as response alternatives of the
API type. Making them part of the type is what puts them in the generated OpenAPI
document and in @en-client@'s result type, instead of leaving them as untyped
'Servant.ServerError's thrown from a handler.

Every operation shares this list even though a write cannot in practice exceed a
traversal bound (422), and a read can never fail a write precondition (412).
'En.Error.EnError' is one closed sum shared by every operation, so the type system
cannot prove the write path never yields 'ResolutionLimitExceeded' nor that the read
path never yields 'WritePreconditionFailed'; a narrower list per operation would make
'faultToResult' partial. A total conversion is worth a slightly over-broad document.

Not covered here: errors raised before a handler runs. A malformed body or an unmatched
route comes from Servant's routing layer ('En.Servant.API.envelopeFormatters'), and
authentication/rate-limit rejections come from WAI middleware in @en-server@. All of
them still carry 'ErrorEnvelopeWire'.
-}
type EnResponses (description :: Symbol) a =
    '[ Respond 200 description a
     , Respond 400 "Invalid request" ErrorEnvelopeWire
     , Respond 412 "Write precondition failed" ErrorEnvelopeWire
     , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
     , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
     ]

-- | What an en handler returns. 'AsUnion' maps it onto 'EnResponses' positionally.
data EnResult a
    = EnOk a
    | -- | 400
      EnClientError !ErrorEnvelopeWire
    | -- | 412
      EnPreconditionFailed !ErrorEnvelopeWire
    | -- | 422
      EnUnprocessable !ErrorEnvelopeWire
    | -- | 503
      EnUnavailable !ErrorEnvelopeWire
    deriving stock (Eq, Show)

{- | Written by hand rather than derived through 'GenericAsUnion': the correspondence
between constructor and response alternative is the thing worth stating explicitly,
and a change to 'EnResponses' should break this instance loudly.
-}
instance
    AsUnion
        '[ Respond 200 description a
         , Respond 400 "Invalid request" ErrorEnvelopeWire
         , Respond 412 "Write precondition failed" ErrorEnvelopeWire
         , Respond 422 "Resolution limit exceeded" ErrorEnvelopeWire
         , Respond 503 "Tuple store unavailable" ErrorEnvelopeWire
         ]
        (EnResult a)
    where
    toUnion = \case
        EnOk value -> Z (I value)
        EnClientError envelope -> S (Z (I envelope))
        EnPreconditionFailed envelope -> S (S (Z (I envelope)))
        EnUnprocessable envelope -> S (S (S (Z (I envelope))))
        EnUnavailable envelope -> S (S (S (S (Z (I envelope)))))
    fromUnion = \case
        Z (I value) -> EnOk value
        S (Z (I envelope)) -> EnClientError envelope
        S (S (Z (I envelope))) -> EnPreconditionFailed envelope
        S (S (S (Z (I envelope)))) -> EnUnprocessable envelope
        S (S (S (S (Z (I envelope))))) -> EnUnavailable envelope
        S (S (S (S (S impossible)))) -> case impossible of {}

-- | Every 'EnFault' has a home in 'EnResponses'. This totality is why the list is shared.
faultToResult :: EnFault -> EnResult a
faultToResult = \case
    BadRequestFault envelope -> EnClientError envelope
    PreconditionFailedFault envelope -> EnPreconditionFailed envelope
    UnprocessableFault envelope -> EnUnprocessable envelope
    UnavailableFault envelope -> EnUnavailable envelope

{- | Run a handler body that may fail with an 'EnFault', turning either outcome into
the 'EnResult' the operation's 'MultiVerb' response list expects.

Handlers return faults rather than throwing them, which is what keeps every status
they can produce visible in the API type.
-}
enHandler :: ExceptT EnFault Handler a -> Handler (EnResult a)
enHandler body =
    either faultToResult EnOk <$> runExceptT body

{- | Run an engine action under the request's schema snapshot.

Every handler takes the snapshot once, at its start, and threads that one value through
both its evaluation ('ActiveSchema.graph') and its store interpreters (which build their
'En.Postgres.Revision.ConsistencyConfig' from @active.graph.hash@). A handler that called
'activeSchema' twice, or that passed one snapshot to 'engine' while reading a graph from
another, could straddle a schema reload and mint a token under a model it did not evaluate.
-}
engine :: Env es -> ActiveSchema -> Eff es a -> ExceptT EnFault Handler a
engine env active action =
    ExceptT (runEngineEither env active action)

-- | The schema this request is served under. Called once per handler. See 'engine'.
activeSchema :: Env es -> ExceptT EnFault Handler ActiveSchema
activeSchema env =
    liftIO env.readActiveSchema

-- | A wire-to-engine conversion failure is a client fault, not an engine error.
orInvalid :: Either Text a -> ExceptT EnFault Handler a
orInvalid =
    either (throwE . invalidRequest) pure

traverseOrInvalid :: (a -> Either Text b) -> [a] -> ExceptT EnFault Handler [b]
traverseOrInvalid convert values =
    orInvalid (traverse convert values)
