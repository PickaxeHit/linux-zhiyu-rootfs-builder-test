{
  config,
  pkgs,
  source,
  settings,
  nixpkgs,
  zhiyu,
  ...
}:
let
  inherit (settings)
    configuration
    desktop
    username
    hostname
    ;
  bsp = zhiyu.packages.aarch64-linux;
  camera = config.system.build.zhiyuCamera;
  bspChecks = zhiyu.checks.aarch64-linux;
  system = config.system.build.toplevel;
  imageSet = config.system.build.zhiyuImages;
  kernel = config.boot.kernelPackages.kernel;
  name = "nixos-zhiyu-${desktop}-rootfs";
  tarball = pkgs.callPackage (nixpkgs + "/nixos/lib/make-system-tarball.nix") {
    fileName = name;
    compressCommand = "cat";
    compressionExtension = "";
    extraInputs = [ ];
    contents = [ ];
    storeContents = [
      {
        object = system;
        symlink = "none";
      }
    ];
    extraCommands = pkgs.writeShellScript "zhiyu-rootfs-layout" ''
      set -euo pipefail
      install -d -m 0755 dev proc sys run var home mnt etc/nixos nix/var/nix/profiles
      install -d -m 0700 root var/lib/zhiyu
      install -d -m 1777 tmp
      install -m 0644 /dev/null etc/NIXOS
      install -m 0644 ${source}/{configuration.nix,flake.nix,flake.lock} etc/nixos/
      ln -s ${system} nix/var/nix/profiles/system-1-link
      ln -s system-1-link nix/var/nix/profiles/system
    '';
  };
  metadata = pkgs.writeText "zhiyu-deployment-metadata.json" (
    builtins.toJSON {
      inherit
        configuration
        desktop
        username
        hostname
        ;
      systemPath = system.outPath;
      systemDerivation = builtins.unsafeDiscardStringContext system.drvPath;
      upstreamCameraPath = builtins.unsafeDiscardStringContext camera.upstream.outPath;
      zhiyuCameraPath = builtins.unsafeDiscardStringContext camera.fork.outPath;
      kernelVersion = kernel.version;
      modDirVersion = kernel.modDirVersion;
      bspRevision = zhiyu.rev;
      nixpkgsRevision = nixpkgs.rev;
    }
  );
in
{
  system.build.deployment = pkgs.runCommand "zhiyu-${desktop}-deployment" { } ''
    mkdir "$out"
    ln -s ${tarball}/tarball/${name}.tar "$out/${name}.tar"
    ln -s ${system} "$out/system"
    ln -s ${imageSet} "$out/images"
    ln -s ${bsp.dtb}/lenovo-zhiyu.dtb "$out/board.dtb"
    ln -s ${config.system.build.zhiyuInitramfs}/initramfs.cpio.gz "$out/initramfs.cpio.gz"
    ln -s ${bsp.android-image-tools} "$out/android-tools"
    ln -s ${bsp.static-helpers}/bin/zhiyu-boot-select "$out/boot-selector"
    ln -s ${bspChecks.boot-tools.simulator}/bin/zhiyu-install "$out/flasher-simulator"
    ln -s ${zhiyu}/avb-test-key.pem "$out/avb-test-key.pem"
    ln -s ${metadata} "$out/metadata.json"
  '';
}
