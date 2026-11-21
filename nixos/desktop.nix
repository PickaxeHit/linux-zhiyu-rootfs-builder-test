{
  desktop,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkMerge [
    (lib.mkIf (desktop != "minimal") {
      services.pipewire = {
        enable = true;
        pulse.enable = true;
      };
      security.rtkit.enable = true;
    })
    (lib.mkIf (desktop == "gnome") {
      services.displayManager.gdm.enable = true;
      services.desktopManager.gnome.enable = true;
    })
    (lib.mkIf
      (builtins.elem desktop [
        "kde"
        "plasmamobile"
      ])
      {
        services.displayManager.sddm = {
          enable = true;
          wayland.enable = true;
        };
        services.desktopManager.plasma6.enable = true;
      }
    )
    (lib.mkIf (desktop == "plasmamobile") {
      services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-mobile ];
      services.displayManager.defaultSession = "plasma-mobile";
    })
  ];
}
