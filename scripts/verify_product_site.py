#!/usr/bin/env python3
"""Validate the dependency-free MDSLens GitHub Pages product site."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "product-site"


def require_file(name: str) -> Path:
    path = SITE / name
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"Missing or empty product-site file: {name}")
    return path


def require_text(path: Path, values: tuple[str, ...]) -> None:
    text = path.read_text(encoding="utf-8")
    for value in values:
        if value not in text:
            raise RuntimeError(f"{path.name} is missing required text: {value}")


def main() -> int:
    index = require_file("index.html")
    styles = require_file("styles.css")
    script = require_file("site.js")
    require_file("mdslens-icon.png")
    require_file("og.png")

    require_text(
        index,
        (
            'href="./styles.css"',
            'src="./site.js"',
            'src="./mdslens-icon.png"',
            "https://github.com/Wu-Kuan-Yee/MDSLens/releases",
            'target="_blank"',
            'rel="noopener noreferrer"',
            'class="waveform-demo"',
        ),
    )
    require_text(
        styles,
        (
            "@media (max-width: 1080px)",
            "@media (max-width: 720px)",
            "@media (prefers-reduced-motion: reduce)",
            "--safe-area-top: env(safe-area-inset-top, 0px)",
            ".site-header {\n  position: fixed",
            "overscroll-behavior: contain",
            "touch-action: none",
        ),
    )
    require_text(
        script,
        (
            "prefers-color-scheme: dark",
            "requestAnimationFrame",
            "ResizeObserver",
            "setPointerCapture",
            'event.pointerType !== "touch"',
            'document.querySelector(".waveform-demo").addEventListener(',
            '"touchmove"',
        ),
    )

    print("Product site verification passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"Product site verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
