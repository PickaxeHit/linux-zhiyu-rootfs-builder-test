
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  services.displayManager.sessionPackages = [ pkgs.kdePackages.plasma-mobile ];
  services.displayManager.defaultSession = "plasma-mobile";
