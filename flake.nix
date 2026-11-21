{
  description = "Bootable Zhiyu NixOS root filesystem and matching Android boot images";

  inputs.zhiyu.url = "github:PickaxeHit/linux-zhiyu-nix/35301a3026335168793040bc82b995e59de70726";
  inputs.nixpkgs.follows = "zhiyu/nixpkgs";

  outputs =
    {
      self,
      nixpkgs,
      zhiyu,
    }:
    let
      inherit (nixpkgs) lib;
      system = "aarch64-linux";
      desktops = [
        "minimal"
        "kde"
        "gnome"
        "plasmamobile"
      ];
      makeSystem =
        desktop:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit
              self
              nixpkgs
              zhiyu
              desktop
              ;
            bsp = zhiyu.packages.${system};
            bspChecks = zhiyu.checks.${system};
          };
          modules = [
            zhiyu.nixosModules.default
            ./nixos/base.nix
            ./nixos/desktop.nix
            ./nixos/deployment.nix
          ];
        };
      systems = lib.genAttrs desktops makeSystem;
    in
    {
      nixosConfigurations = systems;
      packages.${system} = lib.mapAttrs (_: host: host.config.system.build.deployment) systems;
      formatter = lib.genAttrs [ "x86_64-linux" system ] (
        platform: nixpkgs.legacyPackages.${platform}.nixfmt
      );
    };
}
