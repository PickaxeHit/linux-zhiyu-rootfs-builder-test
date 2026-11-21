#!/usr/bin/env python3
"""Verify a deployed closure and its matched boot images, then collect the release files."""
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
from urllib.parse import quote

from validate_nixos_lock import locked_revisions

PARTITIONS = {"boot": 96 << 20, "vendor_boot": 96 << 20, "init_boot": 8 << 20, "vbmeta": 64 << 10}


def require(condition, description):
    if not condition:
        raise ValueError(description)


def command(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return command(*args, stdout=subprocess.PIPE).stdout.strip()


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def rooted(root, path):
    """Follow Linux absolute symlinks relative to the extracted target root."""
    pending = deque(str(path).split("/"))
    parts = []
    hops = 0
    while pending:
        component = pending.popleft()
        if component in ("", "."):
            continue
        if component == "..":
            require(parts, f"path escapes target root: {path}")
            parts.pop()
            continue
        resolved = root.joinpath(*parts, component)
        if resolved.is_symlink():
            hops += 1
            require(hops <= 40, f"link loop: {path}")
            link = str(resolved.readlink())
            if link.startswith("/"):
                parts.clear()
            pending.extendleft(reversed(link.split("/")))
        else:
            parts.append(component)
    result = root.joinpath(*parts)
    require(result.exists(), f"missing target path {path}")
    return result


def extract_root(archive, root):
    root.mkdir()
    required = {
        "dev": 0o755, "proc": 0o755, "sys": 0o755, "run": 0o755,
        "etc": 0o755, "var": 0o755, "tmp": 0o1777, "root": 0o700,
        "nix/var/nix/profiles": 0o755,
    }
    # Read the archive's numeric metadata separately from extraction, which
    # can run as an unprivileged user on the CI worker.
    found = set()
    with tarfile.open(archive, "r|xz") as stream:
        for entry in stream:
            path = entry.name.removeprefix("./")
            require(entry.uid == entry.gid == 0, f"non-root archive owner: {path}")
            if path in required:
                require(entry.isdir() and entry.mode == required[path], f"bad permissions on {path}")
                found.add(path)
    require(found == set(required), "missing root filesystem directories")
    command("tar", "-xJf", archive, "--directory", root, "--same-permissions", "--no-same-owner")
    for directory, mode in required.items():
        require(stat.S_IMODE((root / directory).stat().st_mode) == mode, f"wrong extracted mode: {directory}")


def verify_store(root, system, registration):
    isolated = "local?root=" + quote(str(root), safe="/")
    with registration.open() as file:
        command("nix-store", "--store", isolated, "--load-db", stdin=file)
    expected = set(output("nix-store", "--query", "--requisites", system).splitlines())
    actual = set(output("nix-store", "--store", isolated, "--query", "--requisites", system).splitlines())
    on_disk = {"/nix/store/" + p.name for p in (root / "nix/store").iterdir() if not p.name.startswith(".")}
    require(expected == actual == on_disk, "closure differs across host, archive and restored database")
    # --load-db uses a validity export. Check NAR contents in the isolated
    # store; the validity export itself does not represent cache signatures.
    command("nix", "store", "verify", "--store", isolated, "--no-trust", "--recursive", system)
    return len(actual)


def unpack_images(deployment, images, scratch, root, system, metadata):
    tool = deployment / "android-tools/bin"
    os.environ["PATH"] = f"{tool}:{os.environ['PATH']}"
    key = deployment / "avb-test-key.pem"
    hashes = {}
    unpacked = {}
    for part, size in PARTITIONS.items():
        filename = part + ".img"
        file = images / filename
        require(file.stat().st_size == size, f"wrong partition size: {filename}")
        hashes[filename] = digest(file)
        embedded = rooted(root, f"{system}/etc/zhiyu/boot-images/{filename}")
        require(digest(embedded) == hashes[filename], f"rootfs and external {filename} differ")
        command(tool / "avbtool", "verify_image", "--key", key, "--image", file)
        if part == "vbmeta":
            continue
        unpack = scratch / part
        header = output(tool / "unpack_bootimg", "--boot_img", file, "--out", unpack)
        require(re.search(r"header version: +4$", header, re.I | re.M), f"incompatible header: {filename}")
        unpacked[part] = (unpack, header)
    manifest = dict((name, checksum) for checksum, name in
                    map(str.split, (images / "SHA256SUMS").read_text().splitlines()))
    require(hashes == manifest, "BSP image manifest does not match the image set")
    require(digest(unpacked["boot"][0] / "kernel") == digest(rooted(root, f"{system}/kernel")), "boot kernel differs")
    vendor = unpacked["vendor_boot"][0]
    require(digest(vendor / "dtb") == digest(deployment / "board.dtb"), "vendor DTB differs")
    require(digest(vendor / "vendor_ramdisk00") == digest(deployment / "initramfs.cpio.gz"), "vendor ramdisk differs")

    ids = (images / "BOOT-IDS").read_text().strip()
    require(re.fullmatch(r"[0-9a-f]{64} [0-9a-f]{64}", ids), "malformed image IDs")
    require(rooted(root, f"{system}/etc/zhiyu/boot-id").read_text().strip() == ids, "generation IDs differ")
    kernel_id, vendor_id = ids.split()
    header = unpacked["boot"][1]
    cmdline = re.search(r"^command line args: (.*)$", header, re.M)[1]
    bootconfig = (vendor / "bootconfig").read_text()
    require(f"zhiyu.kernel_id={kernel_id}" in cmdline.split(), "boot kernel ID differs")
    require(f'zhiyu.vendor_id = "{vendor_id}"' in bootconfig.splitlines(), "boot vendor ID differs")
    require(("zhiyu.root=sd" in cmdline.split()) == (metadata["rootfsMode"] == "sd"), "wrong root mode")
    return hashes, kernel_id, vendor_id, cmdline, bootconfig


def test_boot(deployment, root, system, cmdline, bootconfig, hashes):
    (root / "proc/device-tree").mkdir()
    (root / "proc/device-tree/lenovo,mainline-compatible").write_bytes(b"lenovo,zhiyu\0")
    cmd = root / "proc/cmdline"
    bootcfg = root / "proc/bootconfig"
    cmd.write_text(cmdline + " androidboot.slot_suffix=_b\n")
    bootcfg.write_text(bootconfig.rstrip() + '\nandroidboot.slot_suffix = "_b"\n')
    select = (deployment / "boot-selector", root, cmd, bootcfg)
    require(output(*select) == f"{system}/init", "boot selector chose a different generation")

    (root / "run/lock").mkdir()
    parts = root / "partitions"
    parts.mkdir()
    for part, size in PARTITIONS.items():
        for slot in ("a", "b"):
            with (parts / f"{part}_{slot}").open("wb") as file:
                file.truncate(size)
    flash = (deployment / "flasher-simulator", "--simulate", root,
             "--expect-slot", "b", rooted(root, system))
    require(output(*flash, "--dry-run").count("would write") == 4, "flasher dry run differs")
    command(*flash)
    require((root / "nix/var/nix/profiles/zhiyu-boot").readlink() == Path(system), "wrong boot pin")
    require(output(*flash).count("unchanged") == 4, "unchanged images were rewritten")
    for part in PARTITIONS:
        require(digest(parts / f"{part}_b") == hashes[f"{part}.img"], f"bad flash readback for {part}")
        with (parts / f"{part}_a").open("rb") as file:
            require(file.read(4096) == bytes(4096), "inactive slot was touched")
    require(output(*select) == f"{system}/init", "flashed generation cannot be selected")


def verify(deployment, destination):
    metadata = json.loads((deployment / "metadata.json").read_text())
    system = metadata["systemPath"]
    require((deployment / "system").readlink() == Path(system), "exported toplevel differs")
    lock = Path("flake.lock")
    require((metadata["bspRevision"], metadata["nixpkgsRevision"]) ==
            locked_revisions(json.loads(lock.read_text())), "runtime revision differs from flake.lock")
    archive, = deployment.glob("nixos-zhiyu-*-rootfs.tar.xz")
    images = deployment / "images"
    with TemporaryDirectory(prefix="zhiyu-deployment-") as tmp:
        scratch = Path(tmp)
        root = scratch / "root"
        extract_root(archive, root)
        profile = rooted(root, "/nix/var/nix/profiles/system")
        require(profile == rooted(root, system), "target profile does not resolve to the shipped generation")
        init = rooted(root, f"{system}/init")
        require(os.access(init, os.X_OK), "stage 2 init is not executable")
        require("/build/" not in init.read_text(), "stage 2 references a temporary build directory")
        require(rooted(root, "/etc/nixos/flake.lock").read_bytes() == lock.read_bytes(), "deployed lock differs")
        moddir = rooted(root, f"{system}/kernel-modules/lib/modules/{metadata['modDirVersion']}")
        require(any(moddir.rglob("*.ko*")), "kernel modules absent")
        require(set(p.name for p in moddir.parent.iterdir()) == {metadata["modDirVersion"]}, "unexpected module versions")
        count = verify_store(root, system, root / "nix-path-registration")
        hashes, kid, vid, cmdline, bootconfig = unpack_images(deployment, images, scratch, root, system, metadata)
        test_boot(deployment, root, system, cmdline, bootconfig, hashes)

    destination.mkdir(parents=True)
    shutil.copyfile(archive, destination / archive.name)
    for filename in hashes:
        shutil.copyfile(images / filename, destination / filename)
    hashes[archive.name] = digest(destination / archive.name)
    manifest = metadata | {
        "builderRevision": output("git", "rev-parse", "HEAD"),
        "flakeLockSha256": digest(lock),
        "kernelId": kid,
        "vendorId": vid,
        "bootImageSetVersion": digest(images / "SHA256SUMS"),
        "files": hashes,
        "nixStoreClosurePaths": count,
        "builtAt": datetime.now(timezone.utc).isoformat(),
        "ciRunId": os.getenv("GITHUB_RUN_ID"),
    }
    path = destination / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    hashes[path.name] = digest(path)
    (destination / "SHA256SUMS").write_text("".join(f"{sha}  {name}\n" for name, sha in sorted(hashes.items())))
    print(f"Verified {count} registered store paths and the matching four AVB images")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Deployment verification failed: {error}")
