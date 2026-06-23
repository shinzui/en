-- | The en HTTP API as a Servant API type: check / lookup / expand / write.
--
-- Placeholder — the API type is defined when en-servant lands. The surface mirrors
-- the engine: a check endpoint (subject, permission, object → decision + token),
-- a streaming lookup endpoint (subject, permission, type → objects + cursor), an
-- expand endpoint, and write/delete-tuple endpoints. See
-- @docs/spec/0001-en-overview.md@.
module En.Servant.API
  (
  ) where
