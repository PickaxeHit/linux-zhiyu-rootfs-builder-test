{ lib, rootfsMode, ... }:
{
  # The BSP mounts Android userdata after handling encryption and bind-mounts
  # its linux directory. There is no second root mount or fixed block device.
  config = lib.mkIf (rootfsMode == "sd") {
    # Keep the userdata-first boot images. The BSP selects this ext4 root
    # only when userdata cannot supply a bootable generation.
    fileSystems."/" = {
      device = "/dev/mmcblk0p1";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };
}
