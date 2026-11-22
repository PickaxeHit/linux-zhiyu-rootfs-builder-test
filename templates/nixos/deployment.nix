{
  config,
  pkgs,
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
    ln -s ${pkgs.nixos-install}/bin/nixos-install "$out/nixos-install"
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
