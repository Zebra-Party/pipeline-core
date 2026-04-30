# Godot iOS → TestFlight CI/CD playbook

A catalogue of every problem we hit shipping a Godot 4.6 iOS build to TestFlight via GitHub Actions, and what fixed it. Intended as a checklist when bootstrapping a new Godot project from a template.

Skim the **Setup checklist** first; if a build then breaks, jump to **Symptom → cause → fix**.

---

## Setup checklist

Before you ever push a CI build, work through these in order. Most of the time spent debugging in this repo would have been saved by doing this once at the start.

### 1. `project.godot`

- [ ] `[rendering]` contains **`textures/vram_compression/import_etc2_astc=true`** — without this, iOS export fails with an empty error message. See [empty configuration errors](#empty-configuration-errors-message).
- [ ] `config/icon` points at a real PNG that exists in the project (not the default `res://icon.svg`, which the template ships with).
- [ ] If you set `boot_splash/image`, the file actually exists.

### 2. `export_presets.cfg`

- [ ] **One iOS preset, name = `"iOS"`**, platform = `"iOS"`. Match it byte-for-byte against a known-working preset from another shipping project — Godot's GUI silently adds new fields with defaults across versions, so a hand-edited preset rots fast.
- [ ] `application/bundle_identifier` matches the App ID registered in App Store Connect.
- [ ] `application/export_method_release=0` (App Store distribution).
- [ ] `application/export_project_only=false` — Godot 4.6 produces a signed `.ipa` directly. No `xcodebuild` middle step needed.
- [ ] `architectures/arm64=true`.
- [ ] `application/code_sign_identity_release="iPhone Distribution"` — leave this string literal even if your actual cert is named `Apple Distribution: …`. Godot does substring matching; "iPhone Distribution" matches modern Apple Distribution certs.
- [ ] `application/app_store_team_id` and `application/provisioning_profile_specifier_release` left empty in the committed file. CI injects them at build time so secrets stay out of git.
- [ ] **All `icons/icon_*` paths point at files that exist in *this* project.** When you copy a preset between projects, the icon paths come with it — make sure none still point at the donor project's `res://Assets/...`.

### 3. App Store Connect

- [ ] App created under your team (with the bundle id from the preset).
- [ ] An **App Store Distribution** provisioning profile created for that bundle id, downloaded as `.mobileprovision`.
- [ ] An **Apple Distribution** certificate created and exported as `.p12` with a password.
- [ ] An **App Store Connect API key** created (Users and Access → Integrations) with the App Manager role. Note the issuer ID + key ID, download the `.p8`.

### 4. GitHub repo secrets

| Secret | Source |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_IOS_DISTRIBUTION_PROVISION` | `base64 -i profile.mobileprovision` |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect → Users and Access → Integrations |
| `APP_STORE_CONNECT_KEY_ID` | Same page; per-key |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | `base64 -i AuthKey_XXX.p8` |

### 5. Self-hosted macOS runner

- [ ] Xcode installed (any reasonably recent version; the workflow uses whatever `xcrun` finds).
- [ ] Runner registered with labels `[self-hosted, macOS]` (or whatever your release workflow targets).
- [ ] First run of pipeline-core's `install_godot.sh` (invoked by the reusable `ios-release.yml` workflow) will fetch Godot + the iOS export template; cache it under `RUNNER_TOOL_CACHE` so subsequent runs are fast.
- [ ] If Godot.app gets quarantined by macOS Gatekeeper, `xattr -dr com.apple.quarantine /path/to/Godot.app`.

---

## Symptom → cause → fix

### Empty `configuration errors:` message

```
ERROR: Cannot export project with preset "iOS" due to configuration errors:
   at: _fs_changed (editor/editor_node.cpp:1332)
ERROR: Project export for preset "iOS" failed.
```

Note the colon with **nothing after it**. Godot is telling you validation failed but didn't populate an error string.

**Cause.** `editor/export/editor_export_platform_apple_embedded.cpp::has_valid_project_configuration` contains a silent `valid = false`:

```cpp
if (!ResourceImporterTextureSettings::should_import_etc2_astc()) {
    valid = false;  // no error string appended — this is the silent failure
}
```

**Fix.** Add this to `[rendering]` in `project.godot`:

```
textures/vram_compression/import_etc2_astc=true
```

**Diagnostic shortcut.** If `--export-pack "iOS" path.pck` succeeds but `--export-release "iOS" path.ipa` gives empty config errors, it's almost always this — `--export-pack` skips the iOS-specific validation that contains the silent failure. Don't waste time chasing signing.

### `App Store Team ID not specified.`

**Cause.** `application/app_store_team_id` is empty in the preset and CI didn't inject it.

**Fix.** Either:
- Confirm `APPLE_IOS_DISTRIBUTION_PROVISION` is set as a secret (the team ID gets extracted from the profile by `configure_ios_signing.sh`), or
- Manually verify pipeline-core's `configure_ios_signing.sh` ran and its `awk` step actually rewrote the preset (echo the relevant fields after the script — see [configure_ios_signing.sh](https://github.com/Zebra-Party/pipeline-core/blob/main/scripts/configure_ios_signing.sh) for the diagnostic pattern).

### `Could not find type X` / `Identifier X not declared` during reimport

**Cause.** Godot's class_name registration doesn't always settle on the first `--editor --quit-after` pass.

**Fix.** Run the prime step twice. Pipeline-core's [godot_import.sh](https://github.com/Zebra-Party/pipeline-core/blob/main/scripts/godot_import.sh) already retries automatically when it sees these patterns in the log. If you're writing a new prime script:

```sh
"$GODOT" --headless --editor --path . --quit-after 60 > "$LOG" 2>&1
if grep -qiE "Could not find type|Identifier .* not declared" "$LOG"; then
  "$GODOT" --headless --editor --path . --quit-after 60 > "$LOG" 2>&1
fi
```

### `--quit` kills Godot before imports finish

**Cause.** `--quit` exits as soon as the editor mainloop ticks once, which is *before* the filesystem scan, class globals, and `.godot/imported/*` sidecars have settled. The next export step then sees a stale or empty `.godot/`.

**Fix.** Use `--quit-after 60`. Sixty frames is enough for everything to land on disk.

### iOS export template missing

```
::error::Godot iOS export template (ios.zip) is missing from ...
```

**Cause.** Godot's installer doesn't fetch export templates by default. They're a separate `.tpz` download.

**Fix.** Have your `install_godot.sh` download the templates archive and unzip it into `~/Library/Application Support/Godot/export_templates/<version>.stable/`. The iOS export only needs `ios.zip` from that bundle.

### `unzip: command not found` on a Linux runner

**Cause.** Some self-hosted Linux runners don't ship `unzip`.

**Fix.** Use Python's stdlib instead:

```sh
python3 -m zipfile -e archive.zip dest/
```

Works the same on macOS and Linux.

### `pip install gdtoolkit` fails with PEP 668 / "externally-managed-environment"

**Cause.** Modern distros (and recent macOS Pythons) refuse `pip install` to the system Python.

**Fix.** Install via `uv` instead. It manages its own venv automatically:

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install gdtoolkit
# now `gdformat` and `gdlint` are on PATH via uv
```

### Godot.app refuses to launch after download (macOS)

```
"Godot" cannot be opened because the developer cannot be verified.
```

**Cause.** Gatekeeper quarantine attribute on the downloaded archive.

**Fix.**

```sh
xattr -dr com.apple.quarantine /path/to/Godot.app
```

Do this in `install_godot.sh` immediately after extracting the archive.

### Spotlight icon size mismatch

If your icon set has 48 + 96 px slots filled but Godot complains about missing 40/80, you've copied the **macOS** Spotlight slots when iOS wants different sizes.

**Fix.** iOS Spotlight needs `icon_40.png` (40×40 @1x) and `icon_80.png` (40×40 @2x). Generate them and update the relevant `icons/spotlight_*` paths in the preset.

### IPA produced but signature invalid / `codesign --verify` fails

**Cause.** Usually one of:
- `code_sign_identity_release` doesn't substring-match any cert in the keychain.
- The provisioning profile UUID injected into the preset doesn't match a profile installed at `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision`.
- The keychain wasn't unlocked, or the cert was imported without `set-key-partition-list`.

**Fix.** `configure_ios_signing.sh` in this repo handles all three correctly — copy that pattern. The diagnostic worth keeping in build logs:

```sh
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
```

Run that **after** importing the cert and surface the output unconditionally (not inside `::group::`).

### Provisioning profile vs preset bundle ID mismatch

```
::warning::Provisioning profile is for 'X' but the preset's bundle id is 'Y' — Godot will refuse to export.
```

This warning is emitted by `configure_ios_signing.sh` in this repo. Heed it — Godot will silently fail the export later.

**Fix.** Either:
- Regenerate the provisioning profile against the right App ID, or
- Update `application/bundle_identifier` in the preset to match the profile's app id.

Both must equal the App ID you registered in App Store Connect.

### Build hangs forever (Android example, but same pattern)

Symptom: a CI step runs for >15 min with no output.

**Cause.** A Godot CLI call that depends on missing tooling will sometimes hang silently rather than fail. We saw this with `--export-release` for Android when the Android SDK / JDK weren't installed on the runner.

**Fix.** Wrap long Godot calls with `timeout` in CI:

```sh
timeout 600 "$GODOT" --headless --path . --export-release "Android" out.aab
```

Better to fail cleanly at 10 minutes than wedge the runner.

### GitHub Actions log groups hide the only useful line

```
::group::Godot output
... 800 lines ...
::endgroup::
```

GitHub collapses these by default. The actual error message is buried.

**Fix.** Don't put critical diagnostics inside `::group::`. Echo them as plain lines so they're visible without expanding. We do this for the iOS signing summary and the codesigning identities — both are the first thing anyone needs when a build fails.

### `--export-pack` works but `--export-release` doesn't

This is a smoke signal, not a problem in itself: `--export-pack` only validates a subset of preset options. If pack passes and release fails, the diff is in the iOS-specific validation. Top suspects:

1. ETC2/ASTC setting (silent — see [Empty configuration errors](#empty-configuration-errors-message))
2. Missing `ios.zip` template
3. Bundle id / profile mismatch
4. Cert not in keychain or keychain locked

---

## Architecture decisions worth keeping

These aren't problems but choices that paid off across iterations:

- **Two workflows: `ci.yml` and `release.yml`.** PRs run lint + tests only. Push-to-main runs the full release pipeline. Don't let `release.yml` trigger on every branch — you'll burn runner time and rate-limit the App Store Connect API.
- **Self-hosted runners.** GitHub-hosted macOS minutes are expensive and slow. Two macOS runners (one primary, one backup) plus one Linux runner is enough.
- **Auto-versioning from git.** `major.minor` from the latest `vX.Y.Z` tag, patch from commits-since-tag, build from `github.run_number`. No manual version bumps in CI commits → no commit loops.
- **Direct IPA from Godot 4.6.** Don't wedge `xcodebuild -exportArchive` between Godot and the IPA — Godot 4.6's iOS exporter does it correctly when `application/export_project_only=false`. Fewer moving parts.
- **Inject signing only at CI time.** The committed `export_presets.cfg` has empty `app_store_team_id` and `provisioning_profile_specifier_release`. `configure_ios_signing.sh` fills them in before export. Keeps secrets out of git and lets each project's CI inject its own values.

---

## Reference: minimal script set

All of these now live in [Zebra-Party/pipeline-core/scripts](https://github.com/Zebra-Party/pipeline-core/tree/main/scripts) and are invoked by the reusable workflows in that repo. Game repos (including this one) don't vendor copies — they call the reusable workflow and pipeline-core checks itself out under `.pipeline-core/` inside the running job.

| Script | What it does |
|---|---|
| `install_godot.sh` | Downloads Godot + iOS/Android/Linux export templates, dequarantines, caches under `$RUNNER_TOOL_CACHE`. |
| `lint.sh` | Installs `gdtoolkit` via `uv`, runs `gdformat --check` + `gdlint`. |
| `godot_import.sh` | Primes the project with `--editor --quit-after 60`, retries once if class_name registration didn't settle. |
| `boot_scenes.sh` | Headlessly opens every `*.tscn` for 60 frames, fails on `SCRIPT ERROR` / `Parse Error`. |
| `run_tests.sh` | Runs every `_test_*.gd` via `--script`. |
| `configure_ios_signing.sh` | Imports cert into a temp keychain, installs the profile, injects `team_id` + `provisioning_profile_specifier_release` into the preset. |
| `build_ios.sh` | Runs the `--export-release`, verifies the IPA contains a non-empty `.pck` and a valid signature. |
| `upload_ios.sh` | `xcrun altool` upload to TestFlight via App Store Connect API. |
| `compute_version.sh` / `set_version.sh` | Derives version from git tag + commits, writes into `project.godot` + `export_presets.cfg`. |

Each one is short and self-contained. Open them next to this doc when debugging a CI failure or bootstrapping a new project.
