# Languages and Runtime Font Discovery

MDSLens currently ships English and Simplified Chinese interfaces. Its UI text
is resolved through runtime TOML catalogs, so adding another language does not
require generating or editing Dart source. The catalog loader also ships the
CLDR 48.2 Modern locale registry: 104 Modern language/script parents and all
563 production locale records (104 parents plus 459 regional/script variants)
are available for selection. A registry record is metadata plus a fallback
link; it is not a claim that all 563 translations have already been authored.

## Language files

Bundled catalogs live in `assets/languages/`. Flutter's asset manifest is
scanned at runtime, so no separate language manifest or hard-coded locale list
is maintained. Native builds also scan the private runtime directory:

```text
~/.mdslens/languages/
```

Android, iOS, and iPadOS use the equivalent `.mdslens/languages/` directory in
their application-support sandbox. The Language panel can import a TOML file,
which is the portable way to add a runtime catalog on sandboxed devices. The
Web build stores imported catalogs in browser application storage because a web
page cannot watch an arbitrary system folder.

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
inherit from a parent catalog; omitted parents use the normal BCP 47 parent
chain. MDSLens tries an exact catalog with translations, then translated
parents, then the selected locale's registry metadata, and finally English.
The default `System (automatic)` setting listens for operating-system locale
changes while the application is running. An explicitly selected language
remains selected until the user changes it.

## CLDR Modern registry

`assets/languages/cldr-modern.toml` is generated from the official Unicode
CLDR 48.2 `common/properties/coverageLevels.txt`, locale coverage TSV, and
`common/main/` data. It intentionally keeps every production regional/script
record under a Modern language parent, including records whose translation
data is inherited or sparse. The registry is small metadata, not 563 copies
of the 514-message English catalog.

To regenerate it after downloading a newer CLDR release:

```sh
python3 tool/generate_cldr_registry.py \
  --coverage-levels /path/to/cldr/common/properties/coverageLevels.txt \
  --locale-coverage /path/to/locale-coverage.tsv \
  --main-directory /path/to/cldr/common/main \
  --output assets/languages/cldr-modern.toml
```

The generated file is committed so offline builds and all platforms use the
same deterministic locale list. Unicode CLDR data remains subject to the
[Unicode CLDR terms of use](https://cldr.unicode.org/index/license).

The visible English source text is the stable message key. Placeholders must be
kept in translated values. Regenerate and validate the English source catalog
after adding UI text:

```sh
dart run tool/update_english_catalog.dart
dart run tool/update_english_catalog.dart --check
```

Malformed optional files are ignored independently, so one bad translation
cannot remove English or other valid languages. A runtime file with the same
locale intentionally overrides its bundled counterpart; editing, adding, or
deleting it updates an open Language panel and the running interface without a
restart. Bundled application assets are read-only and change only when a new
application build is installed.

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

The English catalog is generated from the Dart UI sources. Fully translated
catalogs should keep the same keys and placeholders; sparse catalogs may
contain only the keys they intentionally override. Run both checks before
committing a UI change:

```sh
dart tool/update_english_catalog.dart --check
flutter test test/language_service_test.dart
```

The language test parses every shipped catalog, verifies that catalog keys are
known English keys and that their placeholders match, validates the CLDR
registry count and representative region/script tags, and exercises ordinary
`Text`, `SelectableText`, interpolation, system-locale selection, and live
catalog add/edit/remove. This keeps new UI strings from silently bypassing
translation while allowing the registry's deliberate sparse fallback model.

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
