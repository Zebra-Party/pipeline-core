# Android build workflow

**File:** `.github/workflows/android-build.yml`

Builds a **debug-signed** APK and uploads it as a workflow artifact. Optionally attaches it to the GitHub Release for the version being shipped, so testers can download and sideload it directly. Play Store publishing is not implemented yet.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to use. |
| `runner` | string | `["self-hosted","macOS","ephemeral"]` | JSON array of runner labels (consumed via `fromJSON`). Android builds don't need macOS/Xcode, so this job can also run on the org's self-hosted **Windows** runners — pass `["self-hosted","Windows","X64"]` (the host needs an Android SDK/JDK; Godot is handled by `install_godot.sh`). See [windows-runners.md](windows-runners.md). |
| `app_name` | string | `export` | Base filename for the output `.apk` (no extension). |
| `android_preset` | string | `Android` | Name of the Godot export preset to use. Must match exactly what's in `export_presets.cfg`. |
| `pre_export_script` | string | _(empty)_ | Optional shell script to run before Godot exports. Use for any code generation the project requires. |
| `version` | string | _(empty)_ | Version to build, from [`release-gate.yml`](versioning.md#release-gateyml). Empty → the workflow computes it itself. Passing it from the gate means every platform job in a release shares one version and one build number. |
| `build` | string | _(empty)_ | Build number, from the release gate. Empty → computed locally. |
| `attach_to_release` | boolean | `false` | Attach the APK to the GitHub Release `v{version}`, creating the release if the Apple jobs haven't yet. Requires `version` to be non-empty. Default `false`, so existing artifact-only callers are unaffected. |

## Secrets

No release-signing secrets required, and none are used. See below for what "debug-signed" means.

## Why the APK is debug-signed

The export runs `--export-debug`, **not** `--export-release`, and that is deliberate:

- A **debug** export is signed with Godot's built-in debug keystore, which is what makes the APK installable by anyone who downloads it (sideloading).
- A **release** export needs a real upload/release keystore, which the org hasn't wired up yet (no Play Console).
- An **unsigned** APK won't install at all, so it would be useless as a downloadable artifact.

Don't "fix" this to `--export-release` without adding keystore secrets first — you'd end up with an APK nobody can install.

## Steps

| Step | Script / Action | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Downloads Godot + export templates. On Linux the binary is the standard `x86_64` build (not a separate headless binary — Godot 4.6 uses the same binary for all modes). |
| Setup Java | `actions/setup-java@v5` | Installs Temurin JDK 17, which Godot's Android exporter requires to invoke Gradle. |
| Setup Android SDK | `android-actions/setup-android@v3` | Installs the Android SDK command-line tools and sets `$ANDROID_SDK_ROOT`. |
| Configure SDK paths | _(inline)_ | Writes `export/android/android_sdk_path` and `export/android/java_sdk_path` into Godot's editor settings file so the exporter can find the SDK without an interactive editor session. |
| Resolve version | `compute_version.sh` | Uses the `version` / `build` inputs when the release gate passed them; otherwise derives them from git tags. See [versioning.md](versioning.md). |
| Apply version | `set_version.sh` | Writes `version/name` (string) and `version/code` (integer) into `export_presets.cfg`. |
| Reimport | `godot_import.sh` | Primes the asset import cache. |
| Pre-export script | _(your script)_ | Only runs if `pre_export_script` is set. |
| Disable gradle_build | _(inline)_ | Sets `gradle_build/use_gradle_build=false` and `gradle_build/export_format=0` (APK) in `export_presets.cfg`. The Gradle build path requires an Android Studio project setup that isn't available in CI; the standard Godot template export works fine. If the project is configured for AAB export (`export_format=1`), Godot refuses to export with Gradle build disabled — resetting to APK avoids that error. |
| Godot export (APK) | _(inline)_ | Calls `godot --headless --export-debug "<android_preset>" build/android/<app_name>.apk`. `--export-debug` is intentional — see [above](#why-the-apk-is-debug-signed). |
| Upload artifact | `actions/upload-artifact@v4` | Attaches the APK to the workflow run. Retained for 14 days. Warns (does not fail) if no APK was produced. |
| Attach APK to GitHub Release | _(inline)_ | Only when `attach_to_release: true`, `version` is non-empty, and the event isn't a pull request. Views the release `v{version}` and creates it if absent (the Apple jobs race for the same release, so this is idempotent), then `gh release upload … --clobber`. Uses `github.token`. |
| Restore presets | _(inline)_ | Always runs. Reverts `export_presets.cfg` to its committed state. |

## Example

Artifact-only (the old behaviour — nothing changes for existing callers):

```yaml
jobs:
  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@v1
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
    secrets: inherit
```

As part of a gated nightly release, with the APK attached to `v{version}`:

```yaml
# .github/workflows/release.yml
name: Release
on:
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:
    inputs:
      bump:
        type: choice
        options: [patch, minor, major]
        default: patch

jobs:
  gate:
    uses: Zebra-Party/pipeline-core/.github/workflows/release-gate.yml@v1
    with:
      bump: ${{ inputs.bump || 'patch' }}

  android:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@v1
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
      attach_to_release: true
    secrets: inherit
```

The attach step uses `github.token`, so the calling workflow must not narrow the token below `contents: write` — the same requirement the Apple release workflows' "Tag release" step already has.

With a pre-export code generation step and a custom preset name:

```yaml
jobs:
  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@v1
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      android_preset: "Android Release"
      pre_export_script: "tools/compile_scenes.sh"
    secrets: inherit
```

## export_presets.cfg requirements

A preset with a name matching `android_preset` must exist. The minimum required options for a working debug export are set by Godot when you add an Android preset in the editor. `version/name` and `version/code` are written by `set_version.sh` at build time — they do not need to be pre-populated.
