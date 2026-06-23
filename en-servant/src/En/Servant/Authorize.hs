-- | A @RequirePermission@ / @Authorize@ Servant combinator.
--
-- The authz counterpart to shomei-servant's @RequireScope@/@RequireRole@: where
-- shomei answers /may you do this class of thing at all/ (coarse, at the front
-- gate), this gates a route on @en.check(subject, permission, object)@ — /may you
-- do this to THIS object/. Composes /after/ shomei authentication (kikan C11+C13).
--
-- Placeholder — defined with the API type. See @docs/spec/0001-en-overview.md@.
module En.Servant.Authorize
  (
  ) where
