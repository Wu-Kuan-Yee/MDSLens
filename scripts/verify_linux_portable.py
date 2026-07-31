#!/usr/bin/env python3
"""Verify a Linux application bundle and its declared host desktop ABI."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path


SYSTEM_RUNTIME = re.compile(
    r"(?:"
    r"ld-linux[^/]*\.so(?:\..*)?|"
    r"ld-\d+(?:\.\d+)+\.so|"
    r"(?:libc|libdl|libm|libpthread|libresolv|librt|libutil|libanl|"
    r"libnss_[A-Za-z0-9_-]+)(?:\.so(?:\..*)?|-\d+(?:\.\d+)+\.so)|"
    r"(?:libstdc\+\+\.so(?:\..*)?|"
    r"libgcc_s(?:-\d[\d.-]*)?\.so(?:\..*)?)|"
    r"(?:libgtk-3|libgdk-3|libpangocairo-1\.0|libpango-1\.0|"
    r"libpangoft2-1\.0|libharfbuzz|libatk-1\.0|libatk-bridge-2\.0|"
    r"libatspi|libcairo-gobject|libcairo|libgdk_pixbuf-2\.0|"
    r"libgio-2\.0|libgmodule-2\.0|libgobject-2\.0|libglib-2\.0|"
    r"libepoxy|libfontconfig|libsecret-1)\.so(?:\..*)?|"
    r"(?:libX11|libXau|libXdmcp|libXext|libXi|libXcursor|libXfixes|"
    r"libXinerama|libXrandr|libXrender|libXcomposite|libXdamage|"
    r"libxcb(?:-[A-Za-z0-9_-]+)?|libwayland-(?:client|cursor|egl)|"
    r"libxkbcommon(?:-x11)?|libepoxy|libEGL|libGL|libGLX|libOpenGL|"
    r"libGLESv2|libGLdispatch|libglapi|libgbm|libdrm(?:_[A-Za-z0-9_-]+)?)"
    r"\.so(?:\..*)?"
    r")"
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


def dependencies(binary: Path) -> list[Path]:
    result = subprocess.run(
        ["ldd", str(binary)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
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


def needed_libraries(binary: Path) -> set[str]:
    result = subprocess.run(
        ["readelf", "-d", str(binary)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return set(
        re.findall(r"\(NEEDED\).*Shared library: \[([^\]]+)\]", result.stdout)
    )


def verify(root: Path, maximum_glibc: tuple[int, int], launch: bool) -> None:
    executable = root / "mdslens"
    library_dir = root / "lib"
    marker = root / ".mdslens-portable.json"
    for required in (executable, library_dir, marker):
        if not required.exists():
            raise RuntimeError(f"Portable bundle is missing {required.relative_to(root)}")
    metadata = json.loads(marker.read_text(encoding="utf-8"))
    if (
        metadata.get("schema_version") != 1
        or metadata.get("product") != "com.mdslens.app"
        or metadata.get("architecture") not in {"x64", "arm64"}
        or metadata.get("executable") != "mdslens"
    ):
        raise RuntimeError("Portable update channel metadata is invalid")
    if not is_elf(executable):
        raise RuntimeError("Portable mdslens is not an ELF executable")
    if not os.access(executable, os.X_OK):
        raise RuntimeError("Portable executable is not executable")

    binaries = [path for path in root.rglob("*") if is_elf(path)]
    if not binaries:
        raise RuntimeError("Portable bundle contains no ELF binaries")
    bundled_system_runtime = sorted(
        path.name
        for path in library_dir.iterdir()
        if is_elf(path) and SYSTEM_RUNTIME.fullmatch(path.name)
    )
    if bundled_system_runtime:
        raise RuntimeError(
            "Portable bundle shadows the host desktop runtime: "
            + ", ".join(bundled_system_runtime)
        )
    bundled_names = {path.name for path in binaries}
    required_versions: set[tuple[int, int]] = set()
    for binary in binaries:
        required_versions.update(glibc_versions(binary))
        dependencies(binary)
        for dependency in needed_libraries(binary):
            if (
                dependency not in bundled_names
                and not SYSTEM_RUNTIME.fullmatch(dependency)
            ):
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
            command = [xvfb, "-a", str(executable)]
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
            command = [str(executable)]
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
                f"MDSLens exited during portable smoke test ({status}):\n{output}"
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
    with tempfile.TemporaryDirectory(prefix="mdslens-portable-test-") as temporary:
        root = extract(args.archive.resolve(), Path(temporary))
        verify(root, maximum, args.launch)
    print(f"Verified portable runtime: {args.archive}")


if __name__ == "__main__":
    main()
