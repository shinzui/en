{-# LANGUAGE QuasiQuotes #-}

module BadQuotedSchema where

import En.Schema (ValidSchema)
import En.Schema.TH (schema)

badQuotedSchema :: ValidSchema
badQuotedSchema =
  [schema|
object user {}
object space {
  relation owner: user
  permission view = ownr
}
|]
