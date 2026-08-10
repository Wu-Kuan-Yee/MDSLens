#!/usr/bin/env python3
"""Generate the sparse MDSLens locale registry from a CLDR release.

The registry contains every CLDR ``main`` locale whose language/script parent
is a Modern locale.  Translation catalogs remain separate and can override a
registry entry at runtime; registry entries with no catalog inherit English.
"""

from __future__ import annotations

import argparse
import csv
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_coverage_levels(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) >= 3:
            result[fields[0]] = fields[1]
    return result


def parse_locale_coverage(path: Path) -> dict[str, tuple[str, str, str, str]]:
    result: dict[str, tuple[str, str, str, str]] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        rows = csv.reader(stream, delimiter="\t")
        next(rows, None)
        for row in rows:
            if len(row) < 7:
                continue
            result[row[0]] = (row[1], row[2], row[3], row[4])
    return result


def xml_identity(path: Path) -> tuple[str | None, str | None, str | None]:
    identity = ET.parse(path).getroot().find("identity")
    if identity is None:
        return None, None, None
    script = identity.find("script")
    region = identity.find("territory")
    variant = identity.find("variant")
    return (
        script.attrib.get("type") if script is not None else None,
        region.attrib.get("type") if region is not None else None,
        variant.attrib.get("type") if variant is not None else None,
    )


def normalize_tag(value: str) -> str:
    parts = [part for part in value.replace("_", "-").split("-") if part]
    if not parts:
        return ""
    normalized = [parts[0].lower()]
    for part in parts[1:]:
        if len(part) == 4 and part.isalpha():
            normalized.append(part.title())
        elif (len(part) == 2 and part.isalpha()) or (
            len(part) == 3 and part.isdigit()
        ):
            normalized.append(part.upper())
        else:
            normalized.append(part.lower())
    return "-".join(normalized)


def parent_candidates(tag: str) -> list[str]:
    parts = tag.split("-")
    return ["-".join(parts[:index]) for index in range(len(parts) - 1, 0, -1)]


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage-levels", type=Path, required=True)
    parser.add_argument("--locale-coverage", type=Path, required=True)
    parser.add_argument("--main-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    coverage = parse_coverage_levels(args.coverage_levels)
    display = parse_locale_coverage(args.locale_coverage)
    modern_cldr_bases = sorted(
        locale for locale, level in coverage.items() if level == "modern"
    )
    modern_bases = sorted({normalize_tag(locale) for locale in modern_cldr_bases})
    modern_languages = {
        locale.split("_", 1)[0] for locale in modern_cldr_bases
    }

    # Use the CLDR main files as the source of truth for regional/script
    # variants.  Prefix matching is deliberately restricted to an underscore
    # boundary so ``fr`` cannot accidentally include ``frr``.
    tags: set[str] = set(modern_bases)
    files: dict[str, Path] = {}
    for path in args.main_directory.glob("*.xml"):
        stem = path.stem
        language = stem.split("_", 1)[0]
        if language not in modern_languages:
            continue
        if stem not in modern_languages and not any(
            stem.startswith(base + "_") for base in modern_languages
        ):
            continue
        tag = normalize_tag(stem)
        if tag:
            tags.add(tag)
            files[tag] = path

    # Parent links are explicit so the Flutter service does not need to know
    # anything about CLDR's filename conventions.
    definitions: list[dict[str, str | None]] = []
    for tag in sorted(tags):
        cldr_name = tag.replace("-", "_")
        base_name = cldr_name.split("_", 1)[0]
        metadata = display.get(cldr_name) or display.get(base_name)
        if metadata:
            name, native_name, script, default_region = metadata
        else:
            name = native_name = base_name
            script = default_region = ""
        identity_script, identity_region, identity_variant = (None, None, None)
        if tag in files:
            identity_script, identity_region, identity_variant = xml_identity(files[tag])
        script = identity_script or script
        default_region = identity_region or default_region
        if tag in modern_bases:
            parent = next(
                (
                    candidate
                    for candidate in parent_candidates(tag)
                    if candidate in tags
                ),
                None,
            )
            level = "modern"
        else:
            parent = next(
                (
                    candidate
                    for candidate in parent_candidates(tag)
                    if candidate in tags
                ),
                base_name if base_name in tags else "en",
            )
            level = "modern-inherited"
        suffix = tag[len(base_name) :].replace("-", " ").strip()
        if tag not in modern_bases:
            label = suffix or tag
            name = f"{name} ({label})"
            native_name = f"{native_name} ({label})"
        definitions.append(
            {
                "locale": tag,
                "name": name,
                "nativeName": native_name,
                "baseLocale": parent,
                "coverageLevel": level,
                "script": script or None,
                "defaultRegion": default_region or None,
                "variant": identity_variant,
            }
        )

    output = [
        "# Generated from Unicode CLDR 48.2 locale coverage and main data.",
        "# This registry contains Modern language parents and all production",
        "# regional/script variants under those parents. Translation catalogs",
        "# are separate and may override any entry at runtime.",
        "# Unicode CLDR: https://cldr.unicode.org/",
        "version = 1",
        'kind = "locale-registry"',
        'coverage = "CLDR 48.2 Modern"',
        f"baseLocaleCount = {len(modern_bases)}",
        f"localeCount = {len(definitions)}",
        "",
    ]
    for item in definitions:
        output.append(f"[locales.{toml_string(item['locale'] or '')}]")
        output.append(f"name = {toml_string(item['name'] or '')}")
        output.append(f"nativeName = {toml_string(item['nativeName'] or '')}")
        for key in ("baseLocale", "coverageLevel", "script", "defaultRegion"):
            if item[key]:
                output.append(f"{key} = {toml_string(item[key] or '')}")
        output.append("")
    args.output.write_text("\n".join(output), encoding="utf-8")
    print(f"wrote {len(definitions)} locale entries ({len(modern_bases)} Modern parents)")


if __name__ == "__main__":
    main()
