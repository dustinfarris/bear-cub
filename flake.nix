# What a NixOS host needs to run Bear Cub (design §7). The build and
# service definitions stay in nix/; this file only exposes them. The
# module builds the package with the consuming host's pkgs, so a host
# should set `inputs.bear-cub.inputs.nixpkgs.follows = "nixpkgs"` to
# avoid evaluating a second nixpkgs; this repo's own nixpkgs pin is used
# only for building the package standalone.
{
  description = "Bear Cub family chore + calendar dashboard";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      nixosModules.default = ./nix/module.nix;
    };
}
