# Configuration and Data Formats

MDSLens uses TOML for every persistent configuration or metadata file whose
format is controlled by this project:

- user preferences: `~/.mdslens/settings.toml`;
- waveform layouts: `.toml` (with `.webscp` retained for WebScope
  interoperability);
- external runtime language catalogs and first-run catalog templates: `.toml`;
- release update metadata: `update-manifest.toml`;
- Windows and Linux portable-package metadata: `.mdslens-portable.toml`;
- the optional encrypted Rust authentication-cache wrapper and its encrypted
  payload: TOML.

When an earlier `~/.mdslens/settings.json` is found, MDSLens reads it only as a
migration source. It writes `settings.toml`, parses the new file again, and
only then removes the old file. If writing or validation fails, the old file is
left untouched. Passwords and tokens remain in the operating-system credential
vault and are never written to `settings.toml`.

## JSON boundaries that are not configuration files

The following JSON uses are intentionally retained because changing them to
TOML would either violate a platform/protocol contract or remove an existing
data-export feature:

- Apple Asset Catalog `Contents.json` files and the Web App Manifest
  `web/manifest.json` are filenames and schemas required by Apple and browsers;
- GitHub, EAST login/latest-shot endpoints, the private Web Gateway, and JWT
  claims exchange JSON as part of their external wire protocols;
- Releases temporarily include a generated `update-manifest.json` protocol
  compatibility copy because already deployed MDSLens versions request that
  exact asset name. `update-manifest.toml` is the source of truth, and current
  builds read only TOML;
- Flutter-to-Rust control messages use an internal JSON wire representation,
  while high-volume waveform samples already use binary typed buffers. These
  messages are transient and are never configuration files on disk;
- JSON remains an explicit, user-selected waveform data export format alongside
  text, CSV, and TSV;
- Cargo fingerprint JSON and Flutter/native generated metadata are build-tool
  outputs, not repository configuration owned by MDSLens.

This distinction keeps user-editable configuration consistently TOML without
renaming standards-mandated files or converting performance-sensitive binary
data into a text configuration format.
