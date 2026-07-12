# Flutter iOS release workflow

**File:** `.github/workflows/flutter-ios-release.yml`

Builds a signed IPA from a Flutter project and uploads it to TestFlight. Mirrors the secret names and skip-when-absent behaviour of [`xcode-release.yml`](xcode-release.md), so a Flutter app and a native Xcode app can sit side by side in the org without their callers diverging.

## Why not `flutter build ipa`?

`flutter build ipa --export-options-plist=…` configures the **export** step but offers no equivalent flag for the **archive** step. With manual signing that's a dealbreaker — the archive falls back to automatic signing with no usable error if the developer team isn't pre-baked into the Xcode project. This workflow goes through `xcodebuild archive` directly (via [`build_flutter_ios.sh`](../scripts/build_flutter_ios.sh)), passing the manual signing settings from `configure_xcode_signing.sh`. Same code path as `xcode-release.yml`.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `app_name` | string | _(required)_ | Output IPA basename. |
| `flutter_project_name` | string | _(required)_ | Dart package name (snake_case). Passed to `flutter create --project-name`. |
| `flutter_org` | string | _(required)_ | Reverse-DNS org prefix for the bundle ID. Passed to `flutter create --org`. |
| `bundle_id` | string | _(empty)_ | Optional override of the iOS bundle ID. Set when the desired ID isn't `<flutter_org>.<lowerCamelCase(flutter_project_name)>`. Passes `PRODUCT_BUNDLE_IDENTIFIER` to xcodebuild. |
| `flutter_version` | string | `3.41.x` | Flutter SDK version (`subosito/flutter-action` format). |
| `runner` | string | `["self-hosted","macOS","ephemeral"]` | JSON array of runner labels. Must be macOS. |
| `run_build_runner` | boolean | `true` | Run `dart run build_runner build --delete-conflicting-outputs` after `flutter pub get`. Set to `false` for projects without code generators (Drift, Freezed, json_serializable, etc.). |
| `upload_to_testflight` | boolean | `true` | Upload to TestFlight when on `main` or a `v*` tag push. Build still runs on PRs. |
| `version` | string | _(empty)_ | Version to build, from [`release-gate.yml`](versioning.md#release-gateyml). Empty → the workflow computes it itself (back-compat). Passing it from the gate means every platform job in a release shares one version and one build number. |
| `build` | string | _(empty)_ | Build number, from the release gate. Empty → computed locally. |

The bundle ID Flutter generates from `--org X.Y --project-name a_b_c` is `X.Y.aBC` (camelCased). If your provisioning profile is for a different bundle ID, set `bundle_id` to override.

## Secrets

Use `secrets: inherit` in the caller (the names below are org-level secrets that the rest of the org also consumes).

### Signing

| Secret | Required | Description |
|---|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | yes | Base64-encoded Apple Distribution `.p12`. |
| `APPLE_CERTIFICATE_PASSWORD` | yes | Password set when the `.p12` was exported. |
| `APPLE_IOS_DISTRIBUTION_PROVISION` | no¹ | Base64-encoded `.mobileprovision`. |

¹ If absent, build + upload are both skipped with a warning. Useful on forks or before Apple credentials are wired up. (`APPLE_CERTIFICATE_P12_BASE64` is declared `required: true` at the workflow level so the caller's intent is explicit; the runtime check still tolerates an empty value.)

### TestFlight upload

| Secret | Description |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect → Users & Access → Integrations → Keys → Issuer ID. |
| `APP_STORE_CONNECT_KEY_ID` | Key ID of the App Store Connect API key. |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded `.p8` downloaded when the key was created. |

If any are missing the upload step is skipped with a warning; the IPA is still built.

## Steps

| Step | Script | What it does |
|---|---|---|
| Select Xcode | `select_xcode.sh` | Picks the newest `Xcode*.app` under `/Applications/`. |
| Set up Flutter | `subosito/flutter-action` | Installs the requested Flutter SDK with caching. |
| Materialise platform folders | `flutter create` | Regenerates `ios/` so it can never drift behind the SDK. |
| `flutter pub get` | — | — |
| Generate code | `build_runner` | Drift / Freezed / Riverpod codegen. Skipped if `run_build_runner: false`. |
| Resolve version | `compute_version.sh` | Uses the `version` / `build` inputs when the release gate passed them; otherwise `X.Y.Z` from the latest `v*` tag + commit count, and a unix-timestamp build number. See [versioning.md](versioning.md). |
| Configure signing | `configure_xcode_signing.sh` | Imports the cert into a fresh keychain, installs the profile, writes `ExportOptions.plist`, exports `KEYCHAIN_PATH` / `TEAM_ID` / `PROVISIONING_PROFILE_UUID_IOS` / `EXPORT_OPTIONS_PATH_IOS`. |
| Build IPA | `build_flutter_ios.sh` | `flutter build ios --no-codesign` then `xcodebuild archive` + `xcodebuild -exportArchive` against `ios/Runner.xcworkspace` with manual signing. Outputs `IPA_PATH`. |
| Upload to TestFlight | `upload_ios.sh` | Only on `main` or a `v*` tag push. Uses `xcrun altool` with the App Store Connect API key. |
| Tag release | _(inline)_ | Creates a GitHub Release `v{version}` in the calling repo (`gh release create --notes … --generate-notes --latest`). The notes lead with a line saying the iOS builds for this version are on TestFlight — an App-Store-signed IPA can't be attached, since it isn't installable from a download. Only on `main` or a `v*` tag, never on PRs, and skipped if the release already exists. See [versioning.md](versioning.md). |
| Clean up | `keychain_destroy` + `rm` | Destroys the per-job keychain and removes the installed `.mobileprovision`. |

## Example

A nightly release gated by [`release-gate.yml`](versioning.md#release-gateyml):

```yaml
# .github/workflows/release.yml
name: Release
on:
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:
    inputs:
      bump:
        description: "patch | minor | major"
        type: choice
        options: [patch, minor, major]
        default: patch

jobs:
  gate:
    uses: Zebra-Party/pipeline-core/.github/workflows/release-gate.yml@v1
    with:
      bump: ${{ inputs.bump || 'patch' }}

  ios:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/flutter-ios-release.yml@v1
    with:
      app_name: "MyApp"
      flutter_project_name: "my_app"
      flutter_org: "com.example"
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
    secrets: inherit
```
