{-# LANGUAGE QuasiQuotes #-}

module DuplicateQuotedSchema where

import En.Schema (ValidSchema)
import En.Schema.TH (schema)

duplicateQuotedSchema :: ValidSchema
duplicateQuotedSchema =
  [schema|
object user {}
object space {
  relation owner: user
  relation owner: user
}
|]
