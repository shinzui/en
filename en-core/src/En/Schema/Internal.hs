{- | INTERNAL. Home of the 'ValidSchema' newtype and its constructor, which the
public "En.Schema" module deliberately re-exports WITHOUT the constructor.
Importing this module lets you build a 'ValidSchema' WITHOUT running
'validateSchema', which defeats the evidence guarantee.

Do NOT import this to bypass validation. The sanctioned use is the compile-time
Template Haskell path in @En.Schema.TH@, which runs 'validateSchema' at compile
time and then wraps the proven-valid schema for splicing.
-}
module En.Schema.Internal (
    ValidSchema (..),
    unsafeValidSchema,
) where

import En.Schema.Types (Schema)

-- | Evidence that a 'Schema' passed validation.
newtype ValidSchema = ValidSchema {unValidSchema :: Schema}
    deriving stock (Eq, Show)

-- | INTERNAL/UNSAFE. Wrap a 'Schema' as a 'ValidSchema' without validating it.
unsafeValidSchema :: Schema -> ValidSchema
unsafeValidSchema = ValidSchema
