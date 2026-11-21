{
  config,
  desktop,
  pkgs,
  rootfsMode,
  self,
  nixpkgs,
  zhiyu,
  bsp,
  bspChecks,
  ...
}:
let
  system = config.system.build.toplevel;
  imageSet = config.system.build.zhiyuImages;
  kernel = config.boot.kernelPackages.kernel;
  name = "nixos-zhiyu-${desktop}-${rootfsMode}-rootfs";
  source = self.outPath;
  tarball = pkgs.callPackage (nixpkgs + "/nixos/lib/make-system-tarball.nix") {
    fileName = name;
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
      install -d -m 0700 root
      install -d -m 1777 tmp
      install -m 0644 /dev/null etc/NIXOS
      install -m 0644 ${source}/flake.nix ${source}/flake.lock etc/nixos/
      cp -r ${source}/nixos etc/nixos/nixos
      chmod -R u+w etc/nixos/nixos
      ln -s ${system} nix/var/nix/profiles/system-1-link
      ln -s system-1-link nix/var/nix/profiles/system
    '';
  };
  metadata = pkgs.writeText "zhiyu-deployment-metadata.json" (
    builtins.toJSON {
      inherit desktop rootfsMode;
      systemPath = system.outPath;
      systemDerivation = builtins.unsafeDiscardStringContext system.drvPath;
      kernelVersion = kernel.version;
      modDirVersion = kernel.modDirVersion;
      bspRevision = zhiyu.rev;
      nixpkgsRevision = nixpkgs.rev;
    }
  );
in
{
  system.build.deployment = pkgs.runCommand "zhiyu-${desktop}-${rootfsMode}-deployment" { } ''
    mkdir "$out"
    ln -s ${tarball}/tarball/${name}.tar.xz "$out/${name}.tar.xz"
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
