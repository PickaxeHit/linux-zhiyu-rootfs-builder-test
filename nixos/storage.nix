{ lib, rootfsMode, ... }:
{
  # The BSP mounts Android userdata after handling encryption and bind-mounts
  # its linux directory. There is no second root mount or fixed block device.
  config = lib.mkIf (rootfsMode == "sd") {
    boot.kernelParams = [ "zhiyu.root=sd" ];
    fileSystems."/" = {
      device = "/dev/mmcblk0p1";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };
}
