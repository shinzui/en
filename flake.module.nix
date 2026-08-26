{ ... }:
{
  perSystem = { pkgs, ... }: {
    haskellProject.extraDevPackages = [ pkgs.hurl ];
  };
}
