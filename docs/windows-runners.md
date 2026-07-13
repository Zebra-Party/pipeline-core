# Using self-hosted Windows runners

Every reusable workflow here takes a **`runner`** input — a JSON array of runner labels —
defaulting to the org's ephemeral macOS pool. Override it to route a job to a **self-hosted
Windows runner** for work that doesn't need macOS (Godot Android exports, Swift/.NET builds,
Unreal builds, etc.).

## Targeting a Windows runner

You must pass **both** `runner` and `shell`. Passing `runner` alone will fail every step.

```yaml
jobs:
  android:
    uses: Zebra-Party/pipeline-core/.github/workflows/android-build.yml@v1
    with:
      runner: '["self-hosted", "Windows", "X64"]'
      shell: 'C:\Users\Developer\AppData\Local\Programs\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}'
    secrets: inherit
```

### Why `shell` is not optional

The scripts are bash. On the Windows host, GitHub's `shell: bash` resolves to
**WSL's `C:\Windows\System32\bash.exe`** — which has no distro installed — and every
step dies. Git for Windows is a per-user install, so its `bash.exe` is not on the
machine PATH. Point at it explicitly.

Two more things that bite in bash on Windows, both already handled in the scripts but
worth knowing when you write a new step:

- **Drive letters look like remote hosts to `tar`.** `tar -xf "$RUNNER_TEMP/x.tar.xz"`
  fails with `tar: Cannot connect to D: resolve failed`. Stage archives at a *relative*
  path instead.
- **`shasum` is not on PATH** (`--noprofile --norc` skips `/usr/bin/core_perl`). Use
  `sha256sum`, or pick whichever exists if the step must also run on macOS.

A runner is selected when it carries **all** the requested labels, so
`["self-hosted", "Windows", "X64"]` matches any Windows runner in the pool — extra labels it
may also carry don't exclude it.

Only override `runner` for jobs that can actually run on Windows. Xcode / Apple
code-signing workflows (`ios-release`, `macos-release`, `flutter-ios-release`,
`xcode-release`) **must** stay on macOS.

## What the job needs on the host

These workflows do **not** provision the runner — the host must already have the toolchain the
job uses (self-hosted runners are long-lived machines, not per-job images). For example:

| Job | Host must provide |
|---|---|
| Godot Android export | an Android SDK/JDK on the host. `install_godot.sh` handles the Godot editor + export templates on Windows too (downloads the `win64` build, or picks up a pre-baked one via `$GODOT_HOME`); on a persistent host, bake Godot once so it's a no-op per job. |
| Swift build / test | a Swift toolchain for Windows |
| .NET / Flutter / Android | the respective SDK on `PATH` |

## Windows gotchas

- **`shell: bash` may resolve to WSL bash.** If Git for Windows is a per-user install,
  GitHub's `shell: bash` can pick `C:\WINDOWS\system32\bash.exe` (WSL — usually with no distro
  installed) and fail every bash step. Prefer **`shell: pwsh`** on Windows, or pin Git Bash
  explicitly: `shell: 'C:\Path\To\Git\bin\bash.exe --noprofile --norc -eo pipefail {0}'`.
- **No POSIX path mangling in `pwsh`.** Git Bash rewrites `/foo/...`-style arguments into
  `C:/.../Git/foo/...`; in bash set `MSYS_NO_PATHCONV=1` and `cygpath -w` real paths. `pwsh`
  passes arguments literally.
- **Persistent hosts keep state between jobs.** Caches stay warm, but a job must not assume a
  clean workspace. No workflow here exposes a "wipe the workspace" input — if a step needs a
  pristine tree, it has to clean up after itself (e.g. `git clean -xdf`, or removing the build
  output directory before writing to it).

## Host provisioning

Standing up a Windows runner host — registering runners as services, wiring a shared Git-LFS
cache, tool install — is an org-infrastructure task documented in the internal workspace repo,
not here. This page covers only how a **consumer workflow** targets a runner that already
exists.
