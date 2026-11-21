#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
desktop=${1:-minimal}
output=${2:-deploy}
test ! -e "$output"
source=$(mktemp -d)
trap 'rm -rf -- "$source"' EXIT

python3 scripts/generate-nixos-config.py "$desktop" "$source"
env -u PASSWORD nix flake lock --refresh "path:$source/config"
python3 scripts/validate_nixos_lock.py "$source/config/flake.lock"

# Check both entry points against the same locked Nixpkgs and generated config.
flake="path:$source/config"
# Use the registry entry that will be installed on the target.
env -u PASSWORD nix eval --json --no-update-lock-file \
  "$flake#nixosConfigurations.zhiyu.config.nix.registry.nixpkgs" \
  --apply 'entry: { version = 2; flakes = [{ inherit (entry) from to; }]; }' > "$source/registry.json"
classic=$(env -u PASSWORD \
  NIX_PATH="nixpkgs=flake:nixpkgs:nixos-config=$source/config/configuration.nix" \
  nix-instantiate '<nixpkgs/nixos>' --no-gc-warning \
  --option flake-registry "file://$source/registry.json" -A system)
modern=$(env -u PASSWORD nix eval --raw --no-update-lock-file \
  "$flake#nixosConfigurations.zhiyu.config.system.build.toplevel.drvPath")
if [[ "$classic" != "$modern" ]]; then
  printf 'Classic and Flake entry points evaluated to different systems:\n%s\n%s\n' "$classic" "$modern" >&2
  exit 1
fi
test "$(env -u PASSWORD nix eval --impure --file "$source/build.nix" inheritsRootMount)" = true

deployment=$(env -u PASSWORD nix build --no-link --impure --file "$source/build.nix" \
  --print-out-paths -L deployment)
python3 scripts/verify-nixos-deployment.py "$deployment" "$output" "$source" "$modern"
(cd "$output" && sha256sum --check --strict SHA256SUMS)
