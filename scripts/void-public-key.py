#!/usr/bin/env python3
"""Convert the configured RSA public key to XBPS's trusted-key plist format."""
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

out = Path(sys.argv[1])
raw = os.environ.get("ZHIYU_BSP_VOID_PUBLIC_KEY", "").strip()
if not raw.startswith("-----BEGIN PUBLIC KEY-----") or not raw.endswith("-----END PUBLIC KEY-----"):
    raise SystemExit("ZHIYU_BSP_VOID_PUBLIC_KEY must contain a PEM public key, not a private key")
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / "key.pem"
    p.write_text(raw + "\n")
    pem = subprocess.check_output(["openssl", "pkey", "-pubin", "-in", str(p), "-pubout"])
    p.write_bytes(pem)
    ssh = subprocess.check_output(["ssh-keygen", "-i", "-m", "PKCS8", "-f", str(p)])
    if not ssh.startswith(b"ssh-rsa "):
        raise SystemExit("XBPS requires an RSA public key")
    s = Path(tmp) / "key.ssh"
    s.write_bytes(ssh)
    bits, fp, *_ = subprocess.check_output(
        ["ssh-keygen", "-E", "md5", "-lf", str(s)], text=True
    ).split()
    fingerprint = fp.removeprefix("MD5:")
    if int(bits) < 2048 or not re.fullmatch(r"(?:[0-9a-f]{2}:){15}[0-9a-f]{2}", fingerprint):
        raise SystemExit("Invalid XBPS RSA key or fingerprint")
    out.mkdir(parents=True, exist_ok=True)
    (out / (fingerprint + ".plist")).write_bytes(plistlib.dumps({
        "public-key": pem,
        "public-key-size": int(bits),
        "signature-by": "Zhiyu Void BSP test",
    }))
    print("Trusted XBPS RSA fingerprint:", fingerprint)
