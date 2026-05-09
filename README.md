# pipeline-core

Shared GitHub Actions workflows and scripts for Godot 4 projects in the Zebra-Party org. Game repos call into these workflows via `workflow_call` — one place to fix a CI bug and every project picks it up.

## How it works

Each game repo calls a reusable workflow here. The workflow does a secondary checkout of this repo into `.pipeline-core/` so every script is available at a predictable path inside the running job, regardless of what the game repo contains.

```
game repo job
├── actions/checkout             ← game repo code
├── actions/checkout@pipeline-core → .pipeline-core/   ← this repo
└── bash .pipeline-core/scripts/install_godot.sh …
    bash .pipeline-core/scripts/lint.sh …
    …
```

Updating a script or workflow here takes effect on the next run in every consumer — no changes needed in the game repos.

## Workflows

| Workflow | Purpose | Docs |
|---|---|---|
| `gdscript-ci.yml` | Lint, reimport, boot every scene, headless tests, PR screenshots | [docs/gdscript-ci.md](docs/gdscript-ci.md) |
| `ios-release.yml` | Godot — code-sign and export IPA, upload to TestFlight | [docs/ios-release.md](docs/ios-release.md) |
| `macos-release.yml` | Godot — code-sign, export .app + .pkg, upload to TestFlight | [docs/macos-release.md](docs/macos-release.md) |
| `android-build.yml` | Godot — export unsigned debug APK, upload as artifact | [docs/android-build.md](docs/android-build.md) |
| `xcode-release.yml` | Native Xcode (iOS/macOS/tvOS) — code-sign + TestFlight upload | — |
| `flutter-ios-release.yml` | Flutter iOS — code-sign IPA, upload to TestFlight | [docs/flutter-ios-release.md](docs/flutter-ios-release.md) |

## Quick start

A typical game repo needs two workflow files. Adjust `godot_version`, `lint_dirs`, `scene_dir`, and `app_name` for the project.

**`.github/workflows/ci.yml`** — runs on every PR:

```yaml
name: CI
on:
  pull_request:

concurrency:
  group: ci-${{ github.head_ref }}
  cancel-in-progress: true

jobs:
  gdscript:
    uses: Zebra-Party/pipeline-core/.github/workflows/gdscript-ci.yml@main
    permissions:
      contents: write      # needed to push screenshots to ci-screenshots branch
      pull-requests: write # needed to post the screenshot PR comment
    with:
      godot_version: "4.6.2-stable"
      lint_dirs: "scripts tools test"
      scene_dir: "scenes"
      test_pattern: "test/_test_*.gd"
    secrets: inherit
```

**`.github/workflows/release.yml`** — runs on every merge to main:

```yaml
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  ios:
    uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      upload_to_testflight: true
    secrets: inherit

  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@main
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
    secrets: inherit
```

If the project has a pre-build step (e.g. a .NET scene compiler), pass it via `pre_test_script` / `pre_export_script`:

```yaml
    with:
      pre_test_script: "tools/compile_scenes.sh"    # gdscript-ci
      pre_export_script: "tools/compile_scenes.sh"  # ios / macos / android
```

## Versioning

See [docs/versioning.md](docs/versioning.md).

## Repository layout

```
.github/workflows/   reusable workflow_call definitions
scripts/             bash scripts called by the workflows
screenshot/          generic screenshot harness (copy into each game project)
docs/                reference documentation
```
