# Versioning

The release workflows compute a version automatically from git tags and write it into the project before every build. You never hand-edit version numbers in source control.

## The release model: nightly, gated

Releases are **not** cut on every push to `main`. A consumer repo schedules a nightly release (plus a `workflow_dispatch` for an on-demand one), and the first job of that workflow is the shared **release gate**:

```yaml
name: Release
on:
  schedule:
    - cron: "0 3 * * *"   # nightly
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

  ios:
    needs: gate
    if: needs.gate.outputs.release == 'true'
    uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@v1
    with:
      app_name: "MyGame"
      version: ${{ needs.gate.outputs.version }}
      build: ${{ needs.gate.outputs.build }}
    secrets: inherit
```

Why the gate exists:

- **A quiet night costs nothing.** The gate runs on a free GitHub-hosted `ubuntu-latest` runner. If nobody merged anything, it returns `release=false` and the expensive self-hosted platform jobs never start — the macOS pool is never woken.
- **One version, one build number, all platforms.** The gate computes them **once** and passes them down, so the iOS, macOS, tvOS and Android jobs of a single release all ship the same `X.Y.Z` and the same build number, instead of each recomputing (and possibly disagreeing).

### `release-gate.yml`

**Inputs**

| Input | Type | Default | Description |
|---|---|---|---|
| `bump` | string | `patch` | `patch` \| `minor` \| `major`. Passed straight to `compute_version.sh` as `BUMP`. |

**Outputs**

| Output | Description |
|---|---|
| `release` | `true` when there's something to ship, `false` on a quiet night. Gate every platform job on this. |
| `version` | The computed `X.Y.Z`. Pass to each platform job's `version` input. |
| `build` | The build number (a unix timestamp). Pass to each platform job's `build` input. |

Every platform workflow (`ios-release.yml`, `macos-release.yml`, `xcode-release.yml`, `flutter-ios-release.yml`, `android-build.yml`) takes matching **`version`** and **`build`** inputs. They're optional: if left empty the workflow runs `compute_version.sh` itself, which is what keeps pre-gate callers working unchanged.

## How the version is computed

### Version string (X.Y.Z)

`compute_version.sh` takes a `BUMP` (`patch` — the default and what the nightly uses — `minor`, or `major`) and the most recent `v*` tag as the baseline:

| Bump | Result |
|---|---|
| `patch` | baseline patch **+ the number of commits since the tag** |
| `minor` | `MAJOR.(MINOR+1).0` |
| `major` | `(MAJOR+1).0.0` |

```
baseline v0.2.0 + 3 commits, BUMP=patch  ->  0.2.3
baseline v0.2.3,             BUMP=minor  ->  0.3.0
baseline v0.2.3,             BUMP=major  ->  1.0.0
```

Because every release tags itself (see below), the next night's baseline is the tag just cut — the patch carries forward and keeps climbing.

