# Release process

How code gets from a feature branch to TestFlight today, and how versions are
numbered along the way. This describes what the workflows in this repo actually
do — see [versioning.md](versioning.md) for the version arithmetic and the
per-workflow pages for build detail.

## Branch model: trunk only

```
main ───●───●───●───●───●───●───●───●   (always green trunk)
         \     \
          \     feat/thing → PR → squash-merge
           fix/other → PR → squash-merge
```

- **`main`** — the only branch that ships. Every push to `main` runs
  `release.yml`, which builds, uploads to TestFlight, and tags the build.
- **Feature branches** — short-lived, named freely (`feat/`, `fix/`, …). Open a
  PR to `main`, squash-merge when CI is green.

There are no release branches, no `develop`, no `staging`. This means **there is
currently no way to patch an already-shipped version while `main` has moved on** —
see [Not implemented](#not-implemented--ideas) below.

## The flow

1. **Feature branch + PR.** `ci.yml` runs the checks for the project type
   (GDScript lint / boot / headless tests, `xcodebuild` builds, `flutter test`,
   …). Green CI to merge.
2. **Squash-merge to `main`.** `release.yml` runs. It computes a version from
   git tags, builds and code-signs, and — on `main` only, never on PRs —
   uploads to TestFlight.
3. **The build tags itself.** After a successful build on `main`, the workflow
   creates a GitHub Release `v{version}` in the calling repo. This anchors the
   patch counter for the next build.
4. **Test from TestFlight.** Builds appear in TestFlight internal testing a few
   minutes after upload. Bugs go back through step 1.
5. **Submit to the App Store.** Done **by hand** in App Store Connect — pick the
   TestFlight build you want and submit it. CI does not submit for review and
   does not know Apple's review outcome.

To move the major/minor baseline (e.g. start calling builds `1.1.x`), tag a
commit `v1.1.0` and push it. Patch numbers take care of themselves.

## What triggers what

| Event | Workflow | Effect |
|---|---|---|
| PR to `main` | `ci.yml` | Lint, tests, build. Never uploads, never tags. |
| Push to `main` | `release.yml` | Build + sign → TestFlight upload → GitHub Release `v{version}`. |
| Manual `workflow_dispatch` | `release.yml` | Same as a push to `main`. |
| Push of a `vX.Y.0` tag | _(none)_ | Nothing automated. The tag only changes what the **next** build computes as its version. |

Signing and upload steps skip gracefully with a warning when their secrets are
absent, so the workflows are safe to run on forks and in repos where Apple
credentials aren't wired up yet.

## Where things are visible

| Question | Where to look today |
|---|---|
| What's on TestFlight? | App Store Connect, or the latest `main` run in Actions. |
| What did that build number correspond to? | The `v{version}` GitHub Release created by the run. |
| What versions have shipped? | `git tag -l 'v*'` in the consumer repo. |
| What's in review / live? | App Store Connect only. CI has no view of this. |

---

## Not implemented / ideas

None of the following exists. It's recorded because the limitation it addresses
is real, and because it's the shape the process would most likely grow into.

### Release branches for hotfixes

The gap: `compute_version.sh` computes the patch as "commits since the latest
`v*` tag" — the **globally** latest tag, not the latest one reachable from the
current branch. That works fine on a single trunk, and breaks the moment a
release branch lives alongside `main`:

- Tag `v1.2.0` on `main`. Main gains 10 commits, tagged `v1.3.0`. A hotfix
  branch off `v1.2.0` would see `v1.3.0` as the latest tag and try to build
  `1.3.1`. Wrong.

The fix, if release branches are ever wanted, is to anchor on the nearest
`vX.Y.0` in the current branch's ancestry rather than the global latest:

```bash
BASE_TAG="$(git describe --tags --match 'v*.*.0' --abbrev=0 HEAD)"
IFS='.' read -r MAJOR MINOR _ <<< "${BASE_TAG#v}"
PATCH="$(git rev-list "${BASE_TAG}..HEAD" --count)"
VERSION="${MAJOR}.${MINOR}.${PATCH}"
```

With that in place, a `release/X.Y` branch (cut from the `vX.Y.0` tag, taking
only cherry-picks from `main`) could carry a patch line independently of trunk.
Until then, patching a live version means shipping from `main`.

### Deployment environments as a "what's where" dashboard

Three GitHub Environments — `testflight-internal`, `app-store-review`,
`app-store-live` — would let GitHub's Deployments UI show the latest build per
channel on the repo home page, instead of that state living only in App Store
Connect. The `app-store-live` marker would have to be recorded manually, since
CI can't know Apple's review outcome.

### Automated submit-to-review

`altool --upload-app` only gets a build **into** App Store Connect. Actually
asking Apple to review it is a separate App Store Connect API call
(`appStoreVersionSubmissions`), which could live next to `upload_ios.sh` as a
tag-triggered step.

### Android release

`android-build.yml` produces an **unsigned debug APK** as a workflow artifact —
a smoke test that the project exports, nothing more. Release signing and Play
Store publishing are not implemented; that needs Play Console setup and an
upload key first.
