# pipeline-core

Shared GitHub Actions workflows and scripts for all Zebra-Party projects — Godot games, Flutter apps, and native Xcode (iOS/macOS/tvOS) builds. Consumer repos call into these workflows via `workflow_call` — one place to fix a CI bug and every project picks it up.

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
| `release-gate.yml` | Decides whether tonight's release happens; computes the version + build number once, for every platform job | [docs/versioning.md](docs/versioning.md#release-gateyml) |
| `ios-release.yml` | Godot — code-sign and export IPA, upload to TestFlight | [docs/ios-release.md](docs/ios-release.md) |
| `macos-release.yml` | Godot — code-sign, export .app + .pkg, upload to TestFlight | [docs/macos-release.md](docs/macos-release.md) |
| `android-build.yml` | Godot — export debug-signed (sideloadable) APK; artifact, and optionally attached to the GitHub Release | [docs/android-build.md](docs/android-build.md) |
| `xcode-release.yml` | Native Xcode (iOS/macOS/tvOS) — code-sign + TestFlight upload | [docs/xcode-release.md](docs/xcode-release.md) |
| `flutter-ios-release.yml` | Flutter iOS — code-sign IPA, upload to TestFlight | [docs/flutter-ios-release.md](docs/flutter-ios-release.md) |

## Runners

Every workflow takes a **`runner`** input (JSON array of labels), defaulting to the org's
ephemeral macOS pool. Non-Apple jobs can be routed to a **self-hosted Windows runner** by
overriding it — see [docs/windows-runners.md](docs/windows-runners.md).

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
    uses: Zebra-Party/pipeline-core/.github/workflows/gdscript-ci.yml@v1
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

**`.github/workflows/release.yml`** — a **nightly** release (not one per merge), gated so a quiet night costs nothing:

```yaml
name: Release
on:
  schedule:
    - cron: "0 3 * * *"      # nightly
  workflow_dispatch:          # or on demand, with a bump
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
  # Runs on free ubuntu. Computes the version + build number ONCE, and answers
  # "is there anything new to ship?" — a patch bump with no new commits is a
  # no-op, and the self-hosted platform jobs below never start.
  gate:
    uses: Zebra-Party/pipeline-core/.github/workflows/release-gate.yml@v1
    with:
      bump: ${{ inputs.bump || 'patch' }}

  ios:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@v1
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      upload_to_testflight: true
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
    secrets: inherit

  android:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@v1
    with:
      godot_version: "4.6.2-stable"
      app_name: "MyGame"
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
      attach_to_release: true   # sideloadable APK on the GitHub Release
    secrets: inherit
```

Passing `version` / `build` down from the gate is what makes every platform job in a release share **one** version string and **one** build number. Both inputs are optional — omit them and each workflow computes its own (the pre-gate behaviour).

If the project has a pre-build step (e.g. a scene compiler that generates `.tscn` files from source), pass it via `pre_test_script` / `pre_export_script`:

```yaml
    with:
      pre_test_script: "tools/compile_scenes.sh"    # gdscript-ci
      pre_export_script: "tools/compile_scenes.sh"  # ios / macos / android
```

## Versioning

Consumers pin to the floating major tag **`@v1`** (as in the snippets above), so patch
and minor fixes here reach every repo automatically while breaking changes wait for a
deliberate bump to `@v2`.

- [docs/versioning.md](docs/versioning.md) — the nightly + gate release model, how a
  build's `X.Y.Z` is computed from the `bump`, why build numbers are unix timestamps
  (`github.run_number` doesn't increment on a re-run, so re-runs collided in App Store
  Connect), the automatic `v{version}` release each successful release build cuts in the
  calling repo, and how to cut a pipeline-core release.
- [docs/release-process.md](docs/release-process.md) — how code gets from a PR to
  TestFlight.

## Repository layout

```
.github/workflows/   reusable workflow_call definitions
scripts/             bash scripts called by the workflows
screenshot/          generic screenshot harness (copy into each game project)
docs/                reference documentation
```
