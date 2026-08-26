-- | Process-scoped OpenTelemetry provider ownership for @en-server@.
--
-- The service-specific switch decides whether this process initializes telemetry at all.
-- Exporters, sampling, resources, propagation, and the collector endpoint remain configured
-- by the SDK's standard @OTEL_*@ environment variables.
module Telemetry
  ( TelemetryConfig (..),
    withTelemetry,
    instrumentationLibrary,
  )
where

import Control.Exception (bracket)
import En.Prelude
import Network.Wai (Middleware)
import OpenTelemetry.Attributes qualified as Attributes
import OpenTelemetry.Instrumentation.Wai (newOpenTelemetryWaiMiddleware)
import OpenTelemetry.Metric qualified as OTelMetric
import OpenTelemetry.Trace qualified as OTel

-- | Whether the standalone server owns an OpenTelemetry SDK lifecycle.
data TelemetryConfig
  = TelemetryDisabled
  | TelemetryEnabled
  deriving stock (Generic, Eq, Show)

-- | Bracket both global providers for one server lifetime.
--
-- The WAI middleware reads the global tracer and meter providers when it is constructed,
-- so construction deliberately happens only after both providers have been installed.
-- The disabled path initializes nothing and supplies identity middleware.
withTelemetry :: TelemetryConfig -> ((Maybe OTel.TracerProvider, Middleware) -> IO a) -> IO a
withTelemetry TelemetryDisabled action = action (Nothing, id)
withTelemetry TelemetryEnabled action =
  bracket OTel.initializeGlobalTracerProvider flushAndShutdownTracer $ \tracerProvider ->
    bracket
      OTelMetric.initializeGlobalMeterProvider
      (\meterProvider -> void (OTelMetric.shutdownMeterProvider meterProvider Nothing))
      ( \_meterProvider -> do
          waiMiddleware <- newOpenTelemetryWaiMiddleware
          action (Just tracerProvider, waiMiddleware)
      )
  where
    flushAndShutdownTracer tracerProvider = do
      void (OTel.forceFlushTracerProvider tracerProvider Nothing)
      void (OTel.shutdownTracerProvider tracerProvider Nothing)

-- | The instrumentation scope used by application spans created by @en-server@.
instrumentationLibrary :: OTel.InstrumentationLibrary
instrumentationLibrary =
  OTel.InstrumentationLibrary
    { OTel.libraryName = "en-server",
      OTel.libraryVersion = "0.1.0.0",
      OTel.librarySchemaUrl = "",
      OTel.libraryAttributes = Attributes.emptyAttributes
    }
