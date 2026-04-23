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

There is no automation to cut tags — that stays a conscious decision.

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
