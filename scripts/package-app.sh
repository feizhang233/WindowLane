#!/bin/bash
set -euo pipefail

# Package an already-built, already-tested app. This script never builds, signs,
# launches an application, or requests system permissions.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$PROJECT_DIR" <<'PY'
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
app = root / "dist" / "WindowLane.app"
verification = root / "verification"
manifest_path = verification / "build-manifest.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_passing_report(filename):
    path = verification / filename
    with path.open("r", encoding="utf-8") as stream:
        report = json.load(stream)
    if report.get("passed") is not True:
        raise RuntimeError(f"Refusing to package: {filename} has not passed.")
    checks = report.get("checks")
    if not isinstance(checks, list) or not checks:
        raise RuntimeError(f"Refusing to package: {filename} has no test checks.")
    if any(not isinstance(check, dict) or check.get("passed") is not True for check in checks):
        raise RuntimeError(f"Refusing to package: {filename} includes a failing test check.")
    completed = report.get("completedAt")
    if not isinstance(completed, str):
        raise RuntimeError(f"Refusing to package: {filename} has no completion time.")
    datetime.datetime.fromisoformat(completed.replace("Z", "+00:00"))
    return {
        "path": path.relative_to(root).as_posix(),
        "scope": report.get("scope"),
        "completedAt": completed,
        "passed": True,
        "count": len(checks),
        "sha256": sha256(path),
    }


def source_inventory():
    files = [root / "Package.swift"]
    for directory in ("Sources", "Tests", "Resources", "scripts"):
        base = root / directory
        if base.exists():
            files.extend(
                path for path in base.rglob("*")
                if path.is_file()
                and not any(part.startswith(".") for part in path.relative_to(base).parts)
            )
    inventory = [
        {"path": path.relative_to(root).as_posix(), "sha256": sha256(path)}
        for path in sorted(set(files), key=lambda path: path.relative_to(root).as_posix())
    ]
    # Canonical aggregate format: UTF-8 relative path, NUL, lowercase file hash, LF.
    aggregate = hashlib.sha256()
    for item in inventory:
        aggregate.update((item["path"] + "\0" + item["sha256"] + "\n").encode("utf-8"))
    return {
        "algorithm": "SHA-256",
        "aggregateFormat": "UTF-8 relative path + NUL + lowercase SHA-256 + LF, sorted by path",
        "sha256": aggregate.hexdigest(),
        "files": inventory,
    }


def main():
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info.get("CFBundleShortVersionString")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise RuntimeError("The app has an invalid version string.")
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise RuntimeError("The app has an invalid executable name.")
    executable = app / "Contents" / "MacOS" / executable_name
    architecture = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", str(executable)], text=True
    ).strip()
    if architecture != "arm64":
        raise RuntimeError(f"Expected the arm64 release app; found architecture: {architecture!r}")

    native_report = load_passing_report("native-smoke.json")
    external_report = load_passing_report("external-smoke.json")
    background_report = load_passing_report("background-smoke.json")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
    executable_hash = sha256(executable)
    sources = source_inventory()
    archive = root / "dist" / f"WindowLane-{version}-{architecture}.zip"

    # Validate a new archive before replacing a previous packaged release.
    with tempfile.TemporaryDirectory(prefix=".windowlane-package-", dir=archive.parent) as scratch:
        temporary_archive = Path(scratch) / archive.name
        subprocess.run(
            ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(temporary_archive)],
            check=True,
        )
        archive_check = subprocess.run(
            ["/usr/bin/unzip", "-t", str(temporary_archive)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        if sha256(executable) != executable_hash:
            raise RuntimeError("The app executable changed during packaging; rerun tests and package again.")
        archive_hash = sha256(temporary_archive)
        os.replace(temporary_archive, archive)
        print(archive_check.stdout.strip().splitlines()[-1])

    manifest = {
        "schemaVersion": 1,
        "appVersion": version,
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "architecture": architecture,
        "appPath": app.relative_to(root).as_posix(),
        "executablePath": executable.relative_to(root).as_posix(),
        "executableSHA256": executable_hash,
        "zipPath": archive.relative_to(root).as_posix(),
        "zipSHA256": archive_hash,
        "createdAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "nativeReport": native_report,
        "externalReport": external_report,
        "backgroundReport": background_report,
        "sourcesHash": sources,
    }
    verification.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".build-manifest-", suffix=".json", dir=verification, delete=False) as stream:
        temporary_manifest = Path(stream.name)
        try:
            json.dump(manifest, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
        except BaseException:
            temporary_manifest.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary_manifest, manifest_path)
    finally:
        temporary_manifest.unlink(missing_ok=True)
    print(f"Packaged: {archive}")
    print(f"Manifest: {manifest_path}")


try:
    main()
except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
    print(f"Packaging failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
