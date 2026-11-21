#!/usr/bin/env python3
"""Require a fixed, shared nixpkgs input and optionally an expected BSP revision."""
import json
from pathlib import Path
import re
import sys


def locked_revisions(lock):
    nodes = lock["nodes"]
    inputs = nodes[lock["root"]]["inputs"]
    if inputs.get("nixpkgs") != ["zhiyu", "nixpkgs"]:
        raise ValueError("nixpkgs must follow the BSP input")
    bsp = nodes[inputs["zhiyu"]]
    toolchain = nodes[bsp["inputs"]["nixpkgs"]]["locked"]
    locked = bsp["locked"]
    for name, entry in [("zhiyu", locked), ("nixpkgs", toolchain)]:
        if entry["type"] != "github" or not re.fullmatch(r"[0-9a-f]{40}", entry.get("rev", "")):
            raise ValueError(f"{name} must use a fixed full Git commit")
    if bsp["original"].get("rev") != locked["rev"]:
        raise ValueError("pin the BSP revision in flake.nix as well as flake.lock")
    return locked["rev"], toolchain["rev"]


if __name__ == "__main__":
    bsp, nixpkgs = locked_revisions(json.loads(Path("flake.lock").read_text()))
    if len(sys.argv) > 1 and sys.argv[1] and sys.argv[1] != bsp:
        sys.exit(f"expected BSP {sys.argv[1]}, found {bsp}; update and commit flake.lock to change it")
    print(f"BSP {bsp}, nixpkgs {nixpkgs}")
