#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
desktop=${1:-minimal}
mode=${2:-userdata}
output=${3:-deploy}
expected_bsp=${4:-}
case "$desktop" in minimal|kde|gnome|plasmamobile) ;; *) exit 2 ;; esac
case "$mode" in userdata|sd) ;; *) exit 2 ;; esac
test ! -e "$output"
python3 scripts/validate_nixos_lock.py "$expected_bsp"
deployment=$(nix build --no-link --no-update-lock-file --print-out-paths -L \
  ".#packages.aarch64-linux.$desktop-$mode")
python3 scripts/verify-nixos-deployment.py "$deployment" "$output"
(cd "$output" && sha256sum --check --strict SHA256SUMS)
