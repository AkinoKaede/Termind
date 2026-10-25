#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Kaede Akino
# SPDX-License-Identifier: GPL-3.0-only

"""Prepare a temporary Apple signing environment; never print credential values."""

from __future__ import annotations

import base64
import binascii
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = {"iOS": "TFI", "macOS": "TFM"}
BUNDLE_ID = "com.akinokaede.termind"


def version_module():
    spec = importlib.util.spec_from_file_location("bump_version", ROOT / "Scripts/bump-version.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def build_matrix(version: str, platform: str) -> dict:
    version_module().parse_version(version)
    if platform not in (*PLATFORMS, "All"):
        raise ValueError("Platform must be All, iOS, or macOS")
    return {"include": [{"platform": name} for name in PLATFORMS if platform in ("All", name)]}


def required(environment: dict, name: str) -> str:
    value = environment.get(name, "")
    if not value:
        raise ValueError(f"Missing required secret: {name}")
    return value


def decode(environment: dict, name: str) -> bytes:
    try:
        return base64.b64decode("".join(required(environment, name).split()), validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError(f"Missing or invalid base64 secret: {name}") from error


def mask(value: str):
    escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::add-mask::{escaped}", flush=True)


def private_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o600)


def security(*arguments: str) -> bytes:
    # Neither argv (which may contain passwords) nor security's output belongs in CI logs.
    result = subprocess.run(["security", *map(str, arguments)], capture_output=True)
    if result.returncode:
        raise RuntimeError(f"security {arguments[0]} failed (exit {result.returncode})")
    return result.stdout


def service_configuration(environment: dict) -> tuple[bytes, bytes]:
    firebase = decode(environment, "FIREBASE_CONFIG_BASE64")
    try:
        configuration = plistlib.loads(firebase)
    except Exception as error:
        raise ValueError("FIREBASE_CONFIG_BASE64 must contain a valid plist") from error
    if not isinstance(configuration, dict) or configuration.get("BUNDLE_ID") != BUNDLE_ID:
        raise ValueError("Firebase BUNDLE_ID does not match Termind")
    for key in ("GOOGLE_APP_ID", "API_KEY", "PROJECT_ID", "GCM_SENDER_ID"):
        if not isinstance(configuration.get(key), str) or not configuration[key].strip():
            raise ValueError(f"Firebase plist is missing {key}")
    api_key = required(environment, "REVENUECAT_API_KEY")
    entitlement = required(environment, "REVENUECAT_ENTITLEMENT_ID")
    if not re.fullmatch(r"appl_[A-Za-z0-9]+", api_key):
        raise ValueError("REVENUECAT_API_KEY must be a public Apple SDK key (appl_...), not a private key")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", entitlement):
        raise ValueError("REVENUECAT_ENTITLEMENT_ID must contain only letters, digits, underscores, dots or hyphens")
    for value in configuration.values():
        if isinstance(value, str) and value:
            mask(value)
    mask(api_key)
    mask(entitlement)
    xcconfig = (
        f"REVENUECAT_API_KEY = {api_key}\n"
        f"REVENUECAT_ENTITLEMENT_ID = {entitlement}\n"
        "FIREBASE_UPLOAD_SYMBOLS = YES\n"
    ).encode()
    return firebase, xcconfig


def profile_payloads(data: bytes) -> list[tuple[str, bytes]]:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = [entry for entry in archive.infolist() if not entry.is_dir()]
        if not entries or len(entries) > 100 or sum(entry.file_size for entry in entries) > 10 * 1024 * 1024:
            raise ValueError("Provisioning profile ZIP must contain 1–100 profiles, at most 10 MiB in total")
        result = []
        for entry in entries:
            # Read bytes without extracting paths supplied by the ZIP.
            suffix = Path(entry.filename).suffix
            if suffix not in (".mobileprovision", ".provisionprofile"):
                raise ValueError("Provisioning profile ZIP may contain only Apple provisioning profiles")
            result.append((suffix, archive.read(entry)))
        return result


def is_development_profile(profile: dict) -> bool:
    if profile.get("ProvisionsAllDevices"):
        return False
    entitlements = profile.get("Entitlements", {})
    debug_keys = ("get-task-allow", "com.apple.security.get-task-allow")
    if any(key in entitlements for key in debug_keys):
        return any(entitlements.get(key) is True for key in debug_keys)
    # Xcode's Mac development profiles can omit get-task-allow. Unlike Mac App
    # Store and Developer ID profiles, they explicitly enumerate registered Macs.
    return bool(set(profile.get("Platform", [])) & {"OSX", "macOS"}) and bool(profile.get("ProvisionedDevices"))


def export_options(team: str) -> dict:
    return {
        "method": "app-store-connect",
        "destination": "upload",
        "signingStyle": "automatic",
        "teamID": team,
        "manageAppVersionAndBuildNumber": True,
        "uploadSymbols": True,
        "iCloudContainerEnvironment": "Production",
    }


def save_state(directory: Path, state: dict):
    private_write(directory / "state.json", json.dumps(state).encode())


def backup_file(path: Path, directory: Path, state: dict):
    backup = directory / "backups" / str(len(state["files"]))
    if path.exists():
        private_write(backup, path.read_bytes())
        record = {"path": str(path), "backup": str(backup), "mode": path.stat().st_mode & 0o777}
    else:
        record = {"path": str(path), "backup": None}
    state["files"].append(record)
    save_state(directory, state)


def prepare(root: Path, directory: Path, home: Path, environment: dict, *, development: bool = False):
    if (directory / "state.json").exists():
        raise ValueError("Signing directory is already in use")
    # Validate all required configuration before touching the runner's signing state.
    if development:
        certificate = decode(environment, "APPLE_DEVELOPMENT_CERTIFICATES_P12_BASE64")
        password = required(environment, "APPLE_DEVELOPMENT_CERTIFICATES_PASSWORD")
        profiles = profile_payloads(decode(environment, "APPLE_DEVELOPMENT_PROFILES_BASE64"))
        firebase = None
        xcconfig = b"REVENUECAT_API_KEY =\nREVENUECAT_ENTITLEMENT_ID = termind_pro\nFIREBASE_UPLOAD_SYMBOLS = NO\n"
    else:
        firebase, xcconfig = service_configuration(environment)
        certificate = decode(environment, "APPLE_CERTIFICATES_P12_BASE64")
        password = required(environment, "APPLE_CERTIFICATES_PASSWORD")
        profiles = profile_payloads(decode(environment, "APPLE_PROVISIONING_PROFILES_BASE64"))
        api_key = decode(environment, "ASC_KEY_BASE64")
        if not api_key.startswith(b"-----BEGIN PRIVATE KEY-----"):
            raise ValueError("ASC_KEY_BASE64 must contain an App Store Connect .p8 private key")
        key_id = required(environment, "ASC_KEY_ID")
        if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
            raise ValueError("ASC_KEY_ID must be a 10-character Apple key ID")
        try:
            issuer = str(uuid.UUID(required(environment, "ASC_ISSUER_ID")))
        except ValueError as error:
            raise ValueError("ASC_ISSUER_ID must be the team API key's issuer UUID") from error
    teams = set(re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", (root / "Termind.xcodeproj/project.pbxproj").read_text()))
    if len(teams) != 1:
        raise ValueError("Expected one DEVELOPMENT_TEAM in the Xcode project")
    team = teams.pop()
    keychain = directory / "signing.keychain-db"
    profile_directory = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    state = {
        "keychain": str(keychain),
        "keychains": shlex.split(security("list-keychains", "-d", "user").decode()),
        "profile_directory": str(profile_directory),
        "original_profiles": [str(path) for path in profile_directory.glob("*") if path.is_file()],
        "files": [],
    }
    save_state(directory, state)
    # Xcode can also download/replace profiles during automatic provisioning.
    for path in profile_directory.glob("*"):
        if path.is_file():
            backup_file(path, directory, state)
    for path, data in (
        (root / "Configuration/Firebase/GoogleService-Info.plist", firebase),
        (root / "Configuration/Services.local.xcconfig", xcconfig),
    ):
        backup_file(path, directory, state)
        if data is None:
            path.unlink(missing_ok=True)
        else:
            private_write(path, data)
    private_write(directory / "certificate.p12", certificate)
    if not development:
        private_write(directory / "AuthKey.p8", api_key)
        private_write(directory / "authentication.json", json.dumps({"key_id": key_id, "issuer": issuer}).encode())
        private_write(directory / "ExportOptions.plist", plistlib.dumps(export_options(team)))
    keychain_password = secrets.token_urlsafe(32)
    mask(keychain_password)
    security("create-keychain", "-p", keychain_password, keychain)
    security("set-keychain-settings", "-lut", "21600", keychain)
    security("unlock-keychain", "-p", keychain_password, keychain)
    security("import", directory / "certificate.p12", "-P", password, "-t", "cert", "-f", "pkcs12",
             "-k", keychain, "-T", "/usr/bin/codesign", "-T", "/usr/bin/productbuild")
    security("set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, keychain)
    security("list-keychains", "-d", "user", "-s", str(keychain), *state["keychains"])
    for suffix, data in profiles:
        temporary_profile = directory / ("profile" + suffix)
        private_write(temporary_profile, data)
        profile = plistlib.loads(security("cms", "-D", "-i", temporary_profile))
        identifier = str(uuid.UUID(profile["UUID"]))
        if team not in profile.get("TeamIdentifier", []):
            raise ValueError("Provisioning profile belongs to a different Apple team")
        if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise ValueError("Provisioning profile has expired")
        if development:
            entitlements = profile.get("Entitlements", {})
            if not is_development_profile(profile):
                raise ValueError("Development tests require development provisioning profiles, not distribution profiles")
            cloud_environments = entitlements.get("com.apple.developer.icloud-container-environment", [])
            if cloud_environments and "Development" not in cloud_environments:
                raise ValueError("Development profile does not permit the Development CloudKit environment")
        private_write(profile_directory / (identifier + suffix), data)
    print("Apple development signing is ready." if development else "Apple signing and required service configuration are ready.")


def cleanup(directory: Path):
    state_path = directory / "state.json"
    failures = []
    if state_path.exists():
        state = json.loads(state_path.read_text())
        for arguments in (
            ("list-keychains", "-d", "user", "-s", *state["keychains"]),
            ("delete-keychain", state["keychain"]),
        ):
            if arguments[0] == "delete-keychain" and not Path(state["keychain"]).exists():
                continue
            try:
                security(*arguments)
            except RuntimeError as error:
                failures.append(str(error))
        for path in Path(state["profile_directory"]).glob("*"):
            if path.is_file() and str(path) not in state["original_profiles"]:
                path.unlink()
        for record in reversed(state["files"]):
            path = Path(record["path"])
            if record["backup"] is None:
                path.unlink(missing_ok=True)
            else:
                private_write(path, Path(record["backup"]).read_bytes())
                path.chmod(record["mode"])
    # Keep recovery data when keychain restoration fails; never report false success.
    if failures:
        raise RuntimeError("; ".join(failures))
    shutil.rmtree(directory)


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "matrix":
        matrix = build_matrix(os.environ["BUILD_VERSION"], os.environ["BUILD_PLATFORM"])
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
        return
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("Signing setup and cleanup are only intended for isolated GitHub Actions runners")
    directory = Path(os.environ["APPLE_CI_DIR"]).resolve()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    if directory.parent != runner_temp or not directory.name.startswith("termind-apple."):
        raise ValueError("APPLE_CI_DIR must be a private termind-apple.* directory under RUNNER_TEMP")
    if command in ("prepare", "prepare-development"):
        prepare(ROOT, directory, Path.home(), dict(os.environ), development=command == "prepare-development")
    elif command == "cleanup":
        cleanup(directory)
    else:
        raise ValueError("Expected matrix, prepare, prepare-development, or cleanup")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not include subprocess arguments, plist contents, or a traceback with credentials.
        if isinstance(error, (ValueError, RuntimeError)):
            print(f"::error::{error}", file=sys.stderr)
        else:
            print(f"::error::Apple CI configuration failed ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
