# Languages and Runtime Font Discovery

MDSLens resolves interface text through runtime TOML catalogs, so adding or
removing a language does not require generating or editing Dart source. The
runtime language list has one authoritative source: the user's language store.
No bundled locale registry, hard-coded locale list, or metadata-only locale is
merged into the list shown in Language Settings.

## Language files

Desktop builds continuously scan this directory:

```text
~/.mdslens/languages/
```

Windows resolves `~` through `USERPROFILE`. Android, iOS, and iPadOS use the
equivalent `.mdslens/languages/` directory in their application-support
sandbox. The Language panel can import a TOML file, which is the portable way
to add a runtime catalog on sandboxed devices. The Web build stores imported
catalogs in browser application storage because a web page cannot watch an
arbitrary system folder.

On a new, empty language store, MDSLens copies the real English and Simplified
Chinese starter TOML files into that store once and records that initialization
with a hidden marker. From then on, only files actually present in the external
store are loaded. Deleting either starter file removes that language from the
open list immediately and does not recreate it on the next launch. If the
store already contains a TOML catalog when this version first runs, MDSLens
does not add any starter files.

Only non-hidden `.toml` files that successfully parse as language catalogs are
shown. Adding, editing, renaming, or deleting such files updates an open
Language Settings panel and the running interface without a restart. One
malformed file is ignored independently and cannot hide the other valid files.

Each file has this schema:

```toml
version = 1
locale = "en-GB"
name = "British English"
nativeName = "British English"
baseLocale = "en"

[messages]
"Color" = "Colour"
"Loaded {value1} panels" = "{value1} panels ready"
```

Locale tags use BCP 47 form. Sparse regional catalogs can set `baseLocale` to
inherit from another installed catalog; omitted parents use the normal BCP 47
parent chain. MDSLens tries the selected catalog, then installed parent
catalogs, then an installed English catalog. If none supplies a message, the
stable English source key itself is displayed. No missing language is invented
for fallback. The default `System (automatic)` setting is a preference mode,
not a language catalog: it listens for operating-system locale changes and
selects the closest catalog that is actually installed. An explicitly selected
language remains selected until the user changes it or removes its file.

## CLDR Modern development registry

`assets/languages/cldr-modern.toml` is generated from the official Unicode
CLDR 48.2 `common/properties/coverageLevels.txt`, locale coverage TSV, and
`common/main/` data. It is retained only as development/reference data for
translation tooling and tests. It is excluded from Flutter assets, is never
loaded by `LanguageService`, and creates no selectable runtime language.

To regenerate it after downloading a newer CLDR release:

```sh
python3 tool/generate_cldr_registry.py \
  --coverage-levels /path/to/cldr/common/properties/coverageLevels.txt \
  --locale-coverage /path/to/locale-coverage.tsv \
  --main-directory /path/to/cldr/common/main \
  --output assets/languages/cldr-modern.toml
```

The generated file is committed so translation tooling has deterministic
reference metadata while remaining completely separate from runtime language
discovery. Unicode CLDR data remains subject to the
[Unicode CLDR terms of use](https://cldr.unicode.org/index/license).

The visible English source text is the stable message key. Placeholders must be
kept in translated values. Regenerate and validate the English source catalog
after adding UI text:

```sh
dart run tool/update_english_catalog.dart
dart run tool/update_english_catalog.dart --check
```

`assets/languages/en.toml` and `assets/languages/zh-Hans.toml` are first-run
copy templates, not a second runtime catalog source. Application updates never
merge them into or overwrite an initialized external language store.

## UI coverage contract

All application pages, dialogs, menus, tooltips, input labels, button labels,
status messages, errors, accessibility labels, and selectable text import
`package:mdslens/i18n/localized_material.dart`. Its `Text`, `Tooltip`, and
`SelectableText` wrappers translate source-keyed strings at build time,
including rich text spans. Strings assembled outside a widget must use
`context.tr(...)` explicitly; parameterized messages use named placeholders
such as `{value1}` rather than interpolating before translation. Runtime data
(signal names, URLs, paths, shot numbers, and server-provided diagnostics) is
not translated, but any surrounding label or status template is.

The English first-run template is generated from the Dart UI sources. Fully
translated catalogs should keep the same keys and placeholders; sparse
catalogs may contain only the keys they intentionally override. Run both checks
before committing a UI change:

```sh
dart tool/update_english_catalog.dart --check
flutter test test/language_service_test.dart
```

The language test parses every starter catalog, verifies that catalog keys are
known English keys and that their placeholders match, validates the tooling
CLDR registry, and exercises ordinary `Text`, `SelectableText`, interpolation,
system-locale selection, and live external catalog add/edit/remove. It also
verifies that a deleted starter file is not recreated on a later launch.

## Font discovery

The Customize Fonts panel queries the host rather than presenting a hard-coded
font list. While that panel is open, MDSLens refreshes the list every two
seconds and updates it only when the set of available families changes. A font
installed or removed while the picker is open therefore appears or disappears
without restarting MDSLens.

Windows, macOS, Linux, Android, iOS, and iPadOS each query their native font
registry on every refresh. Mobile operating systems expose only families that
applications are allowed to use. On the Web, Local Font Access is
browser- and permission-dependent; Chromium-family browsers can expose local
fonts after permission is granted, while unsupported or restricted browsers
show only the bundled `MDSLens Noto Sans SC` family. Browser security does not
permit a web application to bypass that boundary.
