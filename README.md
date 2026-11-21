# Zhiyu Rootfs Builder

The Debian, Arch Linux ARM and Fedora workflows produce standalone root filesystems.
Their device packages come from the [Zhiyu package repository](https://github.com/PickaxeHit/linux-zhiyu-pkgs/releases).
The NixOS deployment workflow builds a root filesystem and its four paired Android
boot images from a single generated NixOS configuration. Download them together
from one Actions run.

## Build a NixOS deployment

Use **Build Rootfs (NixOS)** in Actions to select a desktop,
initial username, hostname and password.

On an ARM64 Nix machine with flakes enabled, run:

```sh
ROOTFS_USERNAME=alice ROOTFS_HOSTNAME=zhiyu-tablet \
  scripts/build-nixos.sh minimal "$PWD/deploy"
(cd deploy && sha256sum --check --strict SHA256SUMS)
```

Desktop choices are `minimal`, `kde`, `gnome` and `plasmamobile`.
Use the same rootfs archive for Android userdata (`/data/linux`) or an
ext4 microSD rescue root. The initramfs mounts the root with the appropriate
options before starting NixOS. Stage 2 inherits the existing mount.
If Android userdata cannot be unlocked or cannot provide a bootable system,
the initramfs tries the microSD. On the rescue card it first looks for
`/sbin/init`, then tries the current or another executable NixOS generation
without requiring a Boot ID match. Rescue userspace runs with the kernel
already loaded by the device. All rootfs workflows upload their results as
Actions artifacts. The initial username is
`username`, and the initial password is `changeme` unless a different workflow input
or the `ROOTFS_PASSWORD` repository secret is set. The secret takes precedence.
NixOS defaults to hostname `nixos`. Its password hash is added to the rootfs during
packaging and is kept out of the Nix store and the manifest.

## Deploy a matched set

1. Check `SHA256SUMS` and confirm the build details in `manifest.json`. Preserve
   numeric ownership and permissions when extracting the tarball as a privileged
   user into the empty target directory or mounted microSD root. The target must
   support Unix permissions and symlinks.
2. Log in locally using the username and password selected for the build.
   Change the default password after the first login. For SSH, put your public key
   at `etc/ssh/authorized_keys.d/<username>` in the extracted root, owned by root
   with mode `0600`.
3. For initial deployment, use an unlocked Android bootloader. In fastboot,
   check the active slot with `fastboot getvar current-slot`. Install this set’s
   `boot.img`, `vendor_boot.img`, `init_boot.img` and `vbmeta.img` to the matching
   four partitions of the slot you have reserved for Linux. The C boot selector
   checks both Boot IDs on Android userdata before stage 2. When adding a
   microSD rescue root to an existing installation, extract the rootfs to the
   card and keep the installed boot images.
4. The first boot imports the tarball's Nix store registration records. The
   selected desktop, user and hostname are already set in
   `/etc/nixos/configuration.nix`. Edit this file for system changes. Both
   rebuild commands below use the same configuration and dependency versions.

   ```sh
   # Flake entry point
   sudo nixos-rebuild boot --flake /etc/nixos#zhiyu

   # Traditional entry point
   sudo nixos-rebuild boot
   ```

   Use the BSP's `zhiyu-install --expect-slot a|b GENERATION` with the resulting
   generation path and your actual slot. It supports `--dry-run`. Keep a
   known-good generation available for recovery.

The four Android partition writes are separate operations. Retain a recovery path
and preserve the matching rootfs and image set.

## BSP versions and cache

The builder repository stores templates. At the start of each build, Nix resolves
the current `main` commit of [linux-zhiyu](https://github.com/PickaxeHit/linux-zhiyu)
and follows the nixpkgs version pinned by that BSP. The generated lock stays
fixed for that build and is installed at `/etc/nixos/flake.lock` alongside
`flake.nix` and `configuration.nix`. The archive manifest records the exact
BSP and nixpkgs commits and the lock checksum.

To deliberately update an installed system's BSP and its nixpkgs input, run
`sudo nix flake update zhiyu --flake /etc/nixos`, then rebuild with the Flake
entry point. That also updates the traditional entry point's nixpkgs path
for subsequent rebuilds.

CI keeps the official Nix cache enabled. In the test repository, set the Actions
variable `ZHIYU_BSP_CACHE_PUBLIC_KEY` to the BSP cache's public key to enable
its signed [package Release cache](https://github.com/PickaxeHit/linux-zhiyu-pkgs/releases/tag/nix-cache-index). The deployment does not publish its NixOS
store closure to the BSP cache.
