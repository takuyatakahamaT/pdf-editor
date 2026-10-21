#!/usr/bin/env python3
"""No-secret CI checks using RFC 8032 section 7.1 public test vectors."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_KEY = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f"
    "b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
)


def verify(plist, appcast, archive, expected):
    result = subprocess.run(
        ["swift", str(ROOT / "scripts/verify-release.swift"), str(plist), str(appcast), str(archive)],
        capture_output=True, text=True, cwd=ROOT,
    )
    if (result.returncode == 0) != expected:
        raise SystemExit(f"署名受入の結果が不正です: {result.stdout}{result.stderr}")


with tempfile.TemporaryDirectory(prefix="pdf-editor-update-check-") as directory:
    folder = Path(directory)
    plist, appcast, archive = (folder / name for name in ("Info.plist", "appcast.xml", "update.zip"))
    plist.write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(PUBLIC_KEY).decode()}))
    signature = base64.b64encode(SIGNATURE).decode()
    xml = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
           f'<channel><item><enclosure length="0" sparkle:edSignature="{signature}"/>'
           '</item></channel></rss>')
    appcast.write_text(xml)
    archive.write_bytes(b"")
    verify(plist, appcast, archive, True)
    appcast.write_text(xml.replace(signature, base64.b64encode(bytes([SIGNATURE[0] ^ 1]) + SIGNATURE[1:]).decode()))
    verify(plist, appcast, archive, False)  # Same payload length, invalid signature.
    appcast.write_text(xml)
    archive.write_bytes(b"tampered")
    verify(plist, appcast, archive, False)
    archive.write_bytes(b"")
    appcast.write_text(xml.replace(f' sparkle:edSignature="{signature}"', ""))
    verify(plist, appcast, archive, False)

# Publishing must stop before build/network/keychain work if signing is unset.
environment = dict(os.environ)
environment.pop("SPARKLE_PRIVATE_KEY", None)
environment.update(GITHUB_REF="refs/heads/main", GITHUB_REPOSITORY="takuyatakahamaT/pdf-editor")
result = subprocess.run(["bash", "scripts/publish-release.sh"], cwd=ROOT, env=environment, capture_output=True, text=True)
if result.returncode == 0 or "SPARKLE_PRIVATE_KEY" not in result.stderr:
    raise SystemExit("署名鍵未設定時に配布を停止しませんでした。")
print("更新セキュリティ受入: 正常署名、不正署名、改変、署名欠落、鍵未設定の5条件が通過しました。")
