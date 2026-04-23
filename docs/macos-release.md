# macOS release workflow

**File:** `.github/workflows/macos-release.yml`

Builds a signed `.app` and `.pkg` via Godot's macOS exporter and uploads to TestFlight. Like the iOS workflow, signing and upload are skipped gracefully when secrets are absent.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to use. |
| `runner` | string | `["self-hosted","macOS","X64"]` | JSON array of runner labels. Must be macOS. |
| `app_name` | string | `export` | Base filename for the `.app` and `.pkg` (no extension). |
| `macos_preset` | string | `macOS (Universal)` | Name of the Godot export preset to use. Must match exactly what's in `export_presets.cfg`. |
| `upload_to_testflight` | boolean | `true` | Whether to upload the `.pkg` to TestFlight. Only runs on `main`, never on PRs. |
| `pre_export_script` | string | _(empty)_ | Optional shell script to run after signing is configured but before Godot exports. |
| `clean_checkout` | boolean | `false` | Wipe workspace before checkout. |

## Secrets

All are optional — the build is skipped with a warning if the core signing secrets are absent.

### Signing secrets (required to build)

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Apple Distribution certificate (`.p12`). |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12`. |
| `APPLE_MACOS_DISTRIBUTION_PROVISION` | Base64-encoded macOS distribution provisioning profile (`.provisionprofile`). Note: macOS profiles use `.provisionprofile`, not `.mobileprovision`. |

If either `APPLE_CERTIFICATE_P12_BASE64` or `APPLE_MACOS_DISTRIBUTION_PROVISION` is empty, the build and upload steps are skipped.

### Optional signing secrets

| Secret | Description |
|---|---|
| `APPLE_MAC_INSTALLER_P12_BASE64` | Base64-encoded Mac Installer Distribution certificate (`.p12`). Required to produce a signed `.pkg`. Without it, the workflow produces an unsigned `.pkg` and warns that TestFlight upload will fail. |

### Upload secrets (required to publish to TestFlight)

| Secret | Description |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from App Store Connect → Keys. |
| `APP_STORE_CONNECT_KEY_ID` | API key ID. |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded `.p8` private key. |

## Steps

| Step | Script | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Downloads Godot + export templates into a per-runner cache. |
| Compute version | `compute_version.sh` | Derives version and build number from git tags. See [versioning.md](versioning.md). |
| Apply version | `set_version.sh` | Writes version into `project.godot` and `export_presets.cfg`. |
| Reimport | `godot_import.sh` | Primes the asset import cache. |
| Configure signing | `configure_macos_signing.sh` | Decodes and imports the distribution cert (and optionally the Mac Installer cert) into a temporary keychain. Extracts the provisioning profile UUID and Team ID. Patches `export_presets.cfg` with `codesign/apple_team_id` and `codesign/identity = "Apple Distribution"`. |
| Pre-export script | _(your script)_ | Only runs if `pre_export_script` is set and signing was not skipped. |
| Build .app + .pkg | `build_macos.sh` | Calls `godot --export-release` with the macOS preset. Unwraps the `.zip` that Godot may produce instead of a bare `.app`. Embeds the provisioning profile, re-signs with `codesign --force --options runtime --timestamp`, then calls `productbuild` to create the `.pkg`. If the Mac Installer cert is present, the `.pkg` is signed; otherwise it is unsigned (and a warning is printed). |
| Upload to TestFlight | `upload_macos.sh` | Uses `xcrun altool --upload-app --type macos`. Only runs on `main`. |
| Clean up keychain | _(inline)_ | Always runs. Restores the login keychain as default and deletes the temporary keychain. |
| Restore presets | _(inline)_ | Always runs. Reverts `export_presets.cfg` to its committed state. |

## Example

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  macos:
    if: github.actor != 'dependabot[bot]'
    uses: Zebra-Party/pipeline-core/.github/workflows/macos-release.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      macos_preset: "macOS (Universal)"
      upload_to_testflight: true
    secrets: inherit
```

## export_presets.cfg requirements

The macOS preset must have these keys present so the signing step can patch them:

```ini
[preset.N.options]
codesign/apple_team_id=""
codesign/identity=""
```

The preset name must match `macos_preset` exactly (default: `"macOS (Universal)"`).
