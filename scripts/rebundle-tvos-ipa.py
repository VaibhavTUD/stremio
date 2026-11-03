#!/usr/bin/env python3
"""Give an upstream VortX tvOS IPA our own bundle identifier, ready for free-account sideloading.

Usage: rebundle-tvos-ipa.py <input.ipa> <output.ipa> --bundle-id <id>

The app's CFBundleIdentifier becomes <id>; every app extension under PlugIns/ keeps its suffix
under the new prefix (com.stremiox.tv.topshelf -> <id>.topshelf). Frameworks keep their own IDs.
The old signature and provisioning profile are removed from the app and its extensions, because
editing Info.plist invalidates them and the sideloading tool (atvloadly) signs the bundle again.
Prints a JSON summary on stdout.
"""

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def read_plist(path: Path) -> tuple[dict, plistlib.PlistFormat]:
    data = path.read_bytes()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    return plistlib.loads(data), fmt


def write_plist(path: Path, value: dict, fmt: plistlib.PlistFormat) -> None:
    path.write_bytes(plistlib.dumps(value, fmt=fmt))


def strip_signature(bundle: Path) -> None:
    shutil.rmtree(bundle / "_CodeSignature", ignore_errors=True)
    (bundle / "embedded.mobileprovision").unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args()

    new_id = args.bundle_id
    if not BUNDLE_ID_RE.match(new_id):
        fail(f"invalid bundle identifier: {new_id}")
    if not args.input.is_file():
        fail(f"input not found: {args.input}")

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        subprocess.run(["unzip", "-qq", str(args.input.resolve()), "-d", str(work)], check=True)

        apps = sorted((work / "Payload").glob("*.app"))
        if len(apps) != 1:
            fail(f"expected exactly one Payload/*.app, found {len(apps)}")
        app = apps[0]

        info_path = app / "Info.plist"
        info, fmt = read_plist(info_path)
        platforms = info.get("CFBundleSupportedPlatforms") or []
        if info.get("DTPlatformName") != "appletvos" and "AppleTVOS" not in platforms:
            fail("not a tvOS app (DTPlatformName/CFBundleSupportedPlatforms)")

        old_id = info.get("CFBundleIdentifier")
        if not old_id:
            fail("app Info.plist has no CFBundleIdentifier")
        info["CFBundleIdentifier"] = new_id
        write_plist(info_path, info, fmt)
        strip_signature(app)

        extensions = []
        for appex in sorted((app / "PlugIns").glob("*.appex")):
            ext_path = appex / "Info.plist"
            ext, ext_fmt = read_plist(ext_path)
            ext_old = ext.get("CFBundleIdentifier", "")
            if ext_old.startswith(old_id + "."):
                ext_new = new_id + ext_old[len(old_id):]
            else:
                ext_new = f"{new_id}.{appex.stem.lower()}"
            ext["CFBundleIdentifier"] = ext_new
            write_plist(ext_path, ext, ext_fmt)
            strip_signature(appex)
            extensions.append({"name": appex.name, "from": ext_old, "to": ext_new})

        args.output.parent.mkdir(parents=True, exist_ok=True)
        out = args.output.resolve()
        out.unlink(missing_ok=True)
        subprocess.run(["zip", "-qry", "-X", str(out), "Payload"], cwd=work, check=True)

    print(json.dumps({
        "app": app.name,
        "from": old_id,
        "to": new_id,
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "minimumOS": info.get("MinimumOSVersion"),
        "extensions": extensions,
    }, indent=2))


if __name__ == "__main__":
    main()
