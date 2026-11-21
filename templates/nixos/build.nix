let
  source = ./config;
  flake = builtins.getFlake ("path:" + toString source);
  inherit (flake.inputs) nixpkgs zhiyu;
  settings = builtins.fromJSON (builtins.readFile ./settings.json);
  system = flake.nixosConfigurations.zhiyu.extendModules {
    modules = [ ./deployment.nix ];
    specialArgs = {
      inherit
        source
        nixpkgs
        zhiyu
        settings
        ;
    };
  };
in
{
  deployment = system.config.system.build.deployment;
  inheritsRootMount =
    !(system.config.fileSystems ? "/")
    && !(builtins.any (mount: mount.where == "/") system.config.systemd.mounts);
}
