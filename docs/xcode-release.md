# Xcode release workflow

**File:** `.github/workflows/xcode-release.yml`

Builds and code-signs a **native Swift/Xcode** app for iOS, macOS, and tvOS, and uploads each to TestFlight. Use this for apps that own an `.xcodeproj` / `.xcworkspace` (optionally generated from `project.yml` by XcodeGen) — not for Godot projects, which use [`ios-release.yml`](ios-release.md) / [`macos-release.yml`](macos-release.md) instead.

The three platforms run as **parallel jobs** (`ios`, `macos`, `tvos`). Each one independently checks for its own provisioning-profile secret and skips the whole build with a warning if it's absent — so an iOS-only app can call this workflow and simply not set `APPLE_MACOS_PROVISION` / `APPLE_TVOS_PROVISION`, and the macOS and tvOS jobs go green without building anything.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `app_name` | string | _(required)_ | The Xcode **scheme** name and the basename of the produced `.ipa` / `.pkg`. Also used to locate the project: `build_xcode.sh` prefers `<app_name>.xcworkspace`, falling back to `<app_name>.xcodeproj`. |
| `runner` | string | `["self-hosted","macOS","ephemeral"]` | JSON array of runner labels. Must be macOS — Xcode is required. |
| `upload_to_testflight` | boolean | `true` | Whether to upload to TestFlight. Upload only happens on `main` or a `v*` tag push, never on pull requests; this flag disables it entirely. |
| `regenerate_xcodeproj` | boolean | `true` | Run `xcodegen generate` before building, when a `project.yml` exists at the repo root. Set to `false` for repos whose committed `.xcodeproj` has hand-tuned settings that XcodeGen would drop (notably iOS code-signing details that aren't expressible in `project.yml`). |
| `version` | string | _(empty)_ | Version to build, from [`release-gate.yml`](versioning.md#release-gateyml). Empty → each job computes it itself (back-compat). Passing it from the gate means the three platform jobs all ship the **same** `X.Y.Z` and the same build number. |
| `build` | string | _(empty)_ | Build number, from the release gate. Empty → computed locally, per job. |

## Secrets

Unlike the Godot workflows, the provisioning profiles here are passed under **generic names** (`APPLE_IOS_PROVISION`, …) rather than inherited wholesale. Provisioning profiles are app-specific, so a caller maps its own org secret onto the generic name — which is what lets several different native apps share this one workflow.

```yaml
    secrets:
      APPLE_CERTIFICATE_P12_BASE64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
      APPLE_IOS_PROVISION: ${{ secrets.APPLE_MYAPP_IOS_DISTRIBUTION_PROVISION }}
```

### Signing secrets

| Secret | Required | Description |
|---|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | yes | Base64-encoded Apple Distribution certificate (`.p12`). |
| `APPLE_CERTIFICATE_PASSWORD` | yes | Password set when the `.p12` was exported. |
| `APPLE_IOS_PROVISION` | no¹ | Base64-encoded iOS distribution profile (`.mobileprovision`). Absent → the `ios` job skips. |
| `APPLE_MACOS_PROVISION` | no¹ | Base64-encoded macOS distribution profile (`.provisionprofile`). Absent → the `macos` job skips. |
| `APPLE_TVOS_PROVISION` | no¹ | Base64-encoded tvOS distribution profile (`.mobileprovision`). Absent → the `tvos` job skips. |
| `APPLE_MAC_INSTALLER_P12_BASE64` | no | Base64-encoded Mac Installer Distribution certificate. Needed to produce a **signed** `.pkg`; without it the macOS `.pkg` is unsigned and TestFlight will reject it. |

¹ `APPLE_CERTIFICATE_P12_BASE64` and `APPLE_CERTIFICATE_PASSWORD` are declared `required: true` at the workflow level so the caller's intent is explicit; the per-job runtime check still tolerates an empty value and skips with a warning.

### Embedded-target profiles (optional)

An app that embeds targets with their **own bundle IDs** — a widget / Live Activity extension, an embedded watchOS app — needs a profile per bundle ID. Pass them alongside the host app's profile:

| Secret | Description |
|---|---|
| `APPLE_IOS_EXTENSION_PROVISION` | Profile for the first embedded target. |
| `APPLE_IOS_EXTENSION_PROVISION_2` | Profile for a second embedded target (e.g. an app shipping both a widget and a watch app). |

When an extension profile is present, `build_xcode.sh` deliberately does **not** pin a single `PROVISIONING_PROFILE_SPECIFIER` across the build — that would force the host app's profile onto the extension's different bundle ID and fail the archive. Instead every profile is installed and Xcode matches each target to its profile by bundle ID under manual signing. Single-target apps keep the explicit specifier.

### Upload secrets (required to publish to TestFlight)

| Secret | Description |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from App Store Connect → Users & Access → Integrations → Keys. |
| `APP_STORE_CONNECT_KEY_ID` | Key ID of the App Store Connect API key. |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded `.p8` private key downloaded when the key was created. |

If any of the three is absent the upload step is skipped with a warning, but the app is still built.

## Steps

Each of the three jobs runs the same sequence, differing only in `PLATFORM` (`ios` / `macos` / `appletvos`), which profile secret it reads, and which upload script it calls.

| Step | Script | What it does |
|---|---|---|
| Select Xcode | `select_xcode.sh` | Picks the newest `Xcode*.app` under `/Applications/`. |
| Regenerate Xcode project | `regenerate_xcodeproj.sh` | Runs `xcodegen generate` if `project.yml` exists at the repo root; a no-op otherwise. Keeps the committed `.xcodeproj` from going stale when a contributor adds a source file. Skipped entirely when `regenerate_xcodeproj: false`. |
| Check signing secrets | _(inline)_ | If the certificate or this platform's provisioning profile is empty, sets `skip=true` — every step below is then skipped and the job succeeds with a warning. |
| Resolve version | `compute_version.sh` | Uses the `version` / `build` inputs when the release gate passed them; otherwise derives `X.Y.Z` and a timestamp build number from git tags. See [versioning.md](versioning.md). |
| Configure signing | `configure_xcode_signing.sh` | Imports the distribution cert (and, on macOS, the Mac Installer cert) into a fresh temporary keychain, installs the provisioning profile(s), and writes an `ExportOptions.plist` for the platform. Exports `KEYCHAIN_PATH`, `TEAM_ID`, `PROVISIONING_PROFILE_UUID_<PLATFORM>`, `EXPORT_OPTIONS_PATH_<PLATFORM>`. |
| Build | `build_xcode.sh` | `xcodebuild archive` then `xcodebuild -exportArchive` against `<app_name>.xcworkspace` (preferred) or `<app_name>.xcodeproj`, with manual signing and `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` set from the computed version. Retries the archive up to 3× on transient codesign failures (`errSecInternalComponent`, timestamp-service hiccups) — a real compile error still fails fast on the first attempt. Outputs `IPA_PATH` (iOS/tvOS) or `PKG_PATH` (macOS). |
| Upload to TestFlight | `upload_ios.sh` / `upload_macos.sh` / `upload_tvos.sh` | `xcrun altool --upload-app` with the App Store Connect API key. Only on `main` or a `v*` tag push, never on PRs, and only if `upload_to_testflight` and the upload secrets are present. |
| Tag release | _(inline)_ | Creates a GitHub Release `v{version}` in the **calling repo** (`gh release create --notes … --generate-notes --latest`). The notes lead with a line saying the iOS/macOS/tvOS builds for this version are on TestFlight — an App-Store-signed IPA/`.pkg` can't be attached to a release because it isn't installable from a download. The wording is platform-agnostic on purpose: whichever of the three parallel jobs wins the race writes the notes. Only on `main` or a `v*` tag, never on PRs. Idempotent — skips if the release exists, so the three jobs don't collide on the same commit. |
| Clean up signing artefacts | _(inline)_ | Always runs. Destroys the temporary keychain and removes the installed provisioning profile so nothing persists on the runner. |

## Example

An iOS-only app with a widget extension, released nightly behind [`release-gate.yml`](versioning.md#release-gateyml):

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

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  gate:
    uses: Zebra-Party/pipeline-core/.github/workflows/release-gate.yml@v1
    with:
      bump: ${{ inputs.bump || 'patch' }}

  release:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/xcode-release.yml@v1
    with:
      app_name: "MyApp"
      upload_to_testflight: true
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
    secrets:
      APPLE_CERTIFICATE_P12_BASE64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
      APPLE_IOS_PROVISION: ${{ secrets.APPLE_MYAPP_IOS_DISTRIBUTION_PROVISION }}
      APPLE_IOS_EXTENSION_PROVISION: ${{ secrets.APPLE_MYAPP_WIDGET_PROVISION }}
      APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
      APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      APP_STORE_CONNECT_PRIVATE_KEY_BASE64: ${{ secrets.APP_STORE_CONNECT_PRIVATE_KEY_BASE64 }}
```

The `macos` and `tvos` jobs still appear in the run, notice their profile secrets are unset, and finish green without building.

A multi-platform app whose committed `.xcodeproj` carries hand-tuned signing settings XcodeGen would drop:

```yaml
jobs:
  release:
    uses: Zebra-Party/pipeline-core/.github/workflows/xcode-release.yml@v1
    with:
      app_name: "MyApp"
      regenerate_xcodeproj: false
    secrets:
      APPLE_CERTIFICATE_P12_BASE64: ${{ secrets.APPLE_CERTIFICATE_P12_BASE64 }}
      APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
      APPLE_MAC_INSTALLER_P12_BASE64: ${{ secrets.APPLE_MAC_INSTALLER_P12_BASE64 }}
      APPLE_IOS_PROVISION: ${{ secrets.APPLE_MYAPP_IOS_DISTRIBUTION_PROVISION }}
      APPLE_MACOS_PROVISION: ${{ secrets.APPLE_MYAPP_MACOS_DISTRIBUTION_PROVISION }}
      APPLE_TVOS_PROVISION: ${{ secrets.APPLE_MYAPP_TVOS_DISTRIBUTION_PROVISION }}
      APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
      APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      APP_STORE_CONNECT_PRIVATE_KEY_BASE64: ${{ secrets.APP_STORE_CONNECT_PRIVATE_KEY_BASE64 }}
```

## Project requirements

- The Xcode **scheme** must be named exactly `app_name` and be shared (`xcshareddata/xcschemes/`), or `xcodebuild -scheme` won't find it.
- The scheme must build the platforms you're releasing — a job for a platform the scheme doesn't support will fail at `xcodebuild archive`.
- Version numbers are injected at build time via `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, so they don't need to be maintained in the project file.
