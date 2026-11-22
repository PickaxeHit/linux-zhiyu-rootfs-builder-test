let
  source = ./config;
  flake = builtins.getFlake ("path:" + toString source);
  inherit (flake.inputs) nixpkgs zhiyu;
  settings = builtins.fromJSON (builtins.readFile ./settings.json);
  specialArgs = {
    inherit
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
      flake.nixosConfigurations.${settings.hostname}.extendModules {
        inherit specialArgs;
        modules = [ ./deployment.nix ];
      };
  inherit (evaluated) config;
in
{
  deployment =
    assert config.networking.hostName == settings.hostname;
    config.system.build.deployment;
  inheritsRootMount =
    !(config.fileSystems ? "/") && !(builtins.any (mount: mount.where == "/") config.systemd.mounts);
}
