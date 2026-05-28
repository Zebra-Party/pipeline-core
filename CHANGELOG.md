# Changelog

Notable changes to pipeline-core are documented here. Callers pinned to a
floating major tag (e.g. `@v1`) receive all minor and patch changes
automatically. Breaking changes (new required inputs, removed outputs, changed
behaviour) bump the major version.

---

## [v1.0.0] — 2026-05-28

Initial versioned release. All workflows were previously consumed via `@main`.

### Changed

- Default runner label across all reusable workflows changed from
  `["self-hosted", "macOS", "olympus"]` to `["self-hosted", "macOS", "ephemeral"]`,
  targeting the org's new Tart-managed ephemeral Mac runners.
- Removed `clean_checkout` input from `gdscript-ci.yml`, `ios-release.yml`, and
  `macos-release.yml` — the input was always `false` and is meaningless on
  ephemeral runners where every workspace is fresh.
- Removed stale import-ordering retry in `godot_import.sh` (only triggered on
  persistent runners with a warm `.godot/` cache).
- Removed `rm -rf "$BUILD_DIR"` from `build_ios.sh` (no-op on ephemeral runners).
- Updated stale runner-name references in `select_xcode.sh` and comments.
- Added `description:` to the `runner` input in `macos-release.yml` (parity
  with other workflows).

### Added

- **Tag-release workflow** (`.github/workflows/tag-release.yml`): manually cut
  a semver release of pipeline-core. Creates a GitHub Release + updates the
  floating major tag (e.g. `v1`).
- **Automatic release tagging** in `ios-release.yml`, `macos-release.yml`,
  `xcode-release.yml`, and `flutter-ios-release.yml`: after each successful
  build on `main`, a GitHub Release `v{version}` is created in the calling
  game repo. This anchors `compute_version.sh`'s patch counter so version
  numbers stay meaningful between manual releases.

### Fixed

- Keychain path with spaces when `RUNNER_NAME` contains a space (e.g. `Minerva 2`):
  `keychain_helpers.sh` now sanitises the runner name before constructing the
  keychain path, preventing `codesign` from splitting on the space and failing
  with "No such file or directory".
