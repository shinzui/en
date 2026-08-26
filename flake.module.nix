{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
    let
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

      sharedExtension = inputs.haskell-nix.lib.mkChannelExtension {
        channel = "github";
        disableProfiling = true;
        disableHaddock = true;
      };

      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = pkgs.lib.composeExtensions
          (sharedExtension pkgs.haskell.lib.compose pkgs)
          (import ./nix/haskell-overlay.nix { inherit inputs pkgs; });
      };
    in
    {
      haskellProject.extraDevPackages = [ pkgs.hurl ];

      packages = pkgs.lib.genAttrs localPackageNames
        (name: haskellPackages.${name})
      // {
        default = haskellPackages.en-server;
      };

      # Make the deployable default a required build, not only an evaluated
      # package output.
      checks.default-package = haskellPackages.en-server;
    };
}
