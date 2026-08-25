{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BadPermissionThis where

import En.Schema.Builder qualified as Schema

badPermission :: Schema.SchemaRelation
badPermission =
  Schema.permission "view" Schema.this
