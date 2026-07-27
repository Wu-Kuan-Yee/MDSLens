#!/usr/bin/env python3
"""Combine MDSLens architecture MSIX packages into one unsigned bundle."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def find_makeappx(requested: str) -> str | None:
    explicit = Path(requested).expanduser()
    if explicit.is_file():
        return str(explicit)
    found = shutil.which(requested)
    if found is not None:
        return found

    program_files = Path(os.environ.get("ProgramFiles", "C:/Program Files"))
    program_files_x86 = Path(
        os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")
    )
    candidates: list[Path] = []
    for root in (program_files_x86, program_files):
        candidates.extend(
            (root / "Windows Kits/10/bin").glob("*/x64/makeappx.exe")
        )
    return str(sorted(candidates, reverse=True)[0]) if candidates else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("packages", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--makeappx", default="makeappx")
    args = parser.parse_args()

    packages = sorted(args.packages.glob("mdslens-windows-*.msix"))
    if {path.stem.rsplit("-", 1)[-1] for path in packages} != {"x64", "arm64"}:
        raise SystemExit(
            "Expected exactly the x64 and arm64 MDSLens MSIX packages in "
            f"{args.packages}"
        )
    executable = find_makeappx(args.makeappx)
    if executable is None:
        raise SystemExit(f"MakeAppx was not found: {args.makeappx}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mdslens-msixbundle-") as temporary:
        staging = Path(temporary)
        for package in packages:
            shutil.copy2(package, staging / package.name)
        subprocess.run(
            [
                executable,
                "bundle",
                "/o",
                "/d",
                str(staging),
                "/p",
                str(args.output),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