**A `patch` bump with no new commits is a no-op.** `compute_version.sh` emits `release=false`, the gate propagates it, and the whole release is skipped. Nothing is built, nothing is uploaded, no tag is cut. `minor` and `major` always release, even with zero new commits (that's how you re-baseline a version deliberately).

If **no** `v*` tag exists at all, the script seeds a clean `0.2.0` baseline. It deliberately does *not* fall back to counting every commit in the repo — that yields a nonsense patch like `0.1.<total commits>` that can outrank a real version.

### Build number

The build number is a **unix timestamp** (`date -u +%s`).

App Store Connect requires the build number to strictly increase for a given version string, or it rejects the upload. The build number used to be `github.run_number` — that turned out to be unsafe: GitHub does **not** increment `run_number` when you *re-run* a workflow (it bumps `run_attempt` instead), so a re-run resubmitted an already-used build number and the upload was rejected. A timestamp is monotonic and re-run-safe.

## How to bump the version

For a `minor` or `major` release, run the consumer repo's Release workflow via **workflow_dispatch** and pick the bump. The version is computed, built, and tagged for you — you don't need to create the tag by hand:

- `minor` → `1.0.7` becomes `1.1.0`
- `major` → `1.0.7` becomes `2.0.0`

Every subsequent nightly `patch` release then climbs from that new baseline (`1.1.1`, `1.1.2`, …).

## Automatic release tagging

After every successful release build, the release workflows (`ios-release.yml`, `macos-release.yml`, `xcode-release.yml`, `flutter-ios-release.yml`) create a GitHub Release `v{version}` — and therefore a git tag — in the **calling repo**, using the version they just built.

The step is idempotent: if `v{version}` already exists it is skipped, so parallel platform jobs building the same commit don't collide, and a re-run doesn't fail. `android-build.yml` joins the same race when `attach_to_release: true` — it creates the release if the Apple jobs haven't yet, then uploads the APK with `--clobber`.

This is what keeps the patch counter honest. A `patch` bump counts commits since the latest `v*` tag, so without these tags the count would climb forever from the last manual tag. With them, the tag tracks what was actually shipped.

### What lands in the release

- **Apple builds go to TestFlight, not to the release.** An App-Store-signed IPA/`.pkg` isn't installable from a download, so there is nothing useful to attach. The release notes instead carry a line saying the builds for that version are on TestFlight, above the generated changelog.
- **The Android APK *is* attached** when the caller passes `attach_to_release: true` — it's debug-signed and therefore directly sideloadable. See [android-build.md](android-build.md).

Two consequences worth knowing:

- **Tags mark builds, not decisions.** A `v1.0.7` tag means "this commit was built and (usually) uploaded", not "someone chose to release 1.0.7".
- **Only release runs tag.** The release jobs' tag step runs on `main` and on `v*` tag pushes, never on pull requests. PR builds compute a version but never create a release.

## Where it gets written

`set_version.sh` applies the computed version to two files in-place, then the workflow restores them with `git checkout` at the end so the working tree stays clean.

### `project.godot`

```ini
config/version="1.0.7"
```

Used for the in-game About screen or any `ProjectSettings.get_setting("application/config/version")` call.

### `export_presets.cfg`

The script rewrites all of the following fields that are present (it is safe to have only some of them):

| Field | Value written |
|---|---|
| `application/short_version` | `X.Y.Z` |
| `application/version` | build number |
| `version/name` | `X.Y.Z` |
| `version/code` | build number |

These map to the store-facing version string and the internal build code on both iOS (CFBundleShortVersionString / CFBundleVersion) and Android (versionName / versionCode).

---

# Versioning pipeline-core itself

The above is about the version of the **app being built**. pipeline-core also versions **itself**, because consumer repos pin the workflow ref they call.

## The floating major tag

Consumers pin to the floating major tag — **`@v1`**, not `@main` and not a specific patch:

```yaml
uses: Zebra-Party/pipeline-core/.github/workflows/ios-release.yml@v1
```

`v1` is a movable tag that always points at the latest `1.x.y` release. So:

- **Patch and minor releases arrive automatically.** Fix a bug here, cut a release, and every consumer picks it up on its next run with no PR in the consumer repo. That's the whole point of the shared pipeline.
- **Breaking changes don't.** A new required input, a removed output, or changed behaviour bumps the **major** version. `v2` is a different tag, so `@v1` consumers keep working until someone deliberately repoints them.

Inside the workflows, the second checkout that fetches this repo into `.pipeline-core/` also pins `ref: v1`, so the scripts a job runs always match the workflow that called them. (It deliberately does *not* use `github.workflow_sha` — in a `workflow_call` context that resolves to the **caller's** commit, which isn't a ref in this repo.)

## Cutting a release

Run the [Tag Release](https://github.com/Zebra-Party/pipeline-core/actions/workflows/tag-release.yml) workflow (`tag-release.yml`, `workflow_dispatch`) from `main`:

| Input | Description |
|---|---|
| `version` | The semver to release, without the `v` prefix — e.g. `1.0.3`. Validated against `X.Y.Z`. |
| `update_floating_tag` | Whether to move the floating major tag (`v1`, `v2`, …) to this release. Default `true`. |

It creates the GitHub Release (with generated notes) at `HEAD` of `main`, then force-updates the major tag so `@v1` consumers pick the change up on their next run.

For a **patch**, cherry-pick the fix onto `main` and run the workflow; the floating tag follows. For a **breaking change**, release `2.0.0` and update consumer repos to `@v2` by hand.

Notable changes are recorded in [CHANGELOG.md](../CHANGELOG.md).
