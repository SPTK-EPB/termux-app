# AGENTS.md — Termux App (Unity Fork)

> Instructions for AI coding agents (GitHub Copilot coding agent, Copilot CLI, etc.)
> This is SPTK-EPB's fork of [termux/termux-app](https://github.com/termux/termux-app),
> extended with Unity Device Manager zero-touch provisioning and SSH bootstrap.

## What This Repo Is

A fork of the upstream Termux Android app. The SPTK-specific additions live entirely in
`TermuxInstaller.java` and are designed to be minimal and rebasing-friendly:

1. **SSH bootstrap** — after the Termux bootstrap zip is extracted, writes `~/.ssh/authorized_keys`
   (fleet management public key) and `~/.bashrc` (sshd safety net), then installs openssh and
   starts sshd via `Runtime.exec()` in the background. Log: `~/unity-ssh-setup.log`.
2. **DPC auto-provisioning** — reads `deviceId`, `deviceSecret`, and `baseUrl` from Android
   Application Restrictions (set by the DPC via AndroidManagementAPI), fetches and runs the
   UDM bootstrap script via `Runtime.exec()`. Log: `~/unity-provisioning.log`.
   Retries 6 times with 5 s gaps before giving up (restrictions may not be applied immediately).

Both hooks run inside `setupBootstrapIfNeeded()` in `TermuxInstaller.java`, after the bootstrap
zip has been successfully extracted and before `whenDone.run()` is called.

## Module Layout

| Module | Purpose |
| ------ | ------- |
| `app/` | Main Termux app (`com.termux`) — Activity, Service, TermuxInstaller |
| `terminal-emulator/` | Platform-independent terminal emulator library |
| `terminal-view/` | Android View wrapping the terminal emulator |
| `termux-shared/` | Shared utilities used by Termux and its plugin apps |

## Key Files

- `app/src/main/java/com/termux/app/TermuxInstaller.java` — bootstrap logic + all Unity customizations
- `app/build.gradle` — `versionName` / `versionCode`; package variant (`packageVariant`)
- `gradle.properties` — SDK versions (`compileSdkVersion`, `minSdkVersion`, `targetSdkVersion`, `ndkVersion`)
- `.github/workflows/debug_build.yml` — CI (builds on push/PR to `master`)
- `.github/workflows/attach_debug_apks_to_release.yml` — builds and attaches APKs when a GitHub Release is published

## Version Scheme

`0.118.0-unity.N` — based on upstream `v0.118.3`. `versionCode` is `118N` (e.g. unity.8 → 118008).
Bump both when cutting a release. The `versionName` is validated against semver by the build scripts.

## Build

```bash
# Debug build (all ABIs), apt-android-7 variant (default)
./gradlew assembleDebug

# Specific package variant
TERMUX_PACKAGE_VARIANT=apt-android-5 ./gradlew assembleDebug
```

Requires Android SDK and NDK. Java 17. The NDK version is pinned in `gradle.properties` (`ndkVersion`).
APKs land in `app/build/outputs/apk/debug/`.

## Code Style

- Java only in `app/` — match the existing code style (Android conventions, no Kotlin)
- Log via `Logger.logInfo(LOG_TAG, ...)` and `Logger.logError(LOG_TAG, ...)`
- Unity-specific code must be clearly commented with `// Unity:` prefix so it's easy to identify during upstream rebases
- No new library dependencies without discussion — keep the APK lean

## Commit Messages

Use conventional commits:

```
feat: description
fix: description
chore: bump versionCode to 118009 for v0.118.0-unity.9

Generated-by: copilot-agent
```

## Boundaries

### Always

- Keep Unity customizations confined to `TermuxInstaller.java` — don't spread provisioning logic
  into other classes
- Annotate all Unity-specific blocks with `// Unity:` comments
- Test on a real device or emulator (API 28+) before declaring a fix done — the bootstrap race
  is timing-sensitive
- Increment `versionCode` and `versionName` for any release build

### Ask First

- Adding or changing the SSH public key hardcoded in `TermuxInstaller.java` — this affects all
  enrolled devices
- Rebasing onto a newer upstream Termux release
- Changing `minSdkVersion` or `targetSdkVersion`
- Modifying CI workflows

### Never

- Commit `.env` files, API keys, or secrets
- Commit the signing keystore (`.jks`) — it is gitignored
- Build a release APK and publish it without explicit approval
- Modify upstream terminal emulator or terminal view code unless fixing a confirmed bug

## Known Gotchas

### Bootstrap race (Android 11+)

`runUnityProvisioning()` and `injectSshBootstrap()` both invoke `Runtime.exec()` to run shell
commands that use `apt`/`pkg`. They can race for the apt lock. The SSH setup script waits up
to 120 s (30 × 4 s) for the lock. Do not remove that wait loop — it exists for a reason.

Previous approach used `yes |` piped into `pkg install` which caused broken pipe errors on
Android 11. The fix was to drop the pipe entirely (`pkg install -y openssh`).

### Application Restrictions timing

On fully managed devices, DPC-set Application Restrictions are sometimes not available
immediately at first launch. `runUnityProvisioning()` polls up to 6 times with 5 s gaps.
If no restrictions appear after 30 s, provisioning is silently skipped — the device falls back
to the `.bashrc` safety net for SSH access on the next terminal open.

### Runtime.exec() PATH

Termux's `$PREFIX/bin` is not on the system `$PATH` when commands are launched via
`Runtime.exec()`. All shell commands in the provisioning/SSH scripts must use the full Termux
path (`/data/data/com.termux/files/usr/bin/`) or be invoked through `$PREFIX/bin/bash -c '...'`
(which sets up the correct environment).

### No Google Play distribution

This fork is distributed exclusively as a debug APK via GitHub Releases and installed via UDM
`fleet-install`. It is not submitted to F-Droid or Google Play. The `apt-android-7` variant is
the standard build target.
