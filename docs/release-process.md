# Release process

This doc is the source of truth for how versions are numbered, how code moves
from a feature branch to TestFlight to the App Store, and how to patch a
version that's already out in the wild. The same model is intended to apply
to every app in the portfolio; the shared bits (version script, workflow
skeletons) will live in a separate CI/CD template repo and each app will
consume them.

## Branch model (trunk + release branches)

```
main ───●───●───●───●───●───●───●───●───●───●   (always green trunk)
         \               \
          \               tag v1.3.0 → cuts ↓
           \              release/1.3 ───●───●  (hotfix line)
            \                            └─ tag v1.3.1
             \
              tag v1.2.0 → cut earlier
              release/1.2 ───●             (hotfix line)
                             └─ tag v1.2.1
```

- **`main`** — the only place new features land. Always deployable. Every merge
  to `main` triggers a TestFlight "internal testing" upload.
- **`release/X.Y`** — one per minor version that's been shipped or submitted
  for review. Created by CI when `vX.Y.0` is tagged on `main`. Only hotfixes
  (cherry-picked from `main`) land here.
- **Feature branches** — short-lived, named freely (`feat/`, `fix/`, etc.).
  Open a PR to `main`, squash-merge when green.

No `develop`, no `hotfix/*`, no `staging`. Release branches ARE the patch line
and ARE the "what's shipped" record — keeping the list short and readable.

## Version scheme

Three-part semver plus an opaque store build number:

```
1.2.3 (build 4567)
│ │ │       │
│ │ │       └── github.run_number — monotonically increasing across all runs
│ │ │           in the repo. Required by both stores.
│ │ │
│ │ └── patch — commits on *this branch* since the most recent vX.Y.0 tag.
│ │             (Not "commits on main" — see "Why the patch rule changes".)
│ │
│ └── minor — bumped manually by tagging vX.Y.0 on `main`.
│
└── major — bumped manually by tagging v(X+1).0.0 on `main`.
```

### Why the patch rule changes

