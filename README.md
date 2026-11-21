# Zhiyu Rootfs Builder

The Debian, Arch Linux ARM and Fedora workflows produce standalone root filesystems.
The NixOS deployment workflow builds a root filesystem and its four paired Android
boot images from a single pinned NixOS configuration. Download them together from
one Actions run.

## Build a NixOS deployment

On an ARM64 Nix machine with flakes enabled, run:

```sh
scripts/build-nixos.sh minimal userdata "$PWD/deploy"
(cd deploy && sha256sum --check --strict SHA256SUMS)
```

Desktop choices are `minimal`, `kde`, `gnome` and `plasmamobile`.
Storage modes are `userdata` and `sd`. The former uses the BSP to unlock Android
userdata and boot from `/data/linux`. The latter uses an ext4 filesystem on
`/dev/mmcblk0p1`. These choices are also available through the Actions manual
dispatch. An optional expected BSP revision checks the committed lock without
changing it. Test releases are opt-in in the test repository.

## Deploy a matched set

1. Check `SHA256SUMS` and confirm the storage mode in `manifest.json`. Preserve
   numeric ownership and permissions when extracting the tarball as a privileged
   user into the empty target directory or mounted microSD root. The target must
   support Unix permissions and symlinks.
2. Before booting, provision your own SSH public key under
   `etc/ssh/authorized_keys.d/operator` in the extracted root, owned by root and
   with permissions `0600`. SSH in as `operator` over a connected network.
   For desktop login, set a password interactively with `sudo passwd operator`.
3. Install the four images from this deployment using the BSP device installation
   procedure for your active slot. Flashing is explicit. The C boot selector
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
its signed `nix-repodata` endpoint. The deployment does not publish its NixOS
store closure to the BSP cache.
