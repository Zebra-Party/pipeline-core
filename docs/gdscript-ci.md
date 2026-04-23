# GDScript CI workflow

**File:** `.github/workflows/gdscript-ci.yml`

Runs GDScript lint, asset reimport, scene boot checks, headless tests, and (on PRs) screenshot capture. Designed to run on every pull request as a quality gate before merge.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `godot_version` | string | `4.6.2-stable` | Godot release to download and use. Must match the version used to author the project. |
| `runner` | string | `["self-hosted","Linux","X64"]` | JSON array of runner labels. Override to use a different runner pool. |
| `lint_dirs` | string | `scripts tools test` | Space-separated directories passed to `gdformat` and `gdlint`. Set to the root of your GDScript sources (e.g. `src` or `scripts tools test`). |
| `scene_dir` | string | `scenes` | Root directory searched recursively for `.tscn` files to boot. |
| `test_pattern` | string | `test/_test_*.gd` | Glob pattern for headless test scripts. Set to `""` if you have no tests yet — the step skips cleanly when nothing matches. |
| `pre_test_script` | string | _(empty)_ | Optional path to a shell script to run before linting and tests. Use this if your project has a code-generation step that must run first (e.g. `tools/compile_scenes.sh`). |
| `clean_checkout` | boolean | `false` | When `true`, wipes the workspace before checkout. Set `false` on self-hosted runners to preserve the `.godot/` asset import cache between runs. |

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
| Lint | `lint.sh` | Installs `gdtoolkit` via `uv` into a per-runner cache. Runs `gdformat --check` (fails if any file would be reformatted) then `gdlint` (fails on style violations). Fix locally with `gdformat <lint_dirs>`. |
| Reimport | `godot_import.sh` | Runs `godot --headless --editor --quit-after 60` to force Godot to regenerate `.godot/imported/` sidecars and register `class_name` globals. Retries once if a resource-ordering race is detected. |
| Boot every scene | `boot_scenes.sh` | Launches each `.tscn` found under `scene_dir` for up to 60 seconds, scanning output for `ERROR:`, `SCRIPT ERROR`, and `Parse Error`. Fails the step if any scene produces errors. This catches broken `@onready` paths, missing nodes, and runtime parse errors that the import step doesn't surface. |
| Run headless tests | `run_tests.sh` | Runs every GDScript file matched by `test_pattern`. Each file must `extend SceneTree` and call `quit(0)` on success or `quit(1)` on failure. Exits cleanly (not as a failure) if no files match the pattern. |

### `screenshots`

Runs only on pull requests from the same repo (skipped on forks and on direct pushes). Requires the `test` job to pass first.

| Step | Script | What it does |
|---|---|---|
| Capture screenshots | `screenshot_scenes.sh` | Renders each scene at multiple resolutions using `xvfb-run` + Godot's OpenGL3 driver. Writes one PNG per (scene × device) to `build/screenshots/`. Uses `tools/ci/screenshot_harness.tscn` as the rendering entry point — this file must exist in the game project (copy from `screenshot/` in this repo). |
| Upload artifact | actions/upload-artifact | Attaches `build/screenshots/` to the workflow run for direct download. |
| Publish to PR | `publish_screenshots.sh` | Pushes the PNGs to an orphan `ci-screenshots` branch and posts (or updates) a PR comment with a link to the gallery. The gallery is a rendered `index.md` on the `ci-screenshots` branch whose `<img>` tags are proxied through GitHub's authenticated camo CDN, making them visible in private repos. |

## Example

A project with GDScript in `src/` and a .NET scene compiler:

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
    uses: Zebra-Party/pipeline-core/.github/workflows/gdscript-ci.yml@main
    permissions:
      contents: write
      pull-requests: write
    with:
      godot_version: "4.6.2-stable"
      lint_dirs: "src"
      scene_dir: "scenes"
      test_pattern: "test/_test_*.gd"
      pre_test_script: "tools/compile_scenes.sh"
      clean_checkout: false
    secrets: inherit
```

A simpler project with the default directory layout:

```yaml
jobs:
  gdscript:
    uses: Zebra-Party/pipeline-core/.github/workflows/gdscript-ci.yml@main
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
