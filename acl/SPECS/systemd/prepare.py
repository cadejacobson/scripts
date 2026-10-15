#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Derive ACL's temporary systemd 255 backport from Azure Linux packaging."""

import argparse
from pathlib import Path
import re
import shutil


PATCHES = (
    "163a0e6097b68f2699931a87c49b1c6a8903606e.patch",
    "1b7aa998ae358d4af66d490d35ca448378650f60.patch",
)


def prepare(upstream: Path, output: Path) -> None:
    if upstream.resolve() == output.resolve():
        raise ValueError("Upstream and output directories must be different")

    spec = (upstream / "systemd.spec").read_text()
    version = re.search(r"^Version:[ \t]+(\S+)", spec, re.MULTILINE)
    if version is None or version[1] != "255":
        raise ValueError(
            "This backport supports only systemd 255; remove it when upgrading "
            "to systemd 256 or newer"
        )

    patch_numbers = {
        int(number) for number in re.findall(r"^Patch(\d+):", spec, re.MULTILINE)
    }
    if patch_numbers.intersection((493, 494)):
        raise ValueError("Upstream patch number 493 or 494 is already in use")

    setup = re.findall(r"^%autosetup[ \t]+(.+)$", spec, re.MULTILINE)
    if len(setup) != 1 or "-p1" not in setup[0].split() or "-N" in setup[0].split():
        raise ValueError("Expected %autosetup with -p1 and automatic patch application")

    spec, replacements = re.subn(
        r"^Release:([ \t]+)(\d+)%\{\?dist\}[ \t]*$",
        r"Release:\g<1>\g<2>%{?dist}.acl1",
        spec,
        flags=re.MULTILINE,
    )
    if replacements != 1:
        raise ValueError("Expected one numeric Release followed by %{?dist}")

    anchor = "# Patches for Azure Linux\n"
    if spec.count(anchor) != 1:
        raise ValueError("Expected one '# Patches for Azure Linux' section")
    backports = (
        "# ACL: Remove these backports when upgrading to systemd 256 or newer.\n"
        "# Fix duplicate initrd journal entries after flushing to persistent storage:\n"
        "# https://github.com/systemd/systemd/commit/"
        "1b7aa998ae358d4af66d490d35ca448378650f60\n"
        f"Patch0493:      {PATCHES[0]}\n"
        f"Patch0494:      {PATCHES[1]}\n\n"
    )
    spec = spec.replace(anchor, backports + anchor)

    patch_dir = Path(__file__).resolve().parent
    for name in PATCHES:
        if not (patch_dir / name).is_file():
            raise FileNotFoundError(f"Missing ACL backport: {patch_dir / name}")

    shutil.copytree(upstream, output, dirs_exist_ok=True)
    for name in PATCHES:
        shutil.copy2(patch_dir / name, output / name)
    (output / "systemd.spec").write_text(spec)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path, help="Azure Linux SPECS/systemd directory")
    parser.add_argument("output", type=Path, help="Generated SPECS/systemd directory")
    args = parser.parse_args()
    try:
        prepare(args.upstream, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"ERROR: Cannot prepare ACL systemd package: {error}\n")


if __name__ == "__main__":
    main()
