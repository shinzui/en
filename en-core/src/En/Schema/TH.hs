{-# LANGUAGE TemplateHaskellQuotes #-}

{- | Template Haskell helpers for compile-time schema validation.

Use 'mkValidSchema' as @$$(mkValidSchema schemaValue)@ to validate a raw 'Schema'
while compiling the module that contains the splice. If validation fails, the
module fails to build with the same 'EnError' text the runtime validator would
return. If validation succeeds, the splice produces a 'ValidSchema'.
-}
module En.Schema.TH (
    mkValidSchema,
    mkValidSchemaEither,
) where

import Language.Haskell.TH.Syntax (Code, Q)
import Language.Haskell.TH.Syntax qualified as TH

import En.Error (EnError)
import En.Schema (Schema, ValidSchema, unValidSchema, validateSchema)
import En.Schema.Internal (unsafeValidSchema)

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
