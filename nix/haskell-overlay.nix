{ inputs, pkgs }:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck;

  localPackageNames = [
    "en-core"
    "en-migrations"
    "en-postgres"
    "en-biscuit"
    "en-servant"
    "en-client"
    "en-example"
    "en-server"
  ];
in
final: _prev:
pkgs.lib.genAttrs localPackageNames
  (name: dontCheck (final.callCabal2nix name (inputs.self + "/${name}") { }))
  // {
  # These dependencies are deliberately outside the shared channel until its
  # lock catches up to the versions selected by cabal.project.
  biscuit-haskell = dontCheck (doJailbreak (final.callCabal2nix
    "biscuit-haskell"
    (inputs.biscuit-haskell-src + "/biscuit")
    { }));

  generic-lens = dontCheck (final.callCabal2nix
    "generic-lens"
    (inputs.generic-lens-src + "/generic-lens")
    { });
  generic-lens-core = dontCheck (final.callCabal2nix
    "generic-lens-core"
    (inputs.generic-lens-src + "/generic-lens-core")
    { });

  hs-opentelemetry-instrumentation-servant = dontCheck (doJailbreak
    (final.callCabal2nix
      "hs-opentelemetry-instrumentation-servant"
      inputs.otel-servant-src
      { }));

  relay-pagination = dontCheck (doJailbreak (final.callCabal2nix
    "relay-pagination"
    (inputs.relay-pagination-src + "/relay-pagination")
    { }));
  relay-pagination-conformance = dontCheck (doJailbreak (final.callCabal2nix
    "relay-pagination-conformance"
    (inputs.relay-pagination-src + "/relay-pagination-conformance")
    { }));
  relay-pagination-hasql = dontCheck (doJailbreak (final.callCabal2nix
    "relay-pagination-hasql"
    (inputs.relay-pagination-src + "/relay-pagination-hasql")
    { }));
  relay-pagination-servant = dontCheck (doJailbreak (final.callCabal2nix
    "relay-pagination-servant"
    (inputs.relay-pagination-src + "/relay-pagination-servant")
    { }));

  servant-health = dontCheck (doJailbreak (final.callCabal2nix
    "servant-health"
    inputs.servant-health-src
    { }));
  servant-openapi-hs = dontCheck (doJailbreak (final.callCabal2nix
    "servant-openapi-hs"
    inputs.servant-openapi-hs-src
    { }));
}
