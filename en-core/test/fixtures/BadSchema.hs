{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module BadSchema where

import En.Schema (ValidSchema)
import En.Schema.Builder qualified as Schema
import En.Schema.TH (mkValidSchema)

badSchema :: ValidSchema
badSchema =
  $$( mkValidSchema $
        either (error . ("invalid bad-schema fixture: " <>) . show) id $ do
          space <-
            Schema.object
              "space"
              [ Schema.relation "owner" [Schema.subject "user"] Schema.this,
                Schema.permission "view" (Schema.computed "ownr")
              ]
          user <- Schema.object "user" []
          Schema.build [space, user]
    )
