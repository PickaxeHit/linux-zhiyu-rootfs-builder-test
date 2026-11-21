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
flake=.
if [[ -n ${ROOTFS_USERNAME:-}${ROOTFS_HOSTNAME:-} ]]; then
  source=$(mktemp -d)
  trap 'rm -rf -- "$source"' EXIT
  cp -r flake.nix flake.lock nixos "$source"
  python3 - "$source/nixos/site.json" <<'PY_CONFIG'
import json
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
site = json.loads(path.read_text())
for field in ("username", "hostname"):
    site[field] = os.environ.get(f"ROOTFS_{field.upper()}") or site[field]
if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", site["username"]) or site["username"] == "root":
    sys.exit("Invalid initial username")
if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", site["hostname"]):
    sys.exit("Invalid hostname")
path.write_text(json.dumps(site, indent=2) + "\n")
PY_CONFIG
  flake="path:$source"
fi
deployment=$(env -u PASSWORD nix build --no-link --no-update-lock-file --print-out-paths -L \
  "$flake#packages.aarch64-linux.$desktop-$mode")
python3 scripts/verify-nixos-deployment.py "$deployment" "$output"
(cd "$output" && sha256sum --check --strict SHA256SUMS)
