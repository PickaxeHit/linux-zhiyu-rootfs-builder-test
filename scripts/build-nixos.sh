#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
desktop=${1:-minimal}
output=${2:-deploy}
configuration=${3:-flake}
test ! -e "$output"
source=$(mktemp -d)
trap 'rm -rf -- "$source"' EXIT

python3 scripts/generate-nixos-config.py "$desktop" "$source" --configuration "$configuration"
env -u PASSWORD nix flake lock --refresh "path:$source/config"
python3 scripts/validate_nixos_lock.py "$source/config/flake.lock"

printf 'NixOS entry point: %s\n' "$configuration"
if [[ ${ZHIYU_REQUIRE_CAMERA_CACHE:-0} == 1 ]]; then
  # Resolve the official consumers and the BSP fork from signed caches before
  # NixOS's closure rewriter starts building the unmodified system.
  if ! env -u PASSWORD nix build --no-link --max-jobs 0 --builders "" \
    --option narinfo-cache-negative-ttl 0 --impure --file "$source/build.nix" cameraCachePaths; then
    echo "A required camera or PipeWire path could not be downloaded from the signed caches." >&2
    exit 1
  fi
fi
test "$(env -u PASSWORD nix eval --impure --file "$source/build.nix" inheritsRootMount)" = true

deployment=$(env -u PASSWORD nix build --no-link --impure --file "$source/build.nix" \
  --print-out-paths -L deployment)
python3 scripts/verify-nixos-deployment.py "$deployment" "$output" "$source"
(cd "$output" && sha256sum --check --strict SHA256SUMS)
