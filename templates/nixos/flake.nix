{
  description = "NixOS configuration for Lenovo Zhiyu";

  inputs.zhiyu.url = "github:PickaxeHit/linux-zhiyu/main";
  inputs.nixpkgs.follows = "zhiyu/nixpkgs";

  outputs =
    { nixpkgs, ... }:
    {
      nixosConfigurations.zhiyu = nixpkgs.lib.nixosSystem {
        modules = [ ./configuration.nix ];
      };
    };
}
