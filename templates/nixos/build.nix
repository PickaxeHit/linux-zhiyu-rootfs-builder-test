let
  source = ./config;
  flake = builtins.getFlake ("path:" + toString source);
  inherit (flake.inputs) nixpkgs zhiyu;
  settings = builtins.fromJSON (builtins.readFile ./settings.json);
  specialArgs = {
    inherit
      source
      nixpkgs
      zhiyu
      settings
      ;
  };
  evaluated =
    if settings.configuration == "configuration.nix" then
      import (nixpkgs + "/nixos") {
        inherit specialArgs;
        configuration.imports = [
          (source + "/configuration.nix")
          ./deployment.nix
        ];
      }
    else
      flake.nixosConfigurations.zhiyu.extendModules {
        inherit specialArgs;
        modules = [ ./deployment.nix ];
      };
  inherit (evaluated) config pkgs;
  camera = config.system.build.zhiyuCamera;
in
{
  deployment = config.system.build.deployment;
  cameraCachePaths = [
    camera.upstream
    camera.fork
  ]
  ++ pkgs.lib.optional config.services.pipewire.enable config.services.pipewire.package;
  inheritsRootMount =
    !(config.fileSystems ? "/") && !(builtins.any (mount: mount.where == "/") config.systemd.mounts);
}
