#!/usr/bin/env python3
"""Regenerate bundled host SVGs from explicit npm releases, never moving tags."""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Frameworks/Resources"


def package(name, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[\w.-]+)?", version):
        raise ValueError("An explicit release version is required")
    with urllib.request.urlopen(f"https://registry.npmjs.org/{name}/{version}", timeout=30) as response:
        metadata = json.load(response)
    with urllib.request.urlopen(metadata["dist"]["tarball"], timeout=60) as response:
        data = response.read()
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
    if metadata["version"] != version or integrity != metadata["dist"]["integrity"]:
        raise ValueError(f"Package integrity mismatch: {name}")
    archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    return archive, {"package": name, "version": version, "integrity": integrity}


def read(archive, path):
    return archive.extractfile("package/" + path).read()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def write_icon(directory, asset, svg):
    text = svg.decode()
    root = ET.fromstring(text)
    if root.tag != "{http://www.w3.org/2000/svg}svg":
        raise ValueError(f"Expected an SVG document: {asset}")
    if re.search(r"<script|<foreignObject|<image|javascript:|(?:xlink:)?href\s*=", text, re.I):
        raise ValueError(f"Unsafe SVG: {asset}")
    # Asset catalogs rasterize standalone SVGs without a CSS currentColor context.
    text = text.replace("currentColor", "#000000")
    imageset = directory / (asset + ".imageset")
    imageset.mkdir()
    (imageset / (asset + ".svg")).write_text(text)
    write_json(imageset / "Contents.json", {
        "images": [{"filename": asset + ".svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simple-icons-version", default="16.29.0")
    parser.add_argument("--tabler-version", default="3.49.0")
    args = parser.parse_args()
    simple, simple_source = package("simple-icons", args.simple_icons_version)
    tabler, tabler_source = package("@tabler/icons", args.tabler_version)
    simple_source["source"] = "https://github.com/simple-icons/simple-icons"
    tabler_source["source"] = "https://github.com/tabler/tabler-icons"
    metadata = {entry["title"]: entry for entry in json.loads(read(simple, "data/simple-icons.json"))}
    requested = json.loads((ROOT / "Configuration/HostIcons/linux-distribution-icons.json").read_text())
    requested.append({"title": "macOS", "slug": "macos", "ids": ["macos"], "id": "macos"})
    for title, slug, ids in [
        ("BSD", "bsd", ["bsd", "dragonfly"]),
        ("FreeBSD", "freebsd", ["freebsd"]),
        ("OpenBSD", "openbsd", ["openbsd"]),
        ("NetBSD", "netbsd", ["netbsd"]),
        ("Linux", "linux", ["linux"]),
    ]:
        requested.append({"title": title, "slug": slug, "ids": ids, "id": slug})
    with tempfile.TemporaryDirectory(prefix="termind-host-icons-") as temporary:
        stage = Path(temporary)
        assets = stage / "assets"
        licenses = stage / "licenses"
        assets.mkdir()
        licenses.mkdir()
        write_json(assets / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        entries = []
        for item in requested:
            info = metadata[item["title"]]
            asset = "HostOS-" + item["id"] if "id" in item else "LinuxDistro-" + item["slug"]
            write_icon(assets, asset, read(simple, "icons/" + item["slug"] + ".svg"))
            entries.append({
                "id": item.get("id", item["slug"]), "title": item["title"],
                "asset": asset, "ids": item["ids"], "hex": info["hex"], "slug": item["slug"],
                "sourceURL": info["source"], "license": info.get("license", {}).get("type"),
                "package": "simple-icons",
            })
        write_icon(assets, "HostOS-windows", read(tabler, "icons/filled/brand-windows.svg"))
        entries.append({
            "id": "windows", "title": "Windows", "asset": "HostOS-windows", "ids": ["windows"],
            "hex": "0078D4", "colorSource": "Termind presentation choice",
            "sourceURL": f"https://github.com/tabler/tabler-icons/blob/v{args.tabler_version}/icons/filled/brand-windows.svg",
            "license": "MIT", "package": "@tabler/icons",
        })
        for filename in ["LICENSE.md", "DISCLAIMER.md"]:
            (licenses / ("SimpleIcons." + filename)).write_bytes(read(simple, filename))
        (licenses / "Tabler.LICENSE").write_bytes(read(tabler, "LICENSE"))
        write_json(stage / "HostIcons.json", {"sources": [simple_source, tabler_source], "entries": entries})
        # Validate every input before replacing any generated output.
        destination = RESOURCES / "Assets.xcassets/LinuxDistributions"
        shutil.rmtree(destination)
        shutil.copytree(assets, destination)
        license_destination = RESOURCES / "HostIcons"
        if license_destination.exists():
            shutil.rmtree(license_destination)
        shutil.copytree(licenses, license_destination)
        shutil.copyfile(stage / "HostIcons.json", RESOURCES / "HostIcons.json")
    print(f"Generated {len(entries)} host icons.")


if __name__ == "__main__":
    main()
