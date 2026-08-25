{-# LANGUAGE TemplateHaskellQuotes #-}

-- | Template Haskell helpers for compile-time schema validation.
--
-- Use 'mkValidSchema' as @$$(mkValidSchema schemaValue)@ to validate a raw 'Schema'
-- while compiling the module that contains the splice. If validation fails, the
-- module fails to build with the same 'EnError' text the runtime validator would
-- return. If validation succeeds, the splice produces a 'ValidSchema'.
module En.Schema.TH
  ( mkValidSchema,
    mkValidSchemaEither,
    schema,
  )
where

import Data.Text qualified as Text
import En.Error (EnError)
import En.Schema (Schema, ValidSchema, unValidSchema, validateSchema)
import En.Schema.Internal (unsafeValidSchema)
import En.Schema.Parse qualified as SchemaParse
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import Language.Haskell.TH.Syntax (Code, Exp, Q)
import Language.Haskell.TH.Syntax qualified as TH

-- | Validate a raw 'Schema' at compile time and splice a 'ValidSchema'.
mkValidSchema :: Schema -> Code Q ValidSchema
mkValidSchema =
  mkValidSchemaEither . Right

-- | Validate a fallible schema-builder result at compile time and splice a 'ValidSchema'.
mkValidSchemaEither :: Either EnError Schema -> Code Q ValidSchema
mkValidSchemaEither schemaResult =
  case schemaResult >>= validateSchema of
    Left err ->
      TH.liftCode (fail ("schema validation failed at compile time: " <> show err))
    Right valid ->
      [||unsafeValidSchema $$(TH.liftTyped (unValidSchema valid))||]

-- | Expression quasi-quoter for compact, compile-time-validated schemas.
--
-- Minimal grammar:
--
-- @
-- object user {}
-- object space {
--   relation owner: user
--   relation parent: space
--   permission view = owner | parent->view
-- }
-- @
schema :: QuasiQuoter
schema =
  QuasiQuoter
    { quoteExp = quoteSchemaExp,
      quotePat = unsupported,
      quoteType = unsupported,
      quoteDec = unsupported
    }
  where
    unsupported _ =
      fail "schema quasi-quoter can only be used in expressions"

quoteSchemaExp :: String -> Q Exp
quoteSchemaExp input =
  case SchemaParse.parseSchema (Text.pack input) of
    Left err ->
      fail ("schema parse failed at compile time: " <> show err)
    Right parsedSchema ->
      TH.unTypeCode (mkValidSchema parsedSchema)
