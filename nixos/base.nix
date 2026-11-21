{
  config,
  lib,
  pkgs,
  ...
}:
let
  site = builtins.fromJSON (builtins.readFile ./site.json);
  localPassword = site.login == "password";
in
{
  assertions = [
    {
      assertion =
        builtins.match "[a-z_][a-z0-9_-]{0,31}" site.username != null && site.username != "root";
      message = "The initial user must have a valid non-root Linux username.";
    }
    {
      assertion = builtins.match "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?" site.hostname != null;
      message = "The hostname must be a single valid DNS label.";
    }
    {
      assertion = builtins.elem site.login [
        "ssh"
        "password"
      ];
      message = "The login method must be ssh or password.";
    }
  ];
  zhiyu.enable = true;
  networking.hostName = site.hostname;
  networking.networkmanager.enable = true;
  system.stateVersion = "26.05";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.channel.enable = false;

  # Enrol the operator by copying a public key to the target before boot.
  # Passwords can be configured after authenticated login.
  users.users = {
    root.hashedPassword = "!";
    ${site.username} = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
        "video"
      ];
      initialHashedPassword = "!";
      hashedPasswordFile = lib.mkIf localPassword "/var/lib/zhiyu/initial-password.hash";
    };
  };
  security.sudo.wheelNeedsPassword = localPassword;
  services.openssh = {
    enable = true;
    authorizedKeysFiles = [ "/etc/ssh/authorized_keys.d/%u" ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  environment.systemPackages = [ pkgs.git ];

  # The official system tarball contains Nix validity registrations. Load
  # them before store consumers, and keep the file on disk if import fails.
  systemd.services.zhiyu-register-store = {
    description = "Register the deployed Nix store closure";
    wantedBy = [ "sysinit.target" ];
    after = [ "local-fs.target" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "nix-daemon.service"
      "nix-daemon.socket"
    ];
    conflicts = [ "shutdown.target" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/nix-path-registration";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package "nix-store"} --load-db < /nix-path-registration
      ${pkgs.coreutils}/bin/rm /nix-path-registration
    '';
  };
  systemd.services.nix-daemon = {
    requires = [ "zhiyu-register-store.service" ];
    after = [ "zhiyu-register-store.service" ];
  };
}