The current script ([pipeline-core/scripts/compute_version.sh](https://github.com/Zebra-Party/pipeline-core/blob/main/scripts/compute_version.sh))
computes patch as "commits since the latest `v*` tag", which works on a single
branch but breaks as soon as you have a release branch living alongside `main`:

- Tag `v1.2.0` on `main`. Main picks up 10 new commits, tagged `v1.3.0`.
  `release/1.2` branches from `v1.2.0` and gets 1 hotfix cherry-picked.
- Without the fix: the hotfix on `release/1.2` sees `v1.3.0` as the nearest
  tag and tries to build `1.3.1`. Wrong.
- With the fix: the script looks for the nearest `vX.Y.0` tag in the current
  branch's ancestry (`git describe --tags --match 'v*.*.0' --abbrev=0 HEAD`),
  which on `release/1.2` is `v1.2.0`, producing `1.2.1`.

Rough shape of the replacement logic (implementation lives in the shared
CI/CD repo):

```bash
# Nearest vX.Y.0 reachable from HEAD (NOT the global "latest tag").
BASE_TAG="$(git describe --tags --match 'v*.*.0' --abbrev=0 HEAD)"
BASE_VERSION="${BASE_TAG#v}"                     # e.g. 1.2.0
IFS='.' read -r MAJOR MINOR _ <<< "$BASE_VERSION"

# Patch = commits on this branch since the vX.Y.0 tag.
PATCH="$(git rev-list "${BASE_TAG}..HEAD" --count)"

VERSION="${MAJOR}.${MINOR}.${PATCH}"
BUILD="${GITHUB_RUN_NUMBER}"
```

`vX.Y.Z` tags with Z > 0 are informational — they mark shipped builds but
don't affect version computation (the count keeps climbing from `vX.Y.0`).

## Channels and how you reach them

Three channels, one GitHub Environment each. GitHub's **Deployments** UI then
shows the latest successful deploy per channel on the repo home page — that's
the "what's where" dashboard, free.

| Environment | Channel | Who sees it | Reached by |
|---|---|---|---|
| `testflight-internal` | TestFlight (internal group only) | Devs + close testers | Every push to `main` or `release/*` |
| `app-store-review` | Under Apple review | Apple reviewers | Pushing a `v*` tag |
| `app-store-live` | Public App Store | Everyone | Manual — marked after Apple approves |

TestFlight external groups are a fourth tier some teams care about. Start
without them; add `testflight-external` as its own environment later if
needed.

### The `app-store-live` environment is manual on purpose

Apple's review outcome isn't something CI knows about. When a build is
approved and goes live, record it by manually creating a deployment against
the `app-store-live` environment (one-line `gh api` call, documented below).
That gives the Deployments UI a truthful "live in prod" marker without us
guessing from webhook state.

## The flows

### Normal feature → TestFlight → review → live

1. **Feature branch + PR** — green CI required to merge.
2. **Merge to `main`** — `release.yml` runs. Uploads to TestFlight internal;
   build shows up in TF ~5 min later.
3. **Internal testing** — team dogfoods the TF build. Bugs go back through
   step 1.
4. **Cut the release** — when a TF build is good:
   ```sh
   git checkout main
   git pull
   git tag v1.3.0 <sha-of-golden-build>
   git push origin v1.3.0
   ```
   A tag-triggered workflow:
   - Creates `release/1.3` branch from the same SHA (if absent).
   - Rebuilds from the tag (CI runs idempotent — same commit, same build
     number in semver terms but a fresh `run_number`).
   - Uploads and submits to App Store review via App Store Connect API.
   - Records a deployment against `app-store-review`.
5. **Apple review** — outside of CI. When approved/rejected, respond in
   App Store Connect.
6. **Mark live** — once the version is approved and released:
   ```sh
   gh api repos/:owner/:repo/deployments \
     -f ref=v1.3.0 -f environment=app-store-live \
     -f auto_merge=false -f required_contexts='[]'
   ```
   (Wrap this in a `tools/ci/mark_live.sh` helper so no one has to remember
   the flags.)

### Hotfix against a live version

Scenario: `main` is working toward 1.4; a crash is reported against live 1.3.

1. **Fix on `main` first.** Same PR flow as any bug. This guarantees the fix
   is in future versions too — no forgetting to forward-port.
2. **Cherry-pick to the release branch:**
   ```sh
   git checkout release/1.3
   git pull
   git cherry-pick <sha-of-fix-on-main>
   git push origin release/1.3
   ```
   Push triggers `release.yml`, which uploads a fresh TestFlight build
   tagged against the 1.3 line. Version comes out as `1.3.1` (one commit
   past `v1.3.0` on this branch).
3. **Tag and submit:**
   ```sh
   git tag v1.3.1
   git push origin v1.3.1
   ```
   Tag-triggered workflow submits `1.3.1` to review.
4. **Mark live** once approved (same `gh api` call, `v1.3.1`).

### Emergency: hotfix without a TestFlight pass

Short-circuit step 2's "push to release branch → TestFlight → test → tag".
Tag directly after cherry-pick. Same workflow runs, same upload, just skips
the human TF check. Policy call, not a tooling change.

## What triggers what

One release workflow, three trigger branches:

```yaml
on:
  push:
    branches: [main, 'release/*']   # → TestFlight internal
    tags: ['v*']                    # → App Store review
```

The job graph:

```
 push to main / release/*            push of v* tag
            │                             │
            ▼                             ▼
         test ──────────────────►     test (re-runs against tag SHA)
            │                             │
    ┌───────┼───────┐                     │
    ▼       ▼       ▼                     ▼
   iOS    Android  (deploy record:     iOS submit-to-review
    │       │       testflight-         (uses altool with
    ▼       ▼       internal)            --upload-app type=ios,
 altool   build                          plus a submission call)
 upload   AAB                            │
                                         ▼
                                  (deploy record:
                                   app-store-review)
```

The "submit to review" bit is a second API call after the upload finishes —
`altool --upload-app` just gets the build into App Store Connect; actually
asking Apple to review it uses the App Store Connect API's
`appStoreVersionSubmissions` endpoint. Wrap it in `tools/ci/submit_review.sh`
so it lives next to `upload_ios.sh`.

## Cross-repo reuse

The CI/CD template repo should own:

- **`compute_version.sh`** — the branch-aware version logic above.
- **`set_version.sh`** — unchanged from today; writes version + build into
  `project.godot` + `export_presets.cfg` (Godot apps) or `Info.plist` /
  `build.gradle` (future non-Godot apps). Keep it pluggable.
- **`upload_ios.sh`** / **`submit_review.sh`** / **`mark_live.sh`** — all the
  App Store Connect glue. These don't change between apps.
- **Reusable GitHub Actions workflow** — exposing the job graph above as a
  `workflow_call` target that each app's `.github/workflows/release.yml`
  calls with app-specific inputs (bundle ID, app ID, secret names).

Per-app files stay small:

- `.github/workflows/release.yml` — ~10 lines, delegates to the reusable
  workflow.
- `.github/workflows/ci.yml` — lint + tests on PRs; can also be shared.
- `project.godot` / `export_presets.cfg` — app-specific config.

Secrets stay per-repo (each app has its own Apple bundle ID, ASC keys, etc.).
Secret *names* stay identical across apps so the shared workflow references
the same variables everywhere.

## Branch protection (once set up)

- `main` — require PR, require green CI, require linear history, disallow
  force-push. No direct pushes.
- `release/*` — require PR for non-cherry-picks, require green CI, disallow
  force-push. Allow cherry-pick pushes from maintainers (use an allow-list or
  just convention).
- Tag push `v*` — gated via an Environment requiring manual approval if
  you want a second pair of eyes on every store submission. Otherwise
  un-gated and fast.

## What this buys vs. the current setup

| Question | Today | With this model |
|---|---|---|
| "What's on TestFlight right now?" | Latest `main` push — check the workflow log | `testflight-internal` deployment on the repo home page |
| "What's in App Store review?" | Apple's dashboard | `app-store-review` deployment + tag |
| "What's live?" | Apple's dashboard | `app-store-live` deployment + tag |
| "Can I patch 1.2.x while main is on 1.3?" | No (version collision) | Yes (hotfix on `release/1.2`) |
| "What versions exist?" | `git log` + Apple | `git tag -l 'v*'` + `git branch -a --list 'release/*'` |
| "Is this reusable across apps?" | Partially — scripts are copy-pasted | Yes — shared template repo, per-app workflow is a thin wrapper |

## Open questions before implementation

1. **Release branch creation — automatic or manual?** This doc assumes
   automatic (tag-triggered workflow cuts the branch). Manual is one extra
   command but removes a class of "CI made a branch I didn't expect" bugs.
2. **Squash vs. merge commits on `main`.** Squash keeps the commit-count
   patch numbering clean and the history readable. Recommend squash.
3. **Do we ever want to skip the TestFlight step for a hotfix?** See
   "Emergency" above. Policy, not tooling.
4. **Non-Godot apps.** `set_version.sh` is currently Godot-specific; the
   shared version will need a `--platform` flag (or per-app override) to
   write the right files.
