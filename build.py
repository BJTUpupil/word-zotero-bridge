"""Build and verify the deterministic Zotero XPI and its HTTPS update manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
MANIFEST_PATH = ROOT / "manifest.json"
UPDATES_PATH = ROOT / "updates.json"
PACKAGE_FILES = ("manifest.json", "bootstrap.js", "bridge.js", "batch-policy.js")
REPOSITORY_RAW = "https://raw.githubusercontent.com/BJTUpupil/word-zotero-bridge/main"


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def validate_manifest(manifest: dict) -> tuple[str, str]:
    zotero = manifest["applications"]["zotero"]
    addon_id = zotero["id"]
    version = manifest["version"]
    expected_update_url = f"{REPOSITORY_RAW}/updates.json"
    if zotero.get("update_url") != expected_update_url:
        raise SystemExit(f"manifest update_url must be {expected_update_url}")
    if zotero.get("strict_min_version") != "9.0.6" or zotero.get("strict_max_version") != "9.0.6":
        raise SystemExit("This release is intentionally restricted to Zotero 9.0.6")
    return addon_id, version


def build() -> tuple[Path, str]:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    addon_id, version = validate_manifest(manifest)
    DIST.mkdir(exist_ok=True)
    output = DIST / f"word-zotero-bridge-{version}.xpi"
    if output.exists():
        output.unlink()
    timestamp = (2026, 9, 5, 0, 0, 0)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in PACKAGE_FILES:
            info = zipfile.ZipInfo(name, timestamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, (ROOT / name).read_bytes())
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise SystemExit("XPI integrity check failed")
        if tuple(archive.namelist()) != PACKAGE_FILES:
            raise SystemExit("Unexpected XPI contents")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    updates = {
        "addons": {
            addon_id: {
                "updates": [
                    {
                        "version": version,
                        "update_link": f"{REPOSITORY_RAW}/dist/{output.name}",
                        "update_hash": f"sha256:{digest}",
                        "applications": {
                            "zotero": {
                                "strict_min_version": "9.0.6",
                                "strict_max_version": "9.0.6",
                            }
                        },
                    }
                ]
            }
        }
    }
    UPDATES_PATH.write_text(canonical_json(updates), encoding="utf-8")
    return output, digest


def check() -> None:
    before_updates = UPDATES_PATH.read_bytes() if UPDATES_PATH.exists() else None
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    _, version = validate_manifest(manifest)
    output = DIST / f"word-zotero-bridge-{version}.xpi"
    before_xpi = output.read_bytes() if output.exists() else None
    built, _ = build()
    if before_updates is None or before_xpi is None:
        raise SystemExit("Run build.py before build.py --check")
    if UPDATES_PATH.read_bytes() != before_updates or built.read_bytes() != before_xpi:
        raise SystemExit("Generated release files are stale")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify committed release files are reproducible")
    args = parser.parse_args()
    if args.check:
        check()
        print("Release files are reproducible.")
    else:
        package, sha256 = build()
        print(package)
        print("SHA256", sha256)
