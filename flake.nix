{
  description = "**A schema-parametric, relationship-based authorization (ReBAC) toolkit for Haskell.**";

  inputs = {
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # Shared Haskell compatibility patches and first-party package sources.
    # mori://shinzui/haskell-nix
    haskell-nix = {
      url = "github:shinzui/haskell-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Project-specific sources not yet supplied at compatible revisions by the
    # shared channel. Keep these aligned with cabal.project.
    # mori://shinzui/biscuit-haskell
    biscuit-haskell-src = {
      url = "github:shinzui/biscuit-haskell/8c0b3c5a13ce4a310737c0336f2ae167a1597588";
      flake = false;
    };
    # mori://shinzui/hs-opentelemetry-instrumentation-servant
    otel-servant-src = {
      url = "github:shinzui/hs-opentelemetry-instrumentation-servant/7a6f692e85295f965cd1827f9354c28af9e62742";
      flake = false;
    };
    # mori://ekmett/lens/packages/generic-lens
    generic-lens-src = {
      url = "github:kcsongor/generic-lens/2.3.0.0";
      flake = false;
    };
    # mori://shinzui/relay-pagination
    relay-pagination-src = {
      url = "github:shinzui/relay-pagination/v0.1.1.0";
      flake = false;
    };
    # mori://shinzui/servant-health
    servant-health-src = {
      url = "github:shinzui/servant-health/v0.1.0.0";
      flake = false;
    };
    # mori://shinzui/servant-openapi-hs
    servant-openapi-hs-src = {
      url = "github:shinzui/servant-openapi-hs/v5.1.0";
      flake = false;
    };
  };

  # The haskell-nix-dev base flake's binary cache, so the first `nix develop` downloads
  # prebuilt GHC/HLS/cabal instead of compiling HLS from source. nixConfig is only honored
  # for users who trust this flake; for a guaranteed pull run `cachix use shinzui` once, or
  # add these two lines to your nix.conf.
  nixConfig = {
    extra-substituters = [ "https://shinzui.cachix.org" ];
    extra-trusted-public-keys = [ "shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=" ];
  };

  # This flake is a thin, seihou-managed shell. All project wiring lives in the
  # imported modules under ./nix, and your own customizations belong in an
  # (optional, unmanaged) ./flake.module.nix — see flake.module.nix.example.
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;

      imports =
        [
          ./nix/haskell.nix
          ./nix/treefmt.nix
          ./nix/pre-commit.nix
        ]
        # Your project-specific customizations. seihou never generates, touches,
        # or migrates this file, so it is the conflict-free place to extend.
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
