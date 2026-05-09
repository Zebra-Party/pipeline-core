# Flutter iOS release workflow

**File:** `.github/workflows/flutter-ios-release.yml`

Builds a signed IPA from a Flutter project and uploads it to TestFlight. Mirrors the secret names and skip-when-absent behaviour of [`xcode-release.yml`](ios-release.md), so a Flutter app and a native Xcode app can sit side by side in the org without their callers diverging.

## Why not `flutter build ipa`?

`flutter build ipa --export-options-plist=…` configures the **export** step but offers no equivalent flag for the **archive** step. With manual signing that's a dealbreaker — the archive falls back to automatic signing with no usable error if the developer team isn't pre-baked into the Xcode project. This workflow goes through `xcodebuild archive` directly (via [`build_flutter_ios.sh`](../scripts/build_flutter_ios.sh)), passing the manual signing settings from `configure_xcode_signing.sh`. Same code path as `xcode-release.yml`.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `app_name` | string | _(required)_ | Output IPA basename. |
| `flutter_project_name` | string | _(required)_ | Dart package name (e.g. `wifes_cookbook`). Passed to `flutter create --project-name`. |
| `flutter_org` | string | _(required)_ | Reverse-DNS org prefix for the bundle ID (e.g. `party.zebra`). Passed to `flutter create --org`. |
| `bundle_id` | string | _(empty)_ | Optional override of the iOS bundle ID. Set when the desired ID isn't `<flutter_org>.<lowerCamelCase(flutter_project_name)>`. Passes `PRODUCT_BUNDLE_IDENTIFIER` to xcodebuild. |
| `flutter_version` | string | `3.41.x` | Flutter SDK version (`subosito/flutter-action` format). |
| `runner` | string | `["self-hosted","macOS","olympus"]` | JSON array of runner labels. Must be macOS. |
| `run_build_runner` | boolean | `true` | Run `dart run build_runner build --delete-conflicting-outputs` after `flutter pub get`. Set to `false` for projects without code generators (Drift, Freezed, json_serializable, etc.). |
| `upload_to_testflight` | boolean | `true` | Upload to TestFlight when on `main`. Build still runs on PRs. |

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
| Compute version | `compute_version.sh` | `X.Y.Z` from latest `v*` tag + commit count; build = `github.run_number`. |
| Configure signing | `configure_xcode_signing.sh` | Imports the cert into a fresh keychain, installs the profile, writes `ExportOptions.plist`, exports `KEYCHAIN_PATH` / `TEAM_ID` / `PROVISIONING_PROFILE_UUID_IOS` / `EXPORT_OPTIONS_PATH_IOS`. |
| Build IPA | `build_flutter_ios.sh` | `flutter build ios --no-codesign` then `xcodebuild archive` + `xcodebuild -exportArchive` against `ios/Runner.xcworkspace` with manual signing. Outputs `IPA_PATH`. |
| Upload to TestFlight | `upload_ios.sh` | Only on pushes to `main`. Uses `xcrun altool` with the App Store Connect API key. |
| Clean up | `keychain_destroy` + `rm` | Destroys the per-job keychain and removes the installed `.mobileprovision`. |
