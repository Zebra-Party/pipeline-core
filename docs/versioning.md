# Versioning

The release workflows compute a version automatically from git tags and write it into the project before every build. You never hand-edit version numbers in source control.

## How the version is computed

### Version string (X.Y.Z)

`compute_version.sh` finds the most recent `v*` tag reachable from HEAD:

```
tag v0.3.0  →  base is 0.3.0
              + N commits since that tag
              = 0.3.N
```

- **Major and minor** (`X.Y`) come from the tag and only change when you create a new tag.
- **Patch** (`Z`) is the number of commits since that tag and increments automatically on every merge.

If no tag exists at all, the base is `0.1.0` and the patch is the total commit count on the branch.

**Examples:**

| Situation | Version |
|---|---|
| Tag `v1.0.0`, 0 commits since | `1.0.0` |
| Tag `v1.0.0`, 3 commits since | `1.0.3` |
| Tag `v2.1.0`, 17 commits since | `2.1.17` |
| No tag, 42 commits total | `0.1.42` |

### Build number

The build number is `GITHUB_RUN_NUMBER` — a monotonically increasing integer that the Actions runner assigns to every workflow run, regardless of branch. App stores (iOS, macOS, Android) require the build number to increase with every submission; this guarantees that without any manual tracking.

## How to bump the version

To ship `1.0.0`, tag the commit you want to be the base and push:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Every subsequent merge increments the patch automatically (`1.0.1`, `1.0.2`, …). When you're ready for `1.1.0`, tag again.

Tagging by hand is only needed to move the **major/minor** baseline. The patch line tags itself:

## Automatic release tagging

After every successful build on `main`, the release workflows (`ios-release.yml`, `macos-release.yml`, `xcode-release.yml`, `flutter-ios-release.yml`) create a GitHub Release `v{version}` — and therefore a git tag — in the **calling repo**, using the version they just built.

The step is idempotent: if `v{version}` already exists it is skipped, so parallel platform jobs building the same commit don't collide, and a re-run doesn't fail.

This is what keeps the patch counter honest. `compute_version.sh` counts commits since the latest `v*` tag, so without these tags the count would climb forever from the last manual tag. With them, the tag tracks what was actually shipped.

Two consequences worth knowing:

- **Tags mark builds, not decisions.** A `v1.0.7` tag means "this commit was built and (usually) uploaded", not "someone chose to release 1.0.7".
- **Only `main` builds tag.** PR builds compute a version but never create a release.

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
