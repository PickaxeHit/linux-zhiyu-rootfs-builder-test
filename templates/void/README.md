# Zhiyu Void repository trust

The existing BSP release public key is pinned by `repo-public.pem.sha256`. The import workflow downloads only that public key, verifies its SHA-256 digest, derives the XBPS RSA fingerprint and commits the PEM and XBPS-compatible plist. Never put the private key in this repository.

For future aarch64 glibc Void rootfs builds, install `keys/*.plist` into `/var/db/xbps/keys/` and `20-zhiyu.conf` into `/etc/xbps.d/`, before synchronizing the BSP repository. The fingerprint format follows upstream XBPS `lib/pubkey2fp.c`; the plist fields follow `lib/repo.c`. Verify the pinned digest against the owner's local public key before using it as a trust anchor. This template does not itself build a Void rootfs.
