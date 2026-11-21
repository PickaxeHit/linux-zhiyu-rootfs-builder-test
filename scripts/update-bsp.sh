#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=${1:?Usage: scripts/update-bsp.sh FULL_BSP_COMMIT}
[[ $revision =~ ^[0-9a-f]{40}$ ]]
python3 - "$revision" <<'PY'
import re
import sys
from pathlib import Path

flake = Path("flake.nix")
body, matches = re.subn(
    r'(inputs\.zhiyu\.url = "github:PickaxeHit/linux-zhiyu-(?:nix|next)/)[0-9a-f]{40}";',
    lambda match: match[1] + sys.argv[1] + '";',
    flake.read_text(),
)
if matches != 1:
    sys.exit("expected exactly one pinned BSP GitHub input in flake.nix")
flake.write_text(body)
PY
nix flake update zhiyu
python3 scripts/validate_nixos_lock.py "$revision"
