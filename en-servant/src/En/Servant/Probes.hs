-- | Build the liveness and readiness checks mounted by @en-server@.
module En.Servant.Probes
  ( mkProbes,
  )
where

import Servant.Health (ProbeCheck)
import Servant.Health.Check
  ( boolCheck,
    newFailureTracker,
    safeCheck,
    sequenceChecks,
    withProbeTimeout,
  )

-- | Construct the two checks once at process startup.
--
-- The first action reads in-process state and must not contact a dependency. The
-- second action implements en's PostgreSQL double-ping semantics. Each result is
-- independently tracked so a consecutive failure run keeps its original onset.
mkProbes :: IO Bool -> IO Bool -> IO (ProbeCheck, ProbeCheck)
mkProbes inProcessResponsive postgresReady = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  let liveness =
        trackLiveness
          ( withProbeTimeout
              2_000_000
              "liveness"
              (safeCheck "liveness" (boolCheck "liveness" inProcessResponsive))
          )
      readiness =
        trackReadiness
          ( sequenceChecks
              [safeCheck "postgres" (boolCheck "postgres" postgresReady)]
          )
  pure (liveness, readiness)
