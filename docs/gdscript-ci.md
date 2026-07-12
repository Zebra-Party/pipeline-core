# GDScript CI workflow

**File:** `.github/workflows/gdscript-ci.yml`

Runs GDScript lint, asset reimport, scene boot checks, headless tests, and (on PRs) screenshot capture. Designed to run on every pull request as a quality gate before merge.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to download and use. Must match the version used to author the project. |
| `runner` | string | `["self-hosted","macOS","ephemeral"]` | JSON array of runner labels. Defaults to the org's ephemeral macOS pool. Override to route the job to another pool — see [windows-runners.md](windows-runners.md). |
| `lint_dirs` | string | `scripts tools test` | Space-separated directories passed to `gdformat` and `gdlint`. Set to the root of your GDScript sources (e.g. `src` or `scripts tools test`). |
| `scene_dir` | string | `scenes` | Root directory searched recursively for `.tscn` files to boot. |
| `test_pattern` | string | `test/_test_*.gd` | Glob pattern for headless test scripts. Set to `""` if you have no tests yet — the step skips cleanly when nothing matches. |
| `pre_test_script` | string | _(empty)_ | Optional path to a shell script to run before linting and tests. Use this if your project has a code-generation step that must run first (e.g. `tools/compile_scenes.sh`). Also runs in the `screenshots` job, before capture. |
| `strict_tests` | boolean | `false` | Fail a test that prints `SCRIPT ERROR` even if it exits 0, catching swallowed false passes. Off by default; opt in once a repo's tests are error-clean. |
| `screenshot_scene_glob` | string | `scenes/**/*.tscn` | Space-separated glob(s) passed to `screenshot_scenes.sh` as `SCENE_GLOB`. `**` is supported (globstar). |

## Secrets

No secrets required. The workflow uses `GITHUB_TOKEN` (automatically provided by Actions) to push screenshots and post PR comments.

The calling job must declare the permissions the token needs:

```yaml
permissions:
  contents: write      # push to the ci-screenshots orphan branch
  pull-requests: write # post the screenshot comment
```

## Jobs

### `test`

Runs on every PR and push.

| Step | Script | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Downloads the Godot binary and export templates into a per-runner cache (`$RUNNER_TOOL_CACHE/godot/`). Skips download on subsequent runs if the version is already cached. Sets `$GODOT` and `$GODOT_HOME` for later steps. |
| Pre-test script | _(your script)_ | Only runs if `pre_test_script` is set. Runs before anything else so generated files are in place for lint and import. |
| Verify shared font assets | `verify_shared_assets.sh` | Checks the project's `fonts/` directory against the reference checksums in `shared-asset-checksums.txt` in this repo, so a font that drifts in one consumer repo is caught rather than silently diverging. Skips cleanly for projects with no `fonts/` directory. |
| Lint | `lint.sh` | Installs `gdtoolkit` via `uv` into a per-runner cache. Runs `gdformat --check` (fails if any file would be reformatted) then `gdlint` (fails on style violations). Fix locally with `gdformat <lint_dirs>`. |
| Reimport | `godot_import.sh` | Runs `godot --headless --editor --quit-after 60` to force Godot to regenerate `.godot/imported/` sidecars and register `class_name` globals. Retries once if a resource-ordering race is detected. |
| Boot every scene | `boot_scenes.sh` | Launches each `.tscn` found under `scene_dir` for up to 60 seconds, scanning output for `ERROR:`, `SCRIPT ERROR`, and `Parse Error`. Fails the step if any scene produces errors. This catches broken `@onready` paths, missing nodes, and runtime parse errors that the import step doesn't surface. |
| Run headless tests | `run_tests.sh` | Runs every GDScript file matched by `test_pattern`. Each file must `extend SceneTree` and call `quit(0)` on success or `quit(1)` on failure. Exits cleanly (not as a failure) if no files match the pattern. |

### `screenshots`

Runs only on pull requests from the same repo (skipped on forks and on direct pushes). Requires the `test` job to pass first.

> **Screenshots do not currently run on the default runner.** Capture needs `xvfb-run` to give Godot a GL context, and macOS has no xvfb. On a macOS runner `screenshot_scenes.sh` prints a warning and exits 0, so the job goes green having captured nothing and the PR comment is never posted. Since the default `runner` is the ephemeral **macOS** pool, that is what happens unless you point `runner` at a Linux host with xvfb installed. Everything else in the job (lint, boot, tests) is unaffected.

| Step | Script | What it does |
|---|---|---|
| Install Godot | `install_godot.sh` | Same per-runner cached install as the `test` job. |
| Pre-screenshot script | _(your script)_ | Only runs if `pre_test_script` is set — the screenshot job needs the same generated files the test job does. |
| Capture screenshots | `screenshot_scenes.sh` | Renders each scene matched by `screenshot_scene_glob` at multiple resolutions using `xvfb-run` + Godot's OpenGL3 driver. Writes one PNG per (scene × device) to `build/screenshots/`. Uses `tools/ci/screenshot_harness.tscn` as the rendering entry point — this file must exist in the game project (copy from `screenshot/` in this repo). Skips with a warning on macOS runners, which have no `xvfb-run`. |
| Publish to PR | `publish_screenshots.sh` | Pushes the PNGs to an orphan `ci-screenshots` branch and posts (or updates) a PR comment with a link to the gallery. The gallery is a rendered `index.md` on the `ci-screenshots` branch whose `<img>` tags are proxied through GitHub's authenticated camo CDN, making them visible in private repos. |

## Example

A project with GDScript in `src/` and a scene-compiler code-generation step:

```yaml
# .github/workflows/ci.yml
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
      contents: write
      pull-requests: write
    with:
      godot_version: "4.6.2-stable"
      lint_dirs: "src"
      scene_dir: "scenes"
      test_pattern: "test/_test_*.gd"
      pre_test_script: "tools/compile_scenes.sh"
    secrets: inherit
```

A simpler project with the default directory layout:

```yaml
jobs:
  gdscript:
    uses: Zebra-Party/pipeline-core/.github/workflows/gdscript-ci.yml@v1
    permissions:
      contents: write
      pull-requests: write
    with:
      godot_version: "4.6.2-stable"
    secrets: inherit
```

## Screenshot harness setup

The screenshot job expects `res://tools/ci/screenshot_harness.tscn` to exist in the game project. Copy it from `screenshot/harness.tscn` in this repo and place it at that path. The `.gd` file it references should live alongside it at `tools/ci/screenshot_harness.gd`.

No other project changes are needed — the harness renders the scene passed via `--scene=` and writes the output PNG to `--out=`.
