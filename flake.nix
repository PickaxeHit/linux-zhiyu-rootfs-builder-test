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
      modes = [
        "userdata"
        "sd"
      ];
      makeSystem =
        desktop: rootfsMode:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit
              self
              nixpkgs
              zhiyu
              desktop
              rootfsMode
              ;
            bsp = zhiyu.packages.${system};
            bspChecks = zhiyu.checks.${system};
          };
          modules = [
            zhiyu.nixosModules.default
            ./nixos/base.nix
            ./nixos/storage.nix
            ./nixos/desktop.nix
            ./nixos/deployment.nix
          ];
        };
      names = lib.concatMap (desktop: map (mode: "${desktop}-${mode}") modes) desktops;
      systems = lib.listToAttrs (
        lib.concatMap (
          desktop: map (mode: lib.nameValuePair "${desktop}-${mode}" (makeSystem desktop mode)) modes
        ) desktops
      );
    in
    {
      nixosConfigurations = systems;
      packages.${system} = lib.genAttrs names (name: systems.${name}.config.system.build.deployment);
      formatter = lib.genAttrs [ "x86_64-linux" system ] (
        platform: nixpkgs.legacyPackages.${platform}.nixfmt
      );
    };
}
