# iOS release workflow

**File:** `.github/workflows/ios-release.yml`

Builds a signed IPA via Godot's iOS exporter and uploads it to TestFlight. Signing and upload are skipped gracefully if the required secrets are absent, so the workflow is safe to call from repos that haven't wired up Apple credentials yet.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to use. |
| `runner` | string | `["self-hosted","macOS","X64"]` | JSON array of runner labels. Must be a macOS runner — Xcode is required. |
| `app_name` | string | `export` | Base filename for the produced `.ipa` (no extension). |
| `upload_to_testflight` | boolean | `true` | Whether to upload the IPA to TestFlight. Upload only happens when on the `main` branch and the event is not a pull request — this flag lets you disable it entirely (e.g. for a staging project). |
| `pre_export_script` | string | _(empty)_ | Optional shell script to run after signing is configured but before Godot exports. Use this for code generation that must run before the Godot export (e.g. `tools/compile_scenes.sh`). |
| `clean_checkout` | boolean | `false` | Wipe workspace before checkout. |

## Secrets

Secrets are forwarded from the calling repo via `secrets: inherit`. All are optional — the workflow emits a warning and skips signing/upload if the core set is absent.

### Signing secrets (required to build)

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Apple Distribution certificate (`.p12`). Export from Keychain Access. |
| `APPLE_CERTIFICATE_PASSWORD` | Password set when the `.p12` was exported. |
| `APPLE_IOS_DISTRIBUTION_PROVISION` | Base64-encoded iOS distribution provisioning profile (`.mobileprovision`). Download from the Apple Developer portal. |

If either `APPLE_CERTIFICATE_P12_BASE64` or `APPLE_IOS_DISTRIBUTION_PROVISION` is empty, the build and upload steps are skipped and the workflow succeeds with a warning.

### Upload secrets (required to publish to TestFlight)

| Secret | Description |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from App Store Connect → Users & Access → Integrations → Keys. |
| `APP_STORE_CONNECT_KEY_ID` | Key ID of the App Store Connect API key. |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded `.p8` private key file downloaded when the API key was created. |

If any of these three are absent, the upload step is skipped with a warning but the IPA is still built.

## Steps

| Step | Script | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Downloads Godot + iOS export templates into a per-runner cache. |
| Compute version | `compute_version.sh` | Derives `X.Y.Z` version and build number from git tags. See [versioning.md](versioning.md). |
| Apply version | `set_version.sh` | Writes the computed version into `project.godot` and `export_presets.cfg`. |
| Reimport | `godot_import.sh` | Primes the `.godot/imported/` cache so Godot's iOS exporter has all asset sidecars available. |
| Configure signing | `configure_ios_signing.sh` | Decodes the `.p12` and `.mobileprovision` from base64, imports the certificate into a fresh temporary keychain, installs the profile, and patches `export_presets.cfg` with the Team ID and profile UUID. Prints a warning if the profile's bundle ID doesn't match the preset. |
| Pre-export script | _(your script)_ | Only runs if `pre_export_script` is set and signing was not skipped. |
| Build IPA | `build_ios.sh` | Re-unlocks the keychain and re-asserts it as the system default (guards against keychain auto-lock between steps), then calls `godot --export-release "iOS"`. Verifies the produced IPA contains a `.pck` and has a valid codesign signature. |
| Upload to TestFlight | `upload_ios.sh` | Uses `xcrun altool --upload-app --type ios` with the App Store Connect API key. Only runs on the `main` branch and only if upload secrets are present. |
| Clean up keychain | _(inline)_ | Always runs. Restores `login.keychain-db` as the system default, then deletes the temporary build keychain so it doesn't persist on the runner. |
| Restore presets | _(inline)_ | Always runs. Discards the version + signing changes to `export_presets.cfg` with `git checkout` so the working tree is clean for the next run. |

## Example

Standard single-target setup:

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  ios:
    uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      upload_to_testflight: true
    secrets: inherit
```

With a pre-export code generation step, and skipping the Dependabot actor who won't have signing secrets:

```yaml
jobs:
  ios:
    if: github.actor != 'dependabot[bot]'
    uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      pre_export_script: "tools/compile_scenes.sh"
      upload_to_testflight: true
    secrets: inherit
```

## Preparing Apple credentials

1. **Distribution certificate**: In Xcode or Keychain Access, export your Apple Distribution certificate as a `.p12` file. Base64-encode it: `base64 -i cert.p12 | pbcopy`. Set `APPLE_CERTIFICATE_P12_BASE64` and `APPLE_CERTIFICATE_PASSWORD` in the repo's secrets.

2. **Provisioning profile**: Download the distribution provisioning profile from the Apple Developer portal. Base64-encode it: `base64 -i Profile.mobileprovision | pbcopy`. Set `APPLE_IOS_DISTRIBUTION_PROVISION`.

3. **App Store Connect API key**: In App Store Connect → Users & Access → Integrations → Keys, create an API key with Developer role. Download the `.p8` file (only available once). Base64-encode it: `base64 -i AuthKey_XXXX.p8 | pbcopy`. Set `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`.

## export_presets.cfg requirements

The iOS preset (preset index 0 by convention) must have these keys present so the signing step can patch them:

```ini
[preset.0]
...
[preset.0.options]
application/app_store_team_id=""
application/provisioning_profile_specifier_release=""
```

The values can be empty — they are overwritten at build time. The preset name must be exactly `"iOS"`.
