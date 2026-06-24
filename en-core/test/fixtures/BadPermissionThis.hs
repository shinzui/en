{-# LANGUAGE OverloadedStrings #-}

module BadPermissionThis where

import qualified En.Schema.Builder as Schema

badPermission :: Schema.SchemaRelation
badPermission =
    Schema.permission "view" Schema.this
