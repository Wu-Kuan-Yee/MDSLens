#!/usr/bin/env python3
"""Combine MdsScope architecture MSIX packages into one unsigned bundle."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("packages", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--makeappx", default="makeappx")
    args = parser.parse_args()

    packages = sorted(args.packages.glob("mdsscope-windows-*.msix"))
    if {path.stem.rsplit("-", 1)[-1] for path in packages} != {"x64", "arm64"}:
        raise SystemExit(
            "Expected exactly the x64 and arm64 MdsScope MSIX packages in "
            f"{args.packages}"
        )
    executable = shutil.which(args.makeappx)
    if executable is None:
        raise SystemExit(f"MakeAppx was not found: {args.makeappx}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mdsscope-msixbundle-") as temporary:
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
