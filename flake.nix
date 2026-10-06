{
  description = "**A schema-parametric, relationship-based authorization (ReBAC) toolkit for Haskell.**";

  # Every module-owned input is decided by the module's pins: the haskell-nix-dev,
  # haskell-nix, and redpanda-container revisions below. Everything else `follows` them,
  # so this project's flake.lock is a pure function of those revs — every project on
  # this nix-haskell-flake version locks to byte-identical pins and shares one store closure
  # instead of each re-resolving `master` on its own schedule.
  #
  # The rev lives in the URL, not only in flake.lock, which is what makes it stick: a
  # rev-pinned input cannot be moved by `nix flake update`, so a stray full update in this
  # project is a no-op here and only touches inputs you added yourself. Verify with
  # `git diff flake.lock` — it should come back empty.
  #
  # seihou-managed: to move the toolchain or the shared patches, release a new
  # nix-haskell-flake version and `seihou update nix-haskell-flake`. Editing a rev here is a
  # conflict at the next run.
  inputs = {
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev/206ecd25bcb4a07581210bdae3e6f43c8fd179d8";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";
    flake-parts.follows = "haskell-nix-dev/flake-parts";
    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";
    pre-commit-hooks.follows = "haskell-nix-dev/pre-commit-hooks";

    # Shared Haskell patch registry (mori://shinzui/haskell-nix), available to
    # ./flake.module.nix when project-specific package wiring needs it. Keeping every
    # module-owned input present makes the shipped lock exact for every feature combination;
    # unused inputs are locked but never built. Both follows keep the graph to one
    # haskell-nix-dev and nixpkgs.
    haskell-nix = {
      url = "github:shinzui/haskell-nix/833edbe48bd6d80c33db4878853ab9ba484d21cc";
      inputs.haskell-nix-dev.follows = "haskell-nix-dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Project-local Redpanda on Apple Container (macOS), consumed by
    # ./nix/redpanda.nix only when nix.redpanda is enabled. Its scripts.nix and
    # defaults.nix are imported as files, so Apple-Silicon-only outputs are never
    # evaluated on Linux. Rev-pinned by the module; nixpkgs follows to keep one nixpkgs.
    redpanda-container = {
      url = "github:shinzui/redpanda-container/c2ccecf589b93e3430b758165de7d2a2bb92f328";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Project-specific source inputs the module does NOT own. A Nix flake can only
    # declare its inputs at the top level, so these must live here in the managed
    # flake.nix; they are consumed by the unmanaged ./nix/haskell-overlay.nix (imported
    # via ./flake.module.nix). They are the one edit that reconflicts on every
    # nix-haskell-flake upgrade — re-apply this block after each `seihou run`.
    # Keep these aligned with cabal.project.
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
