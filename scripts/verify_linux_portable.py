#!/usr/bin/env python3
"""Verify that a Linux portable archive is self-contained above glibc."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path


SYSTEM_RUNTIME = re.compile(
    r"(?:ld-linux[^/]*|libc|libdl|libm|libpthread|libresolv|librt|"
    r"libutil|libanl|libnss_[^.]+)\.so(?:\..*)?"
)


def is_elf(path: Path) -> bool:
    try:
        if not path.is_file():
            return False
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def extract(archive: Path, destination: Path) -> Path:
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
            # zipfile deliberately does not restore Unix permissions during
            # extraction, even though make_archive stores them in external_attr.
            # Reapply the archived mode so launchability is verified rather
            # than the extractor's default 0644 mode.
            for member in source.infolist():
                if member.create_system != 3:
                    continue
                mode = (member.external_attr >> 16) & 0o7777
                extracted = destination / member.filename
                if mode and extracted.exists():
                    extracted.chmod(mode)
    else:
        shutil.unpack_archive(archive, destination)
    roots = [path for path in destination.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise RuntimeError(f"Expected one archive root, found {len(roots)}")
    return roots[0]


def dependencies(binary: Path, library_dir: Path) -> list[Path]:
    environment = dict(os.environ)
    environment["LD_LIBRARY_PATH"] = str(library_dir)
    result = subprocess.run(
        ["ldd", str(binary)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
    )
    if "=> not found" in result.stdout:
        raise RuntimeError(f"Unresolved dependency for {binary}:\n{result.stdout}")
    paths: list[Path] = []
    for line in result.stdout.splitlines():
        match = re.search(r"=>\s+(/[^\s]+)", line)
        if match is None:
            match = re.match(r"\s*(/[^\s]+)\s+\(", line)
        if match is not None:
            paths.append(Path(match.group(1)).resolve())
    return paths


def glibc_versions(binary: Path) -> set[tuple[int, int]]:
    result = subprocess.run(
        ["readelf", "--version-info", str(binary)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return {
        (int(major), int(minor))
        for major, minor in re.findall(r"GLIBC_(\d+)\.(\d+)", result.stdout)
    }


def verify(root: Path, maximum_glibc: tuple[int, int], launch: bool) -> None:
    launcher = root / "mdsscope"
    executable = root / "mdsscope.bin"
    library_dir = root / "lib"
    for required in (launcher, executable, library_dir):
        if not required.exists():
            raise RuntimeError(f"Portable bundle is missing {required.relative_to(root)}")
    if not os.access(launcher, os.X_OK):
        raise RuntimeError("Portable launcher is not executable")

    binaries = [path for path in root.rglob("*") if is_elf(path)]
    if not binaries:
        raise RuntimeError("Portable bundle contains no ELF binaries")
    root_resolved = root.resolve()
    required_versions: set[tuple[int, int]] = set()
    for binary in binaries:
        required_versions.update(glibc_versions(binary))
        for dependency in dependencies(binary, library_dir):
            try:
                dependency.relative_to(root_resolved)
                continue
            except ValueError:
                pass
            if not SYSTEM_RUNTIME.fullmatch(dependency.name):
                raise RuntimeError(
                    f"{binary.relative_to(root)} uses unbundled {dependency}"
                )
    if required_versions and max(required_versions) > maximum_glibc:
        found = ".".join(map(str, max(required_versions)))
        maximum = ".".join(map(str, maximum_glibc))
        raise RuntimeError(f"Portable bundle requires GLIBC_{found}; maximum is {maximum}")

    if launch:
        xvfb = shutil.which("xvfb-run")
        virtual_display: subprocess.Popen[str] | None = None
        environment = dict(os.environ)
        if xvfb is not None:
            command = [xvfb, "-a", str(launcher)]
        else:
            xvfb_server = shutil.which("Xvfb")
            if xvfb_server is None:
                raise RuntimeError("--launch requires xvfb-run or Xvfb")
            display = ":97"
            virtual_display = subprocess.Popen(
                [xvfb_server, display, "-screen", "0", "1280x800x24"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            environment["DISPLAY"] = display
            time.sleep(1)
            if virtual_display.poll() is not None:
                raise RuntimeError("Xvfb exited before the launch test")
            command = [str(launcher)]
        process = subprocess.Popen(
            command,
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=environment,
        )
        time.sleep(8)
        status = process.poll()
        if status is not None:
            output = process.stdout.read() if process.stdout is not None else ""
            if virtual_display is not None:
                virtual_display.terminate()
            raise RuntimeError(
                f"MdsScope exited during portable smoke test ({status}):\n{output}"
            )
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        if virtual_display is not None:
            virtual_display.terminate()
            virtual_display.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--max-glibc", default="2.31")
    parser.add_argument("--launch", action="store_true")
    args = parser.parse_args()
    maximum = tuple(int(part) for part in args.max_glibc.split(".", 1))
    with tempfile.TemporaryDirectory(prefix="mdsscope-portable-test-") as temporary:
        root = extract(args.archive.resolve(), Path(temporary))
        verify(root, maximum, args.launch)
    print(f"Verified portable runtime: {args.archive}")


if __name__ == "__main__":
    main()
