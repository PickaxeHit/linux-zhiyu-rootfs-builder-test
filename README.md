# Zhiyu Rootfs Builder

The Debian, Arch Linux ARM and Fedora workflows produce standalone root filesystems.
Their device packages come from the [Zhiyu package repository](https://github.com/PickaxeHit/linux-zhiyu-pkgs/releases).
The NixOS deployment workflow builds a root filesystem and its four paired Android
boot images from a single pinned NixOS configuration. Download them together from
one Actions run.

## Build a NixOS deployment

Use **Build Rootfs (NixOS)** in Actions to select a desktop, root filesystem
location, initial username, hostname and login method.

On an ARM64 Nix machine with flakes enabled, run:

```sh
ROOTFS_USERNAME=alice ROOTFS_HOSTNAME=zhiyu-tablet ROOTFS_LOGIN=ssh \
  scripts/build-nixos.sh minimal userdata "$PWD/deploy"
(cd deploy && sha256sum --check --strict SHA256SUMS)
```

Desktop choices are `minimal`, `kde`, `gnome` and `plasmamobile`.
Storage modes are `userdata` and `sd`. The former uses the BSP to unlock Android
userdata and boot from `/data/linux`. The latter uses an ext4 filesystem on
`/dev/mmcblk0p1`. These choices are also available through the Actions manual
dispatch. An optional expected BSP revision checks the committed lock without
changing it. Test releases are opt-in in the test repository. The manifest records the selected account settings. Passwords and hashes are provisioned on the extracted rootfs.

## Deploy a matched set

1. Check `SHA256SUMS` and confirm the storage mode in `manifest.json`. Preserve
   numeric ownership and permissions when extracting the tarball as a privileged
   user into the empty target directory or mounted microSD root. The target must
   support Unix permissions and symlinks.
2. Provision the login method selected in Actions. The default username is
   `operator`. For `ssh`, put your public key at `etc/ssh/authorized_keys.d/<username>`
   in the extracted root, owned by root with mode `0600`. After connecting
   over SSH, you can set a desktop password with `sudo passwd <username>`.
   For `password`, set an initial console or desktop password before booting
   by saving its hash at `var/lib/zhiyu/initial-password.hash` in the extracted
   root. SSH continues to use public keys. With `ROOT` set to the extracted
   rootfs directory, run:

   ```sh
   sudo install -d -m 0700 "$ROOT/var/lib/zhiyu"
   sudo install -m 0600 /dev/null "$ROOT/var/lib/zhiyu/initial-password.hash"
   openssl passwd -6 | sudo tee "$ROOT/var/lib/zhiyu/initial-password.hash" >/dev/null
   ```
3. For initial deployment, use an unlocked Android bootloader. In fastboot,
   check the active slot with `fastboot getvar current-slot`. Install this set’s
   `boot.img`, `vendor_boot.img`, `init_boot.img` and `vbmeta.img` to the matching
   four partitions of the slot you have reserved for Linux. The C boot selector
   checks the kernel and vendor IDs against the generation before stage 2.
4. The first boot imports the tarball's Nix store registration records. The
   included `/etc/nixos` contains the pinned configuration. For upgrades, use
   `sudo nixos-rebuild boot --flake /etc/nixos#minimal-userdata` with the variant
   you deployed, then use the BSP's `zhiyu-install --expect-slot a|b GENERATION`
   with the resulting generation path (choose your actual slot). It supports
   `--dry-run`. Keep a known-good generation available for recovery.

The four Android partition writes are separate operations. Retain a recovery path
and preserve the matching rootfs and image set.

## Update the BSP and cache

Run `scripts/update-bsp.sh FULL_BSP_COMMIT` with a BSP commit that passed its
checks, and commit both `flake.nix` and `flake.lock`. The deployment follows the
BSP's locked nixpkgs and never resolves the BSP branch during a build.

CI keeps the official Nix cache enabled. In the test repository, set the Actions
variable `ZHIYU_BSP_CACHE_PUBLIC_KEY` to the BSP cache's public key to enable
its signed [package Release cache](https://github.com/PickaxeHit/linux-zhiyu-pkgs/releases/tag/nix-cache-index). The deployment does not publish its NixOS
store closure to the BSP cache.
