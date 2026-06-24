{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module DuplicateName where

import En.Schema (ValidSchema)
import qualified En.Schema.Builder as Schema
import En.Schema.TH (mkValidSchemaEither)

duplicateSchema :: ValidSchema
duplicateSchema =
    $$( mkValidSchemaEither $ do
            space <-
                Schema.object
                    "space"
                    [ Schema.relation "owner" [Schema.subject "user"] Schema.this
                    , Schema.relation "owner" [Schema.subject "user"] Schema.this
                    ]
            user <- Schema.object "user" []
            Schema.build [space, user]
      )
