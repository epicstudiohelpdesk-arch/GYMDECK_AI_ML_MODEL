#!/usr/bin/env python3
"""Print the emulator and system-image versions an emulator snapshot depends on.

android-emulator-runner installs the newest stable emulator and system image on
every run. A cached boot snapshot only loads in the versions that created it, so
the CI cache key names both: when Google ships an update, the key changes and a
fresh snapshot is created instead of the emulator silently cold-booting.

    sdkmanager --list --channel=0 | emulator_cache_key.py --image 'system-images;android-36;google_apis;x86_64'

Writes `emulator=<version>` and `system_image=<revision>` to $GITHUB_OUTPUT (and
stdout). Fails when either package is missing from "Available Packages".
"""
from __future__ import annotations

import argparse
import os
import re
import sys

VERSION = re.compile(r"[0-9]+(\.[0-9]+)*")


def available_packages(listing: str) -> dict[str, str]:
    """Package path -> version from the "Available Packages:" section of `sdkmanager --list`."""
    packages: dict[str, str] = {}
    section = ""
    for line in listing.splitlines():
        stripped = line.strip()
        if stripped.endswith(":") and "|" not in stripped:
            section = stripped[:-1].strip().lower()
            continue
        if section != "available packages" or "|" not in line:
            continue
        cells = [cell.strip() for cell in line.split("|")]
        path, version = cells[0], cells[1] if len(cells) > 1 else ""
        if not path or path == "Path" or set(path) <= {"-"}:
            continue
        packages[path] = version
    return packages


def snapshot_versions(listing: str, image: str) -> dict[str, str]:
    packages = available_packages(listing)
    found = {"emulator": packages.get("emulator", ""), "system_image": packages.get(image, "")}
    for name, value in found.items():
        if not VERSION.fullmatch(value):
            raise SystemExit(
                f"error: no usable {name} version for the emulator cache key "
                f"(got {value!r}; is {image if name == 'system_image' else 'emulator'} available?)"
            )
    return found


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--image", required=True, help="system image package path")
    args = parser.parse_args(argv)
    versions = snapshot_versions(sys.stdin.read(), args.image)
    lines = [f"{key}={value}" for key, value in versions.items()]
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
