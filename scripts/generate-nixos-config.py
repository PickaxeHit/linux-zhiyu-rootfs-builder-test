#!/usr/bin/env python3
"""Generate the installable NixOS configuration before resolving its inputs."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil


DESKTOPS = {
    "minimal": (),
    "kde": ("audio", "kde"),
    "gnome": ("audio", "gnome"),
    "plasmamobile": ("audio", "kde", "plasmamobile"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("desktop", choices=DESKTOPS)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--configuration", choices=("flake", "configuration.nix"), default="flake")
    args = parser.parse_args()
    username = os.environ.get("ROOTFS_USERNAME") or "username"
    hostname = os.environ.get("ROOTFS_HOSTNAME") or "nixos"
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username) or username == "root":
        parser.error("invalid initial username")
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", hostname):
        parser.error("invalid hostname")

    templates = Path(__file__).resolve().parents[1] / "templates/nixos"
    config = args.directory / "config"
    config.mkdir()
    desktop = "".join(
        (templates / "desktops" / f"{name}.nix.inc").read_text()
        for name in DESKTOPS[args.desktop]
    ).rstrip()
    body = (templates / "configuration.nix.in").read_text()
    body = body.replace("@USERNAME@", json.dumps(username))
    body = body.replace("@HOSTNAME@", json.dumps(hostname))
    body = body.replace("@DESKTOP@\n", desktop + "\n" if desktop else "")
    (config / "configuration.nix").write_text(body)
    shutil.copyfile(templates / "flake.nix", config / "flake.nix")
    for name in ("build.nix", "deployment.nix"):
        shutil.copyfile(templates / name, args.directory / name)
    (args.directory / "settings.json").write_text(
        json.dumps({
            "desktop": args.desktop,
            "configuration": args.configuration,
            "username": username,
            "hostname": hostname,
        }) + "\n"
    )


if __name__ == "__main__":
    main()
