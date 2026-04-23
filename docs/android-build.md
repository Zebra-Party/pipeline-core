# Android build workflow

**File:** `.github/workflows/android-build.yml`

Builds an unsigned debug APK and uploads it as a workflow artifact. This is a smoke-test build — it verifies the project exports cleanly for Android but does not sign or publish to the Play Store.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to use. |
| `runner` | string | `"ubuntu-latest"` | Runner label string. Unlike the other workflows this defaults to `ubuntu-latest` (a GitHub-hosted runner) since Android builds don't require macOS or Xcode. |
| `app_name` | string | `export` | Base filename for the output `.apk` (no extension). |
| `android_preset` | string | `Android` | Name of the Godot export preset to use. Must match exactly what's in `export_presets.cfg`. |
| `pre_export_script` | string | _(empty)_ | Optional shell script to run before Godot exports. Use for any code generation the project requires. |

## Secrets

No secrets required. The APK is unsigned — Play Store release signing is not implemented yet.

## Steps

| Step | Script / Action | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Downloads Godot + export templates. On Linux the binary is the standard `x86_64` build (not a separate headless binary — Godot 4.6 uses the same binary for all modes). |
| Setup Java | `actions/setup-java@v5` | Installs Temurin JDK 17, which Godot's Android exporter requires to invoke Gradle. |
| Setup Android SDK | `android-actions/setup-android@v3` | Installs the Android SDK command-line tools and sets `$ANDROID_SDK_ROOT`. |
| Configure SDK paths | _(inline)_ | Writes `export/android/android_sdk_path` and `export/android/java_sdk_path` into Godot's editor settings file so the exporter can find the SDK without an interactive editor session. |
| Compute version | `compute_version.sh` | Derives version and build number from git tags. See [versioning.md](versioning.md). |
| Apply version | `set_version.sh` | Writes `version/name` (string) and `version/code` (integer) into `export_presets.cfg`. |
| Reimport | `godot_import.sh` | Primes the asset import cache. |
| Pre-export script | _(your script)_ | Only runs if `pre_export_script` is set. |
| Disable gradle_build | _(inline)_ | Sets `gradle_build/use_gradle_build=false` in `export_presets.cfg`. The Gradle build path requires an Android Studio project setup that isn't available in CI; the standard Godot template export works fine for smoke testing. |
| Godot export (APK) | _(inline)_ | Calls `godot --headless --export-debug "<android_preset>" build/android/<app_name>.apk`. Uses `--export-debug` (not `--export-release`) since the APK is unsigned. |
| Upload artifact | `actions/upload-artifact@v4` | Attaches the APK to the workflow run. Retained for 14 days. Warns (does not fail) if no APK was produced. |
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
  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
    secrets: inherit
```

With a pre-export code generation step and a custom preset name:

```yaml
jobs:
  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      android_preset: "Android Release"
      pre_export_script: "tools/compile_scenes.sh"
    secrets: inherit
```

## export_presets.cfg requirements

A preset with a name matching `android_preset` must exist. The minimum required options for a working debug export are set by Godot when you add an Android preset in the editor. `version/name` and `version/code` are written by `set_version.sh` at build time — they do not need to be pre-populated.
